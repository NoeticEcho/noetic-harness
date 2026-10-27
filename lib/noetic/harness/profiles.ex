defmodule Noetic.Harness.Profiles do
  @moduledoc """
  Who may change what: `.agents/registry/profiles.json` (plan 02 D1).

  A profile is a kind of cloud worker, named by `HARNESS_AGENT` in its
  environment, and it owns paths. `Noetic.Harness.Assign` gives an epic a
  scope inside one profile's paths and refuses one that shares a tracked file
  with another live assignment, so two workers never edit one file and a
  landing never meets a conflict it could have been told about.

  ## A file's class

  Every tracked file has exactly one, and it is the **first** of these that
  matches:

  | class | from | what it means |
  |---|---|---|
  | `:refused` | `refused` | no assignment may scope or grant it (`.beads/**`) |
  | `:fenced` | `.agents/policies/evaluators.json` | changed only with the person's approval |
  | `:held` | `coordinator.held` | coordinator-held: a grant, and `--ack` to land |
  | `:per_epic` | `per_epic` | `.agents/handoff/<epic>.json`, writable only by that epic |
  | `:add_only` | `add_only` | any epic may add one; none may modify or delete one |
  | `{:owned, ids}` | a profile's `owns`, less its `except` | the profile(s) whose scope it is |
  | `:unowned` | nothing | a defect: `validate/0` names it |

  First match rather than exactly one, because the classes nest on purpose:
  `.agents/**` is the harness profile's, and inside it the runs are add-only,
  the policies are fenced and `profiles.json` itself is held. Writing the
  harness profile's globs to avoid every one of those would be a list nobody
  could check; ordering the classes is one rule.

  ## What the schema cannot say

  `validate/0` checks it: a profile glob that matches no tracked file (a typo
  or a file that went away; either way the scope it describes is not the one
  in the file), a tracked file nothing claims, a tracked file two profiles own
  that `shared` does not declare, an unknown domain or workflow, and two
  profiles with one id or one environment.

  **`noetic-harness validate` runs it** as its `profiles` check
  (`check_profiles` in `Noetic.Harness.Validation`), which adds what a
  tracked file cannot show: an id outside the six cloud profiles, a profile
  with no environment, a glob two profiles both list before any file lands
  under it, and a `shared` entry naming a profile that does not exist.
  `noetic-harness profiles --check` runs that same check on its own.
  """

  alias Noetic.Harness.{Fence, Glob, Loader}
  alias Noetic.Harness.Validation.Schema

  @type class ::
          {:refused, String.t()}
          | {:fenced, String.t()}
          | {:held, String.t()}
          | {:per_epic, String.t()}
          | {:add_only, String.t()}
          | {:owned, [String.t()]}
          | :unowned

  @type finding :: {:error | :warning, String.t()}

  @doc "Where the definitions live."
  @spec path() :: Path.t()
  def path, do: Path.join(Noetic.Harness.agents_path("registry"), "profiles.json")

  @doc """
  The definitions, as loaded. With `workers` off in `project.json`
  there are no profiles, whatever is on disk: the protocol they
  belong to is not this repository's, and an empty list is what is true of it.
  """
  @spec load() :: {:ok, map()} | {:error, String.t()}
  def load do
    if Noetic.Harness.Integrations.enabled?("workers"),
      do: Loader.load(path()),
      else: {:ok, %{"version" => 1, "profiles" => []}}
  end

  @doc "Every profile id, in the file's order."
  @spec ids(map()) :: [String.t()]
  def ids(doc), do: Enum.map(doc["profiles"], & &1["id"])

  @doc "One profile, or `:error`."
  @spec profile(map(), String.t()) :: {:ok, map()} | :error
  def profile(doc, id) do
    case Enum.find(doc["profiles"], &(&1["id"] == id)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  @doc """
  The files git tracks, root-relative, spelled as they are on disk.

  `core.quotePath=false`, because git otherwise octal-escapes a path with a
  byte outside ASCII and wraps it in quotes, and 37 files under `_refdoc/`
  have one: a glob would be matched against the quoted spelling and miss.
  """
  @spec tracked() :: {:ok, [String.t()]} | {:error, String.t()}
  def tracked do
    case System.cmd("git", ["-c", "core.quotePath=false", "ls-files", "-z"],
           cd: Noetic.Harness.root(),
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.split(output, <<0>>, trim: true)}
      {output, _} -> {:error, "git ls-files: " <> String.trim(output)}
    end
  rescue
    error -> {:error, "git ls-files: " <> Exception.message(error)}
  end

  @doc """
  A classifier: a function from a path to its class.

  Compiled once, because `validate/0` asks it about every tracked file (5,128
  as this is written) and each question tests a few hundred globs. `epic`
  narrows the per-epic class to that epic's own files; without it, any epic's
  handoff is per-epic.
  """
  @spec classifier(map(), keyword()) :: (String.t() -> class())
  def classifier(doc, opts \\ []) do
    fence = Keyword.get_lazy(opts, :fence, &fence_globs/0)
    epic = Keyword.get(opts, :epic)

    per_epic =
      Enum.map(doc["per_epic"], fn %{"glob" => glob} ->
        String.replace(glob, "{epic}", epic || "*")
      end)

    ordered = [
      {:refused, Enum.map(doc["refused"], & &1["glob"])},
      {:fenced, fence},
      {:held, Enum.map(doc["coordinator"]["held"], & &1["glob"])},
      {:per_epic, per_epic},
      {:add_only, Enum.map(doc["add_only"], & &1["glob"])}
    ]

    compiled =
      for {class, globs} <- ordered do
        {class, Enum.map(globs, &{&1, Glob.compile(&1)})}
      end

    owners =
      for profile <- doc["profiles"] do
        {profile["id"], Enum.map(profile["owns"], &Glob.compile/1),
         Enum.map(profile["except"] || [], &Glob.compile/1)}
      end

    fn path ->
      Enum.find_value(compiled, fn {class, globs} ->
        case Enum.find(globs, fn {_glob, regex} -> Regex.match?(regex, path) end) do
          {glob, _regex} -> {class, glob}
          nil -> nil
        end
      end) || owned(owners, path)
    end
  end

  defp owned(owners, path) do
    case for {id, owns, except} <- owners,
             Glob.any?(owns, path),
             not Glob.any?(except, path),
             do: id do
      [] -> :unowned
      ids -> {:owned, ids}
    end
  end

  @doc "The fenced globs, or none when the fence cannot be read (validate says so)."
  @spec fence_globs() :: [String.t()]
  def fence_globs do
    case Fence.entries() do
      {:ok, entries} -> Enum.map(entries, & &1["glob"])
      {:error, _} -> []
    end
  end

  @doc """
  Everything wrong with the definitions, as the validator's findings.

  Options, for the tests: `:doc` (the definitions), `:tracked` (the file list)
  and `:fence` (the fenced globs), each read from the repository when absent.
  `:domain_owns` (a map of domain id to its `owns`) is the domains' side of
  the agreement below; a caller that states `:domains` and not `:domain_owns`
  is not asked about the agreement.

  **`domains.json` agrees with this file**. The two describe one
  tree from two sides — a domain is a competency, a profile is a worker — and
  nothing held them together: the harness profile's domains owned none of the
  harness, and a domain glob matched nothing. Three errors keep them together:
  a domain glob that matches no tracked file, a profile listing a domain that
  owns none of that profile's files, and a file a profile owns that no domain
  owns. A domain `owns` entry ending in `/` is the directory's whole tree.

  **The coordination records pass their schema**:
  `Noetic.Harness.Coordination.validate/1`, given `opts[:coordination]`. This
  file declares them an add-only class, and `Validation`, where a check of
  their own would go, is behind the evaluator fence. They are checked whether
  or not this file is well formed.

  **So is `project.json`**: `Noetic.Harness.Project.validate/1`,
  given `opts[:project]`, for the same reason — `Validation` is fenced.
  """
  @spec validate(keyword()) :: [finding()]
  def validate(opts \\ []) do
    workers(opts) ++ Noetic.Harness.Project.validate(Keyword.get(opts, :project, []))
  end

  # Profiles and coordination records are the coordinator protocol's:
  # with `workers` off, neither is checked, and `project.json`
  # still is.
  defp workers(opts) do
    if Noetic.Harness.Integrations.enabled?("workers"),
      do:
        profiles(opts) ++
          Noetic.Harness.Coordination.validate(Keyword.get(opts, :coordination, [])),
      else: []
  end

  defp profiles(opts) do
    with {:ok, doc} <- fetch(opts, :doc, &load/0),
         [] <- schema_errors(doc, opts),
         {:ok, files} <- fetch(opts, :tracked, &tracked/0) do
      fence = Keyword.get_lazy(opts, :fence, &fence_globs/0)
      classify = classifier(doc, fence: fence)
      classes = Map.new(files, &{&1, classify.(&1)})

      identity(doc) ++
        references(doc, opts) ++
        empty_globs(doc, files) ++
        unowned(classes) ++
        doubly_owned(doc, classes) ++
        domains(doc, files, classes, opts)
    else
      {:error, message} -> [{:error, "profiles: " <> message}]
      errors when is_list(errors) -> errors
    end
  end

  defp fetch(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> default.()
    end
  end

  defp schema_errors(doc, opts) do
    schema_path =
      Keyword.get_lazy(opts, :schema, fn ->
        Path.join(Noetic.Harness.agents_path("schemas"), "profiles.schema.json")
      end)

    case Loader.load(schema_path) do
      {:ok, schema} ->
        doc |> Schema.validate(schema, "registry/profiles.json") |> Enum.map(&{:error, &1})

      {:error, message} ->
        [{:error, "profiles: " <> message}]
    end
  end

  defp identity(doc) do
    for {key, label} <- [{"id", "id"}, {"environment", "environment"}],
        {value, count} <- Enum.frequencies_by(doc["profiles"], & &1[key]),
        count > 1 do
      {:error, "profiles: #{count} profiles have the #{label} #{inspect(value)}"}
    end
  end

  # Domains and workflows are names other files define. A profile naming one
  # that does not exist would route a brief to a workflow nobody can open.
  defp references(doc, opts) do
    domains = Keyword.get_lazy(opts, :domains, &known_domains/0)
    workflows = Keyword.get_lazy(opts, :workflows, &known_workflows/0)

    for profile <- doc["profiles"],
        {kind, names, known} <- [
          {"domain", profile["domains"], domains},
          {"workflow", profile["workflows"], workflows}
        ],
        known != :unknown,
        name <- names,
        name not in known do
      {:error, "profiles: #{profile["id"]} names the #{kind} #{name}, which does not exist"}
    end
  end

  defp known_domains do
    case Loader.load(Path.join(Noetic.Harness.agents_path("registry"), "domains.json")) do
      {:ok, %{"domains" => domains}} -> Enum.map(domains, & &1["id"])
      _ -> :unknown
    end
  end

  defp known_workflows do
    Noetic.Harness.agents_path("workflows")
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Loader.load(path) do
        {:ok, %{"id" => id}} -> [id]
        _ -> []
      end
    end)
  end

  # A profile glob that matches nothing describes a scope that is not the one
  # in the file: a typo, or a file that moved. An error, as the bead asks. For
  # the classes it is a warning: a held path that does not exist yet (a
  # `.credo.exs` nobody has written) still says something true about the day
  # it does.
  defp empty_globs(doc, files) do
    profile_globs =
      for profile <- doc["profiles"],
          glob <- profile["owns"] ++ (profile["except"] || []),
          do: {:error, profile["id"], glob}

    class_globs =
      for {section, entries} <- [
            {"coordinator.held", doc["coordinator"]["held"]},
            {"refused", doc["refused"]},
            {"add_only", doc["add_only"]},
            {"shared", doc["shared"]}
          ],
          %{"glob" => glob} <- entries,
          do: {:warning, section, glob}

    for {severity, where, glob} <- profile_globs ++ class_globs,
        regex = Glob.compile(glob),
        not Enum.any?(files, &Regex.match?(regex, &1)) do
      {severity, "profiles: #{where}'s glob #{glob} matches no tracked file"}
    end
  end

  @listed 20

  # ---- the agreement with domains.json -----------------------------

  defp domains(doc, files, classes, opts) do
    owns =
      Keyword.get_lazy(opts, :domain_owns, fn ->
        if Keyword.has_key?(opts, :domains), do: :skip, else: domain_owns()
      end)

    case owns do
      owns when is_map(owns) ->
        compiled = Map.new(owns, fn {id, globs} -> {id, Enum.map(globs, &domain_glob/1)} end)

        owned =
          for {path, {:owned, ids}} <- classes, id <- ids, reduce: %{} do
            acc -> Map.update(acc, id, [path], &[path | &1])
          end

        dead_domain_globs(owns, files) ++
          idle_domains(doc, compiled, owned) ++ domainless(compiled, owned)

      _ ->
        []
    end
  end

  defp domain_owns do
    case Loader.load(Path.join(Noetic.Harness.agents_path("registry"), "domains.json")) do
      {:ok, %{"domains" => domains}} -> Map.new(domains, &{&1["id"], &1["owns"] || []})
      _ -> :unknown
    end
  end

  defp domain_glob(glob) do
    if String.ends_with?(glob, "/"), do: Glob.compile(glob <> "**"), else: Glob.compile(glob)
  end

  defp dead_domain_globs(owns, files) do
    for {id, globs} <- Enum.sort(owns),
        glob <- globs,
        regex = domain_glob(glob),
        not Enum.any?(files, &Regex.match?(regex, &1)) do
      {:error, "domains: #{id}'s #{glob} matches no tracked file"}
    end
  end

  defp idle_domains(doc, compiled, owned) do
    for profile <- doc["profiles"],
        domain <- profile["domains"],
        regexes = Map.get(compiled, domain, []),
        mine = Map.get(owned, profile["id"], []),
        mine != [],
        not Enum.any?(mine, fn path -> Enum.any?(regexes, &Regex.match?(&1, path)) end) do
      {:error,
       "profiles: #{profile["id"]} lists the domain #{domain}, which owns none of " <>
         "#{profile["id"]}'s #{length(mine)} files"}
    end
  end

  defp domainless(compiled, owned) do
    regexes = compiled |> Map.values() |> List.flatten()

    for {id, paths} <- Enum.sort(owned),
        orphans = Enum.reject(paths, fn path -> Enum.any?(regexes, &Regex.match?(&1, path)) end),
        orphans != [] do
      shown = orphans |> Enum.sort() |> Enum.take(@listed)

      {:error,
       "profiles: #{length(orphans)} of #{id}'s file(s) no domain in domains.json owns: " <>
         Enum.join(shown, ", ")}
    end
  end

  defp unowned(classes) do
    case classes
         |> Enum.filter(fn {_path, class} -> class == :unowned end)
         |> Enum.map(&elem(&1, 0)) do
      [] ->
        []

      paths ->
        shown = paths |> Enum.sort() |> Enum.take(@listed)
        more = if length(paths) > @listed, do: " (and #{length(paths) - @listed} more)", else: ""

        [
          {:error,
           "profiles: #{length(paths)} tracked file(s) no profile or class claims: " <>
             Enum.join(shown, ", ") <> more}
        ]
    end
  end

  defp doubly_owned(doc, classes) do
    shared =
      for %{"glob" => glob, "profiles" => ids} <- doc["shared"],
          do: {Glob.compile(glob), MapSet.new(ids)}

    classes
    |> Enum.flat_map(fn
      {path, {:owned, [_, _ | _] = ids}} ->
        declared =
          Enum.any?(shared, fn {regex, allowed} ->
            Regex.match?(regex, path) and MapSet.subset?(MapSet.new(ids), allowed)
          end)

        if declared, do: [], else: [{Enum.sort(ids), path}]

      _ ->
        []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {ids, paths} ->
      shown = paths |> Enum.sort() |> Enum.take(@listed)

      {:error,
       "profiles: #{length(paths)} file(s) owned by #{Enum.join(ids, " and ")}, " <>
         "which `shared` does not declare: " <> Enum.join(shown, ", ")}
    end)
  end
end
