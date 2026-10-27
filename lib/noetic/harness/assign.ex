defmodule Noetic.Harness.Assign do
  @moduledoc """
  Give an epic to a profile, or refuse to (plan 02 §3).

  `noetic-harness assign` runs on the coordinator's workstation. It decides one
  thing that nothing else in the landing path can decide early enough: that
  the epic's paths are disjoint from every other live epic's. Two workers on
  one file is a merge conflict found at the landing, after both have spent
  their session; refused here, it is a sentence before either starts.

  ## What an epic's paths are

  Its **scope** is the profile's paths (`Noetic.Harness.Profiles`), narrowed by
  `--scope` globs, each of which must stay inside the profile. Its **grants**
  are paths outside the profile the epic may also change: another profile's
  file, or a coordinator-held one with `--ack`. Refused paths are never
  granted, and a fenced path needs `--ack` too, and the person at the landing.

  Overlap is decided on **tracked files**, not on glob text: two globs that
  look different can name one file, and two that look alike can name none in
  common. Add-only and per-epic files are in every scope and are not compared;
  a run file or a memory record added by two epics is two files.

  ## What is live

  The coordination records under `.agents/coordination/`, one file per act and
  add-only. An epic's assignment is live when its latest record is an assign
  or a reassign (or a return or revert, which put it back to work), unless bd
  says the epic is closed. Before this module, records were written by hand
  and carry no scope; they are counted and said, not compared.

  ## What it writes

  One coordination record per act (`assign`, `reassign`, `abandon`) and, not
  under `--dry-run`, the bd side through `Noetic.Harness.Beads`: assignee,
  status and label, and an assignment block in the notes. A reassign or
  abandon record carries the old branch's head sha, which is the "not landed"
  fact telemetry reads.

  ## What it does not do

  Send the brief. It prints it; the coordinator sends it (`claude -p … --cloud
  <session>`). And nothing here checks the record against a schema: the
  coordination schema is `.agents/schemas/coordination.schema.json`, which is
  outside an earlier change's scope and a `shared_change_requests[]` entry of it.
  """

  alias Noetic.Harness.{Glob, Profiles}

  @type request :: %{
          required(:epic) => String.t(),
          optional(:profile) => String.t(),
          optional(:session) => String.t() | nil,
          optional(:scope) => [String.t()],
          optional(:grants) => [String.t()],
          optional(:adrs) => [pos_integer()],
          optional(:slug) => String.t() | nil,
          optional(:ack) => boolean(),
          optional(:reassign) => boolean(),
          optional(:by) => String.t() | nil
        }

  @live_acts ~w(assign reassign return revert)
  @ended_acts ~w(abandon landing)

  @listed 10

  @doc "Where the records live."
  @spec dir() :: Path.t()
  def dir, do: Noetic.Harness.agents_path("coordination")

  # ---- live assignments --------------------------------------------------------

  @doc """
  The live assignments, and how many records carry no scope to compare.

  Returns `{live, unscoped}`: `live` maps an epic to its latest scoped record.
  `opts[:status]` answers an epic's bd status (`{:ok, "closed"}` ends it);
  `opts[:records]` replaces the directory, for the tests.
  """
  @spec live(keyword()) :: {%{String.t() => map()}, non_neg_integer()}
  def live(opts \\ []) do
    records = Keyword.get_lazy(opts, :records, &records/0)
    status = Keyword.get(opts, :status, fn _epic -> :error end)

    {scoped, unscoped} = Enum.split_with(records, &is_list(&1["scope"]))

    live =
      scoped
      |> Enum.group_by(& &1["bead"])
      |> Enum.flat_map(fn {epic, list} ->
        latest = Enum.max_by(list, &{&1["at"], &1["id"]})

        cond do
          latest["act"] in @ended_acts -> []
          latest["act"] not in @live_acts -> []
          match?({:ok, "closed"}, status.(epic)) -> []
          true -> [{epic, latest}]
        end
      end)
      |> Map.new()

    {live, length(unscoped)}
  end

  @doc "Every coordination record, decoded. A file that is not one is skipped."
  @spec records() :: [map()]
  def records do
    dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Noetic.Harness.Loader.load(path) do
        {:ok, %{"act" => _, "bead" => _} = record} -> [record]
        _ -> []
      end
    end)
  end

  # ---- planning ------------------------------------------------------------------

  @doc """
  Decide an assignment without writing anything.

  `{:ok, plan}` or `{:error, reasons}`, every reason at once: a coordinator
  told one reason at a time fixes one and runs it again.

  Options: `:doc`, `:tracked`, `:fence`, `:live` (`{live, unscoped}`),
  `:bead` (an epic's title and `bd show` text), each read from the
  repository when absent.
  """
  @spec plan(request(), keyword()) :: {:ok, map()} | {:error, [String.t()]}
  def plan(request, opts \\ []) do
    epic = request.epic
    profile_id = request[:profile]

    with {:ok, doc} <- fetch(opts, :doc, &Profiles.load/0),
         {:ok, tracked} <- fetch(opts, :tracked, &Profiles.tracked/0),
         {:ok, profile} <- profile(doc, profile_id) do
      fence = Keyword.get_lazy(opts, :fence, &Profiles.fence_globs/0)
      classify = Profiles.classifier(doc, fence: fence, epic: epic)
      {live, unscoped} = Keyword.get_lazy(opts, :live, fn -> live() end)
      previous = Map.get(live, epic)
      others = Map.delete(live, epic)

      scope = request[:scope] || []
      grants = request[:grants] || []
      scope_globs = if scope == [], do: profile["owns"], else: scope

      scope_files = files(tracked, scope_globs, profile["except"] || [], scope == [])
      grant_files = files(tracked, grants, [], false)

      mine = compared(scope_files ++ grant_files, classify)

      reasons =
        already(previous, request) ++
          outside(scope, scope_files, profile["id"], classify) ++
          granted(grants, grant_files, classify, request[:ack] == true) ++
          overlaps(mine, others, tracked, doc, fence) ++
          concurrency(profile, others) ++
          adrs(request[:adrs] || [], others, tracked)

      if reasons == [] do
        {:ok,
         %{
           epic: epic,
           profile: profile["id"],
           session: request[:session],
           scope: scope_globs,
           narrowed: scope != [],
           except: if(scope == [], do: profile["except"] || [], else: []),
           grants: grants,
           acked: acked(grants, grant_files, classify),
           adrs: Enum.sort(request[:adrs] || []),
           files: length(mine),
           previous: previous,
           unscoped: unscoped,
           unmatched: Enum.reject(scope ++ grants, &matches_any?(tracked, &1))
         }}
      else
        {:error, reasons}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, [reason]}
      {:error, reasons} -> {:error, reasons}
    end
  end

  defp fetch(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> default.()
    end
  end

  defp profile(_doc, nil), do: {:error, "no --profile: say which profile the epic is for"}

  defp profile(doc, id) do
    case Profiles.profile(doc, id) do
      {:ok, profile} ->
        {:ok, profile}

      :error ->
        {:error,
         "no profile #{inspect(id)}; the profiles are #{Enum.join(Profiles.ids(doc), ", ")}"}
    end
  end

  # The profile's own scope keeps its `except`; a narrowed one is whatever the
  # globs name, and `outside/4` says when that leaves the profile.
  defp files(tracked, globs, except, whole?) do
    regexes = Enum.map(globs, &Glob.compile/1)
    excluded = if whole?, do: Enum.map(except, &Glob.compile/1), else: []

    Enum.filter(tracked, fn path ->
      Glob.any?(regexes, path) and not Glob.any?(excluded, path)
    end)
  end

  defp matches_any?(tracked, glob) do
    regex = Glob.compile(glob)
    Enum.any?(tracked, &Regex.match?(regex, &1))
  end

  # Files in every scope are not compared: an add-only file two epics add is
  # two files, and an epic's own handoff is its own.
  defp compared(paths, classify) do
    paths
    |> Enum.uniq()
    |> Enum.reject(fn path ->
      match?({class, _} when class in [:add_only, :per_epic], classify.(path))
    end)
  end

  defp already(nil, _request), do: []
  defp already(_previous, %{reassign: true}), do: []

  defp already(previous, request) do
    [
      "#{request.epic} is already assigned to #{previous["profile"]} on #{previous["branch"]} " <>
        "(#{previous["id"]}); --reassign gives it a new branch, `--release #{request.epic}` ends it"
    ]
  end

  defp outside([], _files, _profile, _classify), do: []

  defp outside(_scope, files, profile, classify) do
    stray =
      for path <- files,
          class = classify.(path),
          not inside?(class, profile),
          do: {path, class}

    case stray do
      [] ->
        []

      _ ->
        [
          "--scope leaves #{profile}'s paths: " <>
            (stray |> Enum.take(@listed) |> Enum.map_join(", ", &describe/1)) <>
            more(stray) <> "; grant what the epic needs outside them with --grant"
        ]
    end
  end

  defp inside?({:owned, ids}, profile), do: profile in ids
  defp inside?({class, _}, _profile) when class in [:add_only, :per_epic], do: true
  defp inside?(_class, _profile), do: false

  defp granted(_grants, files, classify, ack?) do
    by_class = Enum.group_by(files, &class_name(classify.(&1)))

    refused =
      case by_class[:refused] do
        nil -> []
        paths -> ["--grant reaches refused paths, which no epic may change: " <> list(paths)]
      end

    unacked =
      for class <- [:held, :fenced], paths = by_class[class], paths != nil, not ack? do
        "--grant reaches #{label(class)} paths, which need --ack: " <> list(paths)
      end

    refused ++ unacked
  end

  defp acked(_grants, files, classify) do
    files
    |> Enum.filter(&(class_name(classify.(&1)) in [:held, :fenced]))
    |> Enum.sort()
  end

  defp class_name({:owned, _}), do: :owned
  defp class_name({class, _}), do: class
  defp class_name(:unowned), do: :unowned

  defp label(:held), do: "coordinator-held"
  defp label(:fenced), do: "fenced"

  defp overlaps(mine, others, tracked, doc, fence) do
    mine = MapSet.new(mine)

    for {epic, record} <- Enum.sort(others),
        theirs = their_files(record, tracked, doc, fence),
        common = MapSet.intersection(mine, theirs),
        MapSet.size(common) > 0 do
      paths = common |> Enum.sort()

      "shares #{length(paths)} tracked file(s) with #{epic} (#{record["profile"]}, " <>
        "#{record["branch"]}): " <> list(paths)
    end
  end

  defp their_files(record, tracked, doc, fence) do
    classify = Profiles.classifier(doc, fence: fence, epic: record["bead"])

    except =
      case Profiles.profile(doc, record["profile"]) do
        {:ok, profile} -> profile["except"] || []
        :error -> []
      end

    whole? = record["narrowed"] != true

    (files(tracked, record["scope"], except, whole?) ++
       files(tracked, record["grants"] || [], [], false))
    |> compared(classify)
    |> MapSet.new()
  end

  defp concurrency(profile, others) do
    holding = for {epic, record} <- others, record["profile"] == profile["id"], do: epic

    if length(holding) >= profile["max_concurrent"] do
      [
        "#{profile["id"]} runs at most #{profile["max_concurrent"]} session(s), and " <>
          "#{Enum.join(Enum.sort(holding), ", ")} already hold(s) an assignment"
      ]
    else
      []
    end
  end

  defp adrs(numbers, others, tracked) do
    reserved =
      for {epic, record} <- others,
          n <- record["reserved_adr_numbers"] || [],
          into: %{},
          do: {n, epic}

    for n <- Enum.sort(numbers),
        reason = adr_taken(n, reserved, tracked),
        reason != nil,
        do: reason
  end

  # Where an ADR's file would be is the project's to say (`adr` in
  # `.agents/registry/project.json`). A project that names no ADR
  # directory has no file to find, and only reservations can refuse a number.
  defp adr_taken(n, reserved, tracked) do
    prefix = Noetic.Harness.Project.adr_file_prefix(n)

    cond do
      Map.has_key?(reserved, n) -> "ADR-#{n} is reserved by #{reserved[n]}"
      prefix && Enum.any?(tracked, &String.starts_with?(&1, prefix)) -> "ADR-#{n} exists already"
      true -> nil
    end
  end

  defp describe({path, {:owned, ids}}), do: "#{path} (#{Enum.join(ids, ", ")}'s)"
  defp describe({path, :unowned}), do: "#{path} (nobody's)"
  defp describe({path, {class, _}}), do: "#{path} (#{class})"

  defp list(paths) do
    sorted = Enum.sort(paths)
    Enum.join(Enum.take(sorted, @listed), ", ") <> more(sorted)
  end

  defp more(items) when length(items) > @listed, do: " (and #{length(items) - @listed} more)"
  defp more(_items), do: ""

  # ---- the branch and the record ------------------------------------------------------

  @doc """
  The branch for a plan: `claude/<epic>-<slug>`. A reassignment mints a new
  slug by numbering it, so the abandoned branch and the new one never share a
  name and the old head stays findable.
  """
  @spec branch(map(), String.t()) :: String.t()
  def branch(plan, slug) do
    slug =
      case plan.previous do
        nil -> slug
        %{"branch" => old} -> next_slug(old, plan.epic, slug)
      end

    "claude/#{plan.epic}-#{slug}"
  end

  defp next_slug(old, epic, slug) do
    case Regex.run(~r/^claude\/#{Regex.escape(epic)}-(.+?)(?:-(\d+))?$/, old) do
      [_, ^slug, n] -> "#{slug}-#{String.to_integer(n) + 1}"
      [_, ^slug] -> "#{slug}-2"
      _ -> slug
    end
  end

  @doc "A slug from a title: the first four words, lower case, hyphenated."
  @spec slug(String.t() | nil) :: String.t()
  def slug(nil), do: "work"

  def slug(title) do
    words =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, " ")
      |> String.split(" ", trim: true)
      |> Enum.take(4)

    if words == [], do: "work", else: Enum.join(words, "-")
  end

  @doc """
  The profile that holds the epic in bd now: the previous assignment's, for a
  reassign, and `nil` for a first assign. `Beads.assign/4` guards the change
  with it.
  """
  @spec holder(map()) :: String.t() | nil
  def holder(%{previous: %{"profile" => profile}}) when is_binary(profile), do: profile
  def holder(_plan), do: nil

  @doc """
  The coordination record for an act. Pure: `at` and `nonce` are given, so
  the same inputs give the same record.
  """
  @spec record(String.t(), map(), keyword()) :: map()
  def record(act, plan, opts) do
    at = Keyword.fetch!(opts, :at)
    nonce = Keyword.fetch!(opts, :nonce)
    date = String.slice(at, 0, 10)

    %{
      "id" => "#{date}-#{act}-#{plan.epic}-#{nonce}",
      "act" => act,
      "at" => at,
      "by" => Keyword.get(opts, :by) || "the coordinator",
      "bead" => plan.epic,
      "profile" => plan.profile,
      "session" => plan.session,
      "branch" => Keyword.fetch!(opts, :branch),
      "scope" => plan.scope,
      "narrowed" => plan.narrowed,
      "grants" => plan.grants,
      "acked" => plan.acked,
      "reserved_adr_numbers" => plan.adrs,
      "files" => plan.files
    }
    |> put_previous(plan.previous, Keyword.get(opts, :previous_head))
  end

  defp put_previous(record, nil, _head), do: record

  defp put_previous(record, previous, head) do
    Map.put(record, "previous", %{
      "record" => previous["id"],
      "branch" => previous["branch"],
      "head" => head
    })
  end

  @doc "The record for `--release`: the live assignment it ends, and where its branch stood."
  @spec release_record(map(), keyword()) :: map()
  def release_record(previous, opts) do
    at = Keyword.fetch!(opts, :at)

    %{
      "id" =>
        "#{String.slice(at, 0, 10)}-abandon-#{previous["bead"]}-#{Keyword.fetch!(opts, :nonce)}",
      "act" => "abandon",
      "at" => at,
      "by" => Keyword.get(opts, :by) || "the coordinator",
      "bead" => previous["bead"],
      "profile" => previous["profile"],
      "session" => previous["session"],
      "branch" => previous["branch"],
      "scope" => previous["scope"],
      "narrowed" => previous["narrowed"],
      "grants" => previous["grants"] || [],
      "previous" => %{
        "record" => previous["id"],
        "branch" => previous["branch"],
        "head" => Keyword.get(opts, :previous_head)
      }
    }
  end

  @doc "Write a record where it belongs. Never over an existing file: the class is add-only."
  @spec write(map()) :: {:ok, Path.t()} | {:error, String.t()}
  def write(record) do
    path = Path.join(dir(), record["id"] <> ".json")

    with :ok <- File.mkdir_p(dir()),
         false <- File.exists?(path),
         :ok <- File.write(path, Noetic.Harness.Loader.pretty!(record)) do
      {:ok, path}
    else
      true -> {:error, "#{path} exists; a coordination record is never overwritten"}
      {:error, reason} -> {:error, "could not write #{path}: #{inspect(reason)}"}
    end
  end

  @doc "The branch's head sha, from origin or the local ref, or `nil` when git has neither."
  @spec head(String.t()) :: String.t() | nil
  def head(branch) do
    Enum.find_value(["refs/remotes/origin/" <> branch, "refs/heads/" <> branch], fn ref ->
      case System.cmd("git", ["rev-parse", "--verify", "--quiet", ref],
             cd: Noetic.Harness.root(),
             stderr_to_stdout: true
           ) do
        {sha, 0} -> String.trim(sha)
        _ -> nil
      end
    end)
  end

  @doc "The block appended to the epic's notes in bd."
  @spec notes(map(), String.t()) :: String.t()
  def notes(record, branch) do
    """
    assignment (noetic-harness assign, #{record["id"]}):
      profile: #{record["profile"]}
      session: #{record["session"] || "none yet"}
      branch: #{branch}
      scope: #{Enum.join(record["scope"], " ")}
      grants: #{none(record["grants"])}
      adr: #{none(Enum.map(record["reserved_adr_numbers"], &"ADR-#{&1}"))}
    """
  end

  defp none([]), do: "none"
  defp none(list), do: Enum.join(list, " ")

  # ---- the brief -------------------------------------------------------------------------

  @doc """
  The brief the coordinator sends. Deterministic: the same plan, branch and
  bead text give the same bytes, which is what the golden test holds.

  Its first line is the shape CLAUDE.md's worker section accepts as an
  assignment; anything else a worker reads as a question.
  """
  @spec brief(map(), String.t(), String.t()) :: String.t()
  def brief(plan, branch, bead_text) do
    grants_line = if plan.grants == [], do: "none", else: Enum.join(plan.grants, ", ")

    scope_lines =
      Enum.map(plan.scope, &"    #{&1}") ++
        Enum.map(Map.get(plan, :except, []), &"    not #{&1}         (another profile's)") ++
        [
          "    .agents/handoff/#{plan.epic}.json",
          "    .agents/runs/*.json                      (new files only)",
          "    .agents/memory/records/*.json            (new files only)"
        ]

    grant_lines =
      case plan.grants do
        [] ->
          ["**Grants: none.** A change outside the scope is a `shared_change_requests[]` entry."]

        grants ->
          Enum.map(grants, &"    #{&1}") ++
            if(plan.acked == [],
              do: [],
              else: [
                "",
                "Coordinator-held or fenced, landed only with --ack: " <>
                  Enum.join(plan.acked, ", ")
              ]
            )
      end

    adr_lines =
      case plan.adrs do
        [] -> []
        numbers -> ["", "## Reserved ADR numbers", "", Enum.map_join(numbers, ", ", &"ADR-#{&1}")]
      end

    Enum.join(
      [
        "EPIC #{plan.epic}: branch #{branch}, scope #{Enum.join(plan.scope, ", ")}, grants #{grants_line}",
        "",
        "## The epic, as bd shows it",
        "",
        String.trim_trailing(bead_text),
        "",
        "## Scope",
        "" | scope_lines
      ] ++
        ["", "## Grants", "" | grant_lines] ++
        adr_lines ++
        [
          "",
          "## Protocol",
          "",
          "CLAUDE.md, *If you are a cloud worker*: WF-021, the handoff,",
          "WIP pushes, `run --finish`, the pull request against develop.",
          "End with `EPIC #{plan.epic} READY <S> <pr-url>`, or `EPIC #{plan.epic} BLOCKED <reason>`.",
          ""
        ],
      "\n"
    )
  end
end
