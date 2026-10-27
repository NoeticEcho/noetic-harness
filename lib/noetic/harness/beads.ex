defmodule Noetic.Harness.Beads do
  @moduledoc """
  A thin read shell over `bd`, the canonical work graph.

  Thin on purpose. Beads owns work state (`.agents/policies/source_of_truth.md`)
  and the harness must not become a second tracker: it reads beads to build
  context and to resolve a task id into a work item, and that is all. Creating,
  claiming and closing issues is done by an agent running `bd` directly, where
  the human can see it.

  Every function degrades to `:error` when `bd` is absent or its database will
  not open. That is reported, never silently replaced with an empty work graph —
  "no ready work" and "the tracker is down" are very different statements.

  ## And "the tracker did not answer" is a third statement

  `bd` opens a Dolt database, and more than one session shares this working
  directory, so a lock held by one of them used to be a wait with no end.
  Measured on 2026-09-22, by an independent reviewer who was doing something
  else at the time: **`bd ready` running for 327 seconds**, taking `ContextTest`
  with it and leaving a full suite run that never finished.

  So every call is bounded by `timeout/0`, and the bound produces `:timeout`
  rather than `:error`. The distinction earns its keep: `:error` means the
  tracker answered and said no, or is not installed, and the right response is
  to carry on without a work graph. `:timeout` means the tracker is *there* and
  is stuck, and the right response is to say so loudly enough that somebody
  looks at the lock.

  The bound is in two layers, because one of them is not enough. `Task.yield/2`
  guarantees that *this* process stops waiting, with no dependency and on any
  machine. It does not kill the external `bd`, which would then be an orphan
  holding the same lock — so when `timeout(1)` is on the PATH the command is
  run under it as well, and the orphan is reaped. `bounded?/0` says which of
  the two a given machine gets, and nothing here claims the stronger one when
  it has the weaker.
  """

  # How long `bd` may take before the caller stops waiting for it. Ten seconds
  # is three times the 3.2-4.2 s a healthy `bd ready` takes here and a thirtieth
  # of the 327 s that provoked this.
  @timeout_ms 10_000

  @type answer :: {:ok, String.t()} | :timeout | :error | :off

  @doc "How long a `bd` call may take before the caller gives up, in milliseconds."
  @spec timeout() :: pos_integer()
  def timeout, do: @timeout_ms

  @doc """
  Whether the external process is killed on timeout, or merely abandoned.

  `false` means `timeout(1)` is not on this machine: the harness still returns,
  but the `bd` that did not answer keeps running and keeps its lock.
  """
  @spec bounded?() :: boolean()
  def bounded?, do: System.find_executable("timeout") != nil

  @doc "Whether `bd` is on the PATH and answering."
  @spec available?() :: boolean()
  def available? do
    match?({:ok, _}, run(["--version"]))
  end

  @doc """
  `bd ready`, trimmed to a limit of lines.

  Options: `:timeout` in milliseconds, for the test that has to watch the
  bound fire without waiting out the real one.
  """
  @spec ready(pos_integer(), keyword()) :: answer()
  def ready(limit \\ 10, opts \\ []) do
    case run(["ready", "--json", "--brief", "--limit", to_string(limit)], opts) do
      {:ok, output} ->
        case render_ready(output) do
          {:ok, rendered} -> {:ok, rendered}
          :error -> plain_ready(limit, opts)
        end

      other ->
        other
    end
  end

  # `--brief` omits each row's free-form text, and that is the whole of the
  # saving. `bd ready` plain measured **4032–5202 ms** here
  # against **140–172 ms** for `bd ready --json --brief`: not because Dolt is
  # slow to open, which is what the bead assumed, but because the plain form
  # fetches every ready issue's description and this caller renders a one-line
  # summary and throws all of them away. Sixty-nine ready issues in this
  # repository, some with descriptions of several hundred words.
  #
  # `--limit` is passed as well, so `bd` stops at the rows that will be shown
  # rather than this taking the first few lines of everything.
  #
  # The parent survives. `--brief` keeps `dependencies`, where a `parent-child`
  # entry carries the parent's **id**; the plain renderer shows the parent's
  # *title*, which would need a second query. When the parent is itself in the
  # result — an epic is usually ready when its children are — the title is
  # resolved locally for nothing.
  @doc """
  Render `bd ready --json --brief` output as the one-line-per-issue block the
  `SessionStart` context carries, or `:error` if it is not that shape.

  Public so that a test can exercise it against a captured payload. The
  alternative — asserting through `ready/2` — needs a `bd` on the machine and a
  database in a known state, which makes it a test of this repository's tracker
  rather than of the renderer.
  """
  @spec render_ready(String.t()) :: {:ok, String.t()} | :error
  def render_ready(output) do
    with {:ok, json} <- array(output),
         {:ok, rows} when is_list(rows) <- JSON.decode(json),
         true <- Enum.all?(rows, &is_map/1) do
      titles = Map.new(rows, &{&1["id"], &1["title"]})
      {:ok, Enum.map_join(rows, "\n", &ready_row(&1, titles))}
    else
      _not_the_shape_we_render -> :error
    end
  end

  defp ready_row(row, titles) do
    kind = if row["issue_type"] in [nil, "task"], do: "", else: " [#{row["issue_type"]}]"

    parent =
      case parent_of(row) do
        nil -> ""
        id -> " ← #{titles[id] || id}"
      end

    "○ #{row["id"]} P#{row["priority"]}#{kind} #{row["title"]}#{parent}"
  end

  # `--json` is not only JSON: `bd` appends a human sentence after the array —
  # "Showing 6 of 69 ready issues. Use --limit 0 for all…" — and `stderr` is
  # merged into `stdout` here, so a warning can arrive on either side of it.
  # The array is taken by its brackets rather than by trimming known lines,
  # because the set of things `bd` might print around it is not ours to enumerate.
  #
  # This is what the fallback caught on the first run: the JSON path silently
  # became the slow path, and it said so in the injected block instead of
  # quietly costing four seconds a session forever.
  defp array(output) do
    with first when first != nil <- :binary.match(output, "[") |> position(),
         last when last != nil <- last_bracket(output),
         true <- last > first do
      {:ok, binary_part(output, first, last - first + 1)}
    else
      _no_array -> :error
    end
  end

  defp position(:nomatch), do: nil
  defp position({at, _length}), do: at

  defp last_bracket(output) do
    case :binary.matches(output, "]") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  # `bd` gives the parent twice: a `parent` field, and a `parent-child` entry
  # in `dependencies`. The field is read first and the walk is the fallback,
  # because one of the two is a convenience and neither is documented as the
  # contract.
  defp parent_of(row) do
    case row["parent"] do
      id when is_binary(id) and id != "" ->
        id

      _absent ->
        row
        |> Map.get("dependencies", [])
        |> List.wrap()
        |> Enum.find_value(fn
          %{"type" => "parent-child", "depends_on_id" => id} -> id
          _other -> nil
        end)
    end
  end

  # The path for a `bd` that does not know `--brief`, or whose JSON stops being
  # the shape above. It is the behaviour this function had before, and it is
  # **announced** rather than silent: a reader seeing `session_start` take four
  # seconds again should be able to find out why from the block itself.
  defp plain_ready(limit, opts) do
    with {:ok, output} <- run(["ready"], opts) do
      trimmed =
        output |> String.split("\n") |> Enum.take(limit + 4) |> Enum.join("\n") |> String.trim()

      {:ok, trimmed <> "\n(`bd ready --json --brief` was not usable, so this is the slow path.)"}
    end
  end

  @doc """
  One issue as a work item the router understands.

  Returns `{:ok, %{id:, title:, body:, kind:}}`. The parse is deliberately
  forgiving of `bd show`'s formatting: the alternative is a harness that breaks
  when the tracker changes a label, which would make the harness the more
  fragile of the two.
  """
  @spec work_item(String.t()) :: {:ok, map()} | :timeout | :error | :off
  def work_item(id) do
    with {:ok, output} <- run(["show", id]) do
      {:ok,
       %{
         id: id,
         title: field(output, ~r/^(?:Title|#\s*\S+)\s*[:\-]?\s*(.+)$/m) || first_line(output),
         body: output,
         kind: field(output, ~r/^Type:\s*(\w+)/m)
       }}
    end
  end

  defp first_line(output), do: output |> String.split("\n", trim: true) |> List.first()

  defp field(output, regex) do
    case Regex.run(regex, output) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  # `beads` off in `.agents/registry/project.json`: no `bd` is
  # run, and every call answers `:off` — a fourth answer beside `:error`, for
  # the same reason `:timeout` is one: absent, stuck and switched off are
  # three different things to tell a reader.
  defp run(args, opts \\ []) do
    if Noetic.Harness.Integrations.enabled?("beads"), do: run_bd(args, opts), else: :off
  end

  defp run_bd(args, opts) do
    budget = Keyword.get(opts, :timeout, @timeout_ms)
    task = Task.async(fn -> cmd(args, budget) end)

    case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, _refused} -> :error
      nil -> :timeout
      _exited -> :error
    end
  end

  # --- Which database --------------------------------------------------------
  #
  # One bead database, the coordinator's, in the main checkout.

  @doc """
  Whether `bd`, run from `root`, would use the coordinator's database.

  `:ok` when it would; `{:split, why, where, coordinator}` when it would use
  another; `:unknown` when `root` is not in a git checkout, so there is no main
  checkout to compare with.

  A design decision gives the workstation one bead database, the main checkout's
  `.beads/embeddeddolt`. A worktree with no database of its own falls back to
  it, which `bd where --json` confirmed from a fresh `git worktree add` on
  2026-09-23. bd 1.3.0 has four ways to end up on another one, checked here in
  the order bd applies them, each against `bd where --json` in a scratch
  checkout (an earlier change's review):
  1. `BEADS_DIR` names a `.beads` that exists. One that does not exist is
     ignored, and bd falls back.
  2. `BEADS_DB` names a database.
  3. `.beads/redirect` points somewhere, resolved against the checkout root.
     An empty or unreadable one is a split too: bd then uses the worktree's
     own `.beads`, which has no database.
  4. The worktree has a `.beads/embeddeddolt` of its own. This one happened:
     the session worktree ran 264 issues beside the main checkout's 161 for
     days, and nothing said so.

  An earlier rule wins, so a worktree with a database of its own and a
  `BEADS_DIR` naming the main checkout's is fine: bd uses the main one.
  Directories are compared by device and inode where they exist, so a symlink
  to the main checkout is the main checkout.

  **It reads the filesystem instead of asking `bd where`**, and the reason is
  cost. `bd where --json` took 1.2–3.2 s here. The resident `session_start`
  answers in about 70 ms against a 1000 ms ceiling (`Noetic.Harness.Hooks`),
  and one `bd` call would break it; this takes about 5 ms. The price is that it
  mirrors bd's rule rather than asking bd. It does not see `bd --db`, which is
  per command, or a user-level `~/.config/bd/config.yaml`.

  Options: `:beads_dir` and `:beads_db`, standing in for the environment
  variables, so a test need not set a VM-global.
  """
  @spec database_split(Path.t(), keyword()) ::
          :ok | {:split, String.t(), Path.t(), Path.t()} | :unknown
  def database_split(root \\ Noetic.Harness.root(), opts \\ []) do
    env = %{
      beads_dir: Keyword.get_lazy(opts, :beads_dir, fn -> System.get_env("BEADS_DIR") end),
      beads_db: Keyword.get_lazy(opts, :beads_db, fn -> System.get_env("BEADS_DB") end)
    }

    case checkout(root) do
      {:ok, top, main} -> split(top, main, env)
      :error -> :unknown
    end
  end

  defp split(top, main, env) do
    main_beads = Path.join(main, ".beads")
    coordinator = Path.join(main_beads, "embeddeddolt")
    redirect = Path.join([top, ".beads", "redirect"])
    own = Path.join([top, ".beads", "embeddeddolt"])

    cond do
      set?(env.beads_dir) and File.dir?(env.beads_dir) ->
        same_or_split(env.beads_dir, main_beads, "BEADS_DIR names #{env.beads_dir}",
          where: Path.join(Path.expand(env.beads_dir), "embeddeddolt"),
          coordinator: coordinator
        )

      set?(env.beads_db) ->
        if same_dir?(env.beads_db, coordinator) or same_dir?(env.beads_db, main_beads),
          do: :ok,
          else: {:split, "BEADS_DB names #{env.beads_db}", Path.expand(env.beads_db), coordinator}

      File.exists?(redirect) ->
        case redirect_target(redirect, top) do
          {:ok, target} ->
            same_or_split(target, main_beads, ".beads/redirect leads there",
              where: Path.join(target, "embeddeddolt"),
              coordinator: coordinator
            )

          :error ->
            {:split, ".beads/redirect is empty or unreadable, so bd uses this worktree's .beads",
             own, coordinator}
        end

      not same_dir?(top, main) and File.dir?(own) ->
        {:split, "this worktree has a database of its own", own, coordinator}

      true ->
        :ok
    end
  end

  defp set?(value), do: value not in [nil, ""]

  defp same_or_split(path, expected, why, where: where, coordinator: coordinator) do
    if same_dir?(path, expected), do: :ok, else: {:split, why, where, coordinator}
  end

  # bd resolves a relative redirect against the checkout root, the parent of
  # `.beads`, whatever the working directory (checked in a scratch checkout;
  # the first version of this also accepted the `.beads`-relative reading,
  # which hid a real split).
  defp redirect_target(redirect, top) do
    case File.read(redirect) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> :error
          target -> {:ok, Path.expand(target, top)}
        end

      {:error, _} ->
        :error
    end
  end

  # By device and inode when both exist, so a symlink to the main checkout is
  # the main checkout; by expanded path otherwise.
  defp same_dir?(a, b) do
    with {:ok, %File.Stat{major_device: da, inode: ia}} <- File.stat(a),
         {:ok, %File.Stat{major_device: db, inode: ib}} <- File.stat(b) do
      da == db and ia == ib
    else
      _ -> Path.expand(a) == Path.expand(b)
    end
  end

  # Both paths from git, in one call, so they are resolved the same way: a
  # symlink anywhere above the checkout would otherwise make the worktree and
  # the main checkout look like different places, or the same one.
  defp checkout(root) do
    case System.cmd(
           "git",
           ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.split(output, "\n", trim: true) do
          [top, common] -> {:ok, top, Path.dirname(common)}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  # --- Writing -------------------------------------------------------------
  #
  # Until this bead all three functions here read: the harness
  # could see the work queue and not add to it, so a weakness it detected
  # survived only as long as somebody read the telemetry output.

  @marker "harness-cluster"
  @rate_limit 3
  @rate_window_hours 24

  # Higher than the cluster threshold of three, deliberately, and the reason is
  # An earlier change's own last paragraph: `bd` is a real queue a person reads. A
  # cluster is worth *reporting* at three — that is the number WF-020 names and
  # `--clusters` uses. A cluster is worth a slot in somebody's work queue at
  # more than that, because a bead is a claim on attention and three
  # observations is the point at which a pattern becomes arguable rather than
  # established.
  #
  # Measured on the day it was written: at three, this repository's telemetry
  # would have filed three beads, two of which read "3 lessons share the scope
  # <x> out of 37". At five it files one, and that one is 13 routing
  # corrections. That is the difference between a development system that
  # reports weaknesses and one that has optimised its own visibility.
  @file_threshold 5

  # A write is not a read, and this cost a wrong answer the first time the
  # write path ran. `run/2`'s default budget is 10s, which the `timeout`
  # wrapper turns into 11s for the external process — and `bd create` commits
  # to Dolt and re-exports `.beads/issues.jsonl`, which took longer than that.
  # The bead **was created**; the call was killed after it had been, so `file/2`
  # reported `{:error, "could not file the bead"}` about a bead that existed.
  # A second run then correctly said `known`, which is how it was found.
  #
  # Two lessons in one number: a write killed mid-way is not a write that did
  # nothing, and a budget taken from a read is the wrong budget for a write.
  @write_timeout_ms 45_000

  @doc "The label every bead this module files carries, so they can be counted."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc "How many beads this module may file in #{@rate_window_hours} hours."
  @spec rate_limit() :: pos_integer()
  def rate_limit, do: @rate_limit

  @doc "How many observations a cluster needs before it is worth a bead, not just a report."
  @spec file_threshold() :: pos_integer()
  def file_threshold, do: @file_threshold

  @doc "The budget a `bd` **write** gets, which is not the budget a read gets."
  @spec write_timeout() :: pos_integer()
  def write_timeout, do: @write_timeout_ms

  # ---- assignment ------------------------------------------------
  #
  # `Noetic.Harness.Assign` is the only caller. It runs on the coordinator's
  # workstation, where `bd` is; a cloud worker has none and never reaches
  # these. Neither is exercised against a real `bd` in the suite: the tests
  # hand `Assign` a stand-in, because a suite that writes the tracker is a
  # suite that changes the work graph every time it runs.

  @doc """
  An issue's status, read from `bd show <id> --json`, or `:error`.

  `Assign` asks it of every epic a coordination record says is live: a closed
  epic's assignment has ended, whether or not anything wrote a landing record.
  """
  @spec status(String.t()) :: {:ok, String.t()} | :timeout | :error | :off
  def status(id) do
    with {:ok, output} <- run(["show", id, "--json"]) do
      case JSON.decode(output) do
        {:ok, [%{"status" => status} | _]} when is_binary(status) -> {:ok, status}
        {:ok, %{"status" => status}} when is_binary(status) -> {:ok, status}
        _ -> :error
      end
    end
  end

  @doc """
  Record an assignment on the epic: assignee and label `profile:<profile>`,
  status `in_progress`, and `notes` appended.

  `previous` is the profile that holds the epic now, for a reassign.
  bd 1.3.0 refuses an unguarded assignee change to another
  actor's live `in_progress` claim (`validateIssueReassignable`, bd-98s5c),
  and a profile is never the coordinator's actor, so a reassign names its
  holder with `--if-assignee <previous>` — the transfer bd sanctions, which
  writes nothing and exits 13 when the holder is no longer `previous` — and
  takes the old `profile:` label off. A first assign (`previous` nil) carries
  no guard: bd's own fence already refuses another actor's live claim, and an
  `--if-assignee ''` would also refuse the coordinator's own claim on an epic
  it is assigning.
  """
  @spec assign(String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, String.t()}
  def assign(epic, profile, notes, previous \\ nil) do
    guard =
      case previous do
        nil -> []
        ^profile -> ["--if-assignee", previous]
        _ -> ["--if-assignee", previous, "--remove-label", "profile:" <> previous]
      end

    written(
      ["update", epic] ++
        guard ++
        ["--assignee", profile, "--status", "in_progress"] ++
        ["--add-label", "profile:" <> profile, "--append-notes", notes],
      "bd update #{epic}"
    )
  end

  @doc """
  End an assignment: the assignee is cleared, the label comes off, the status
  goes back to `open`, and `notes` say why.

  The assignee is cleared under `--if-assignee <profile>`. bd 1.3.0
  refuses an unguarded assignee change to another actor's live `in_progress`
  claim (`validateIssueReassignable`, bd-98s5c), and the holder here is the
  profile, never the coordinator's actor, so a bare `--assignee ""` would be
  that refusal. Naming the holder is the transfer bd sanctions; when the
  assignee is no longer `profile` it writes nothing and exits 13, and this
  answers `{:error, _}` rather than releasing somebody else's claim.
  """
  @spec release(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def release(epic, profile, notes) do
    written(
      ["update", epic, "--if-assignee", profile, "--assignee", ""] ++
        ["--status", "open", "--remove-label", "profile:" <> profile] ++
        ["--append-notes", notes],
      "bd update #{epic}"
    )
  end

  defp written(args, what) do
    case run(args, timeout: @write_timeout_ms) do
      {:ok, _output} ->
        :ok

      :timeout ->
        {:error,
         "#{what} did not answer within #{div(@write_timeout_ms, 1000)}s; it may have " <>
           "written anyway, so read the issue before trying again"}

      :error ->
        {:error, "#{what} failed"}

      :off ->
        {:error, Noetic.Harness.Integrations.off("beads")}
    end
  end

  @doc """
  The dedup key for a cluster, as a `bd` label.

  Stable across sessions and **independent of wording**, which is the whole
  requirement: the shape and the subject, not the reading. A reading that gets
  rewritten must not produce a second bead for the same weakness, and filing
  the same bead every run is worse than filing none.

  Readable, then hashed. The slug is what a person sees on the bead; the six
  hex characters are what stops two subjects that truncate to the same fifty
  characters from sharing a key.
  """
  @spec cluster_key(map()) :: String.t()
  def cluster_key(cluster) do
    raw = "#{cluster["shape"]}|#{cluster["subject"]}"

    slug =
      raw
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 50)

    digest = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> String.slice(0, 6)

    "hc-#{slug}-#{digest}"
  end

  @doc """
  Whether this cluster may become a bead, and what the bead would say.

  Pure: every guard the bead asks for is here, and the `bd` calls are in
  `file/2`. That split is deliberate — a guard that can only be tested by
  writing to the real tracker is a guard nobody tests.

  Four refusals:

    * **Below the threshold.** `Telemetry.clusters/2` already refuses under the
      population floor, but a hand-assembled map can claim anything.
    * **Naming no change.** An earlier change gave every cluster a `change` field
      and marked the ones that could not fill it in. A bead whose body is "this
      is where the work was" is noise in a queue a person reads.
    * **No evidence.** The count, the population and the reading all have to be
      there. A bead the harness filed about a number it cannot show is worse
      than no bead.
    * **A protected artifact.** Constitution §23 and
      `.agents/policies/evolution.md`: a change to the constitution, the trust
      levels, a gate policy or the security policy is a proposal a human opens.
      The harness may still say so — through
      `noetic-harness evolution --from-cluster`, which produces a candidate that
      `promotable?/1` refuses to land — but it may not put it in the work queue
      as a task.
  """
  @spec fileable(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def fileable(cluster, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @file_threshold)

    cond do
      not Noetic.Harness.Integrations.enabled?("beads") ->
        {:error, Noetic.Harness.Integrations.off("beads")}

      not is_integer(cluster["count"]) or cluster["count"] < threshold ->
        {:error,
         "#{cluster["shape"]} has #{inspect(cluster["count"])} observation(s), and a bead " <>
           "needs #{threshold}. Three is enough to *report* a cluster; a slot in a queue a " <>
           "person reads costs more than that."}

      cluster["actionable"] != true or not is_binary(cluster["change"]) ->
        {:error,
         "#{cluster["shape"]} on #{cluster["subject"]} names no change, so a bead for it " <>
           "would say only where the work was. See `.agents/policies/evolution.md`."}

      not is_binary(cluster["reading"]) or cluster["of"] == nil ->
        {:error,
         "#{cluster["shape"]} carries no reading or no population, and a bead the harness " <>
           "filed about a number it cannot show is worse than no bead."}

      protected?(cluster) ->
        {:error,
         "#{cluster["shape"]} implies a change to the constitution, the trust levels, a gate " <>
           "policy or the security policy. Those are proposals a human opens (constitution " <>
           "§23). `noetic-harness evolution --from-cluster #{cluster["shape"]}` makes it a " <>
           "candidate instead, which `promotable?/1` refuses to land."}

      true ->
        {:ok,
         %{
           key: cluster_key(cluster),
           title: title_for(cluster),
           design: design_for(cluster, opts)
         }}
    end
  end

  # A gate, lane or policy cluster implies an edit to `.agents/policies/`, and
  # that is the protected set. Read from the shape rather than from the change
  # text, because the text is prose and a guard that greps prose is a guard
  # somebody rewords past.
  defp protected?(cluster) do
    String.starts_with?(cluster["shape"] || "", ["gate.", "lane.", "policy.", "trust."])
  end

  defp title_for(cluster) do
    "#{cluster["shape"]} on #{cluster["subject"]}: #{cluster["count"]} of #{cluster["of"]}"
    |> String.slice(0, 120)
  end

  defp design_for(cluster, opts) do
    population = Keyword.get(opts, :population, %{})

    """
    Filed by the harness from its own telemetry. Do not edit the label; it is
    the dedup key and it is what stops this bead being filed again every run.

    WEAKNESS
      #{cluster["shape"]} on #{cluster["subject"]}
      #{cluster["count"]} of #{cluster["of"]}

    READING
      #{cluster["reading"]}

    THE CHANGE THIS IMPLIES
      #{cluster["change"]}

    DRAWN FROM
      #{population["runs"] || "?"} run(s), #{population["memory_records"] || "?"} memory record(s).
      Re-measure with `noetic-harness telemetry --clusters`. If the cluster is
      gone, close this and say so -- a weakness that stopped without anyone
      changing anything is worth knowing about.

    A CANDIDATE INSTEAD OF A TASK
      `noetic-harness evolution --from-cluster #{cluster["shape"]} --subject '#{cluster["subject"]}'`
      turns the same cluster into an evolution candidate with a hypothesis and
      frozen metrics.
    """
  end

  @doc """
  File the bead, or comment on the one that already exists.

  Three outcomes and the second is the interesting one:

    * `{:filed, id}` — no bead carried this key.
    * `{:returned, id}` — a **closed** bead carries it. The weakness came back
      after somebody fixed it, which is the most interesting event this
      machinery can report, and it is a note on the old bead rather than a new
      one. Not reopened: whether it is the same defect or a new one with the
      same shape is a judgement, and the note is what someone judges from.
    * `{:known, id}` — an open bead carries it. Nothing is written.

  Refuses above the rate limit. `bd` is a real queue a person reads, and a
  development system that adds to it faster than anyone empties it has
  optimised its own visibility rather than the work.
  """
  @spec file(map(), keyword()) :: {:filed | :returned | :known, String.t()} | {:error, String.t()}
  def file(cluster, opts \\ []) do
    with {:ok, attrs} <- fileable(cluster, opts),
         :ok <- within_rate_limit(opts) do
      case existing(attrs.key) do
        {:ok, %{"id" => id, "status" => "closed"}} ->
          note =
            "The harness saw this weakness again on #{Date.utc_today()}: " <>
              "#{cluster["count"]} of #{cluster["of"]}. It was closed and it came back. " <>
              "Either the fix did not hold, or this is a different defect with the same " <>
              "shape -- which is a judgement, so nothing was reopened."

          case run(["update", id, "--append-notes", note], timeout: @write_timeout_ms) do
            {:ok, _} -> {:returned, id}
            other -> {:error, "could not comment on #{id}: #{inspect(other)}"}
          end

        {:ok, %{"id" => id}} ->
          {:known, id}

        :none ->
          create(attrs, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp create(attrs, opts) do
    args =
      [
        "create",
        attrs.title,
        "--type",
        "task",
        "--priority",
        to_string(Keyword.get(opts, :priority, 3)),
        "-l",
        "#{@marker},#{attrs.key}",
        "--design",
        attrs.design
      ] ++
        case Keyword.get(opts, :parent) do
          nil -> []
          parent -> ["--parent", parent]
        end

    case run(args, timeout: @write_timeout_ms) do
      {:ok, output} ->
        case Regex.run(~r/\b([a-z0-9]+-[a-z0-9.]+)\b/, output) do
          [_, id] -> {:filed, id}
          _ -> {:filed, "(created; id not parsed from #{String.slice(output, 0, 80)})"}
        end

      :timeout ->
        {:error,
         "`bd` did not answer within #{div(@write_timeout_ms, 1000)}s while filing the bead. " <>
           "Check whether it was created anyway before filing again — a write killed mid-way " <>
           "is not a write that did nothing, and this exact thing happened once."}

      other ->
        {:error, "could not file the bead: #{inspect(other)}"}
    end
  end

  # Open **and** closed, because a closed bead for the same key is the event
  # this machinery exists to notice.
  defp existing(key) do
    case run(["list", "--label", key, "--status", "all", "--json"]) do
      {:ok, output} ->
        case JSON.decode(output) do
          {:ok, rows} when is_list(rows) -> first_issue(rows)
          {:ok, %{"issues" => rows}} -> first_issue(rows)
          _ -> :none
        end

      :timeout ->
        {:error, "`bd` did not answer while looking for an existing bead, so nothing was filed"}

      :error ->
        :none
    end
  end

  defp first_issue([]), do: :none

  defp first_issue(rows) do
    # An open bead wins over a closed one: if both exist the weakness is
    # already somebody's work.
    case Enum.find(rows, &(&1["status"] != "closed")) do
      nil -> {:ok, hd(rows)}
      open -> {:ok, open}
    end
  end

  defp within_rate_limit(opts) do
    limit = Keyword.get(opts, :rate_limit, @rate_limit)

    case run(["list", "--label", @marker, "--status", "all", "--json"]) do
      {:ok, output} ->
        recent = output |> decode_rows() |> Enum.count(&recent?/1)

        if recent < limit do
          :ok
        else
          {:error,
           "#{recent} bead(s) filed by the harness in the last #{@rate_window_hours}h, and the " <>
             "limit is #{limit}. `bd` is a queue a person reads; a development system that " <>
             "fills it faster than anyone empties it has optimised its own visibility."}
        end

      _cannot_tell ->
        # Fail closed. Not knowing how many were filed is not the same as
        # knowing none were.
        {:error, "could not count what the harness has already filed, so nothing was filed"}
    end
  end

  defp decode_rows(output) do
    case JSON.decode(output) do
      {:ok, rows} when is_list(rows) -> rows
      {:ok, %{"issues" => rows}} when is_list(rows) -> rows
      _ -> []
    end
  end

  defp recent?(row) do
    with created when is_binary(created) <- row["created_at"] || row["created"],
         {:ok, at, _} <- DateTime.from_iso8601(created) do
      DateTime.diff(DateTime.utc_now(), at, :hour) < @rate_window_hours
    else
      # A row whose date cannot be read counts as recent: the rate limit is a
      # guard, and a guard that cannot tell errs towards refusing.
      _ -> true
    end
  end

  # `timeout` first when it is there, so that a `bd` we stop waiting for is
  # also a `bd` that stops holding the lock. Its own budget is a second longer
  # than ours, so that the ordinary outcome is our `:timeout` and not a 124 we
  # would have to read back out of an exit status.
  defp cmd(args, budget) do
    {executable, argv} =
      if bounded?() do
        {"timeout", ["-k", "2", "#{div(budget, 1000) + 1}", "bd" | args]}
      else
        {"bd", args}
      end

    System.cmd(executable, argv, cd: Noetic.Harness.root(), stderr_to_stdout: true)
  rescue
    _ -> {"", 127}
  end
end
