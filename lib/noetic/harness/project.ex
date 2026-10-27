defmodule Noetic.Harness.Project do
  @moduledoc """
  What the repository tells the harness about itself: `.agents/registry/project.json`.

  ## Why the engine's paths became data

  The engine read the development repository's files by name: a table in
  `Noetic.Harness.Context` from a context key to a design decision, a
  module of its web application and thirty more; the knowledge base's `docs/kb/…` in five modules; the ADR
  directory in `Assign`; the three services SessionStart probes and the script
  that starts them. None of that is the engine's. It is what this repository
  says, and while it was code, another repository could not use the engine
  without editing it, and no test could tell the engine from the project
  . The values moved here
  unchanged, and the answers the harness gives did not change with them.

  The app layout followed in an earlier change (`layout/0`): where an app's source
  and tests are, the command that runs them and the build directory a
  worktree is seeded from, which `Environments`, `Scoring` and `Tree` named
  as `apps/<app>`, `mix test` and `_build` behind the evaluator fence.

  ## What stays in code

  The engine's own conventions: `.agents/` itself, the files the client
  adapters write (`CLAUDE.md`, `.claude/`, `GEMINI.md`, `.cursor/`, `.codex/`,
  `.gemini/`), `bd`'s `.beads/`, Mix's `_build/` and `lib/` → `test/`, and the
  engine's own commands (`noetic-harness`). Those are what any repository the
  engine serves has, or what a client it serves reads. `PathLiteralsTest` holds
  the list, with the reason for each.

  ## An absent file configures nothing

  A repository with no `project.json` gets no project-specific context
  sources, no knowledge base, no ADR check and no services probe, and each of
  those says it is not configured rather than guessing at another repository's
  layout.
  A file that is present but malformed reads as absent here, and
  `noetic-harness validate` reports it (`validate/1`, through the profiles check:
  `Noetic.Harness.Validation` is behind the evaluator fence).
  """

  alias Noetic.Harness.Integrations
  alias Noetic.Harness.Loader
  alias Noetic.Harness.Validation.Schema

  @kinds ~w(docs files glob)

  @type finding :: {:error | :warning, String.t()}

  @doc "Where the file is."
  @spec path() :: Path.t()
  def path, do: Path.join(Noetic.Harness.agents_path("registry"), "project.json")

  @doc "The schema's path."
  @spec schema_path() :: Path.t()
  def schema_path, do: Path.join(Noetic.Harness.agents_path("schemas"), "project.schema.json")

  @doc """
  The decoded file, or `%{}` when there is none or it does not decode to an
  object. Memoised per process, like every definition file (`Loader.cached_load/1`).
  """
  @spec get() :: map()
  def get do
    case Loader.cached_load(path()) do
      {:ok, %{} = project} -> project
      _ -> %{}
    end
  end

  @doc "The project's name, or `nil`."
  @spec name() :: String.t() | nil
  def name, do: string(get()["name"])

  @doc """
  A knowledge-base path by key (`"extraction"`, `"glossary"`, …), relative to
  the root, or `nil` when it is not configured.
  """
  @spec kb(String.t()) :: String.t() | nil
  def kb(key), do: string(get_in(get(), ["kb", key]))

  @doc "The directories a recorded source path is cut back to; `[]` when none."
  @spec kb_source_roots() :: [String.t()]
  def kb_source_roots, do: strings(get_in(get(), ["kb", "source_roots"]))

  @doc """
  The prefix an ADR numbered `n` has on disk, a design decision here, or
  `nil` when the project declares no ADRs.
  """
  @spec adr_file_prefix(integer()) :: String.t() | nil
  def adr_file_prefix(n) when is_integer(n) do
    case get()["adr"] do
      %{"dir" => dir, "prefix" => prefix, "digits" => digits}
      when is_binary(dir) and is_binary(prefix) and is_integer(digits) ->
        Path.join(dir, prefix <> String.pad_leading(Integer.to_string(n), digits, "0") <> "-")

      _ ->
        nil
    end
  end

  @doc "The services SessionStart probes, as `{name, port}`; `[]` when none."
  @spec services() :: [{String.t(), pos_integer()}]
  def services do
    for %{"name" => name, "port" => port} <- list(get_in(get(), ["services", "probe"])),
        is_binary(name) and is_integer(port),
        do: {name, port}
  end

  @doc "The command that starts the services, or `nil`."
  @spec services_start() :: String.t() | nil
  def services_start, do: string(get_in(get(), ["services", "start"]))

  @doc "A tooling command by key, or `nil`."
  @spec tooling(String.t()) :: String.t() | nil
  def tooling(key), do: string(get_in(get(), ["tooling", key]))

  @typedoc "Where an app's source and tests are, and how its tests run."
  @type layout :: %{
          apps: String.t(),
          lib: String.t(),
          test: String.t(),
          test_suffix: String.t(),
          test_command: [String.t(), ...],
          build: String.t()
        }

  @doc """
  The app layout, or `nil` when the project declares none or declares it
  incompletely: `Environments` cannot derive or verify without one, and says
  so, and `Tree` seeds a worktree with nothing.
  """
  @spec layout() :: layout() | nil
  def layout do
    case get()["layout"] do
      %{
        "apps" => apps,
        "lib" => lib,
        "test" => test,
        "test_suffix" => suffix,
        "test_command" => [_ | _] = command,
        "build" => build
      } ->
        fields = [apps, lib, test, suffix, build | command]

        if Enum.all?(fields, &(is_binary(&1) and &1 != "")),
          do: %{
            apps: apps,
            lib: lib,
            test: test,
            test_suffix: suffix,
            test_command: command,
            build: build
          }

      _ ->
        nil
    end
  end

  @doc "What a caller that needs the layout says when there is none."
  @spec no_layout() :: String.t()
  def no_layout, do: "no layout in .agents/registry/project.json"

  @doc "The bead-database guide, or `nil`."
  @spec beads_guide() :: String.t() | nil
  def beads_guide, do: string(get_in(get(), ["beads", "guide"]))

  @doc """
  The context source for `key`, with `same_as` followed, or `nil` when the
  project declares none. `"key"` in the result is the key the chain ended at:
  a section is named for the source that answered, as it was when the table
  was code. A `same_as` chain that loops or ends nowhere is `nil` here and an
  error in `validate/1`.
  """
  @spec context_source(String.t()) :: map() | nil
  def context_source(key), do: follow(context(get()), key, [])

  defp follow(sources, key, seen) do
    case Map.get(sources, key) do
      %{"same_as" => other} when is_binary(other) ->
        if other in seen, do: nil, else: follow(sources, other, [key | seen])

      %{"kind" => kind} = source when kind in @kinds ->
        if well_formed?(kind, source), do: Map.put(source, "key", key)

      _ ->
        nil
    end
  end

  # A source the context can build a section from. One that is not is `nil`
  # here, so a malformed file is "not attached" on the hook path rather than
  # a crash there; `validate/1` is where it is an error.
  defp well_formed?(kind, source) do
    {field, type} = shape(kind)

    is_binary(source["title"]) and is_binary(source["why"]) and
      typed("", source[field], type) == [] and not is_nil(source[field])
  end

  # ---- validation -----------------------------------------------------------------

  @doc """
  Everything wrong with the file: the schema, then what the schema cannot say,
  then a renamed integration switch (`Noetic.Harness.Integrations.findings/2`):
  its old name alone is a warning, and both names an error.
  `[]` when there is no file, which is a valid way to be a repository.

  Options, for the tests: `:project` (the decoded file, or `:absent`) and
  `:schema` (the decoded schema).
  """
  @spec validate(keyword()) :: [finding()]
  def validate(opts \\ []) do
    with {:ok, project} <- fetch_project(opts),
         {:ok, schema} <- fetch_schema(opts) do
      label = "registry/project.json"

      errors =
        (Schema.validate(project, schema, label) ++ sources(project, label))
        |> Enum.map(&{:error, &1})

      for {level, message} <- errors ++ Integrations.findings(project, label),
          do: {level, "project: " <> message}
    else
      :absent -> []
      {:error, message} -> [{:error, "project: " <> message}]
    end
  end

  defp fetch_project(opts) do
    case Keyword.fetch(opts, :project) do
      {:ok, :absent} ->
        :absent

      {:ok, project} ->
        {:ok, project}

      :error ->
        if File.exists?(path()), do: Loader.load(path()), else: :absent
    end
  end

  defp fetch_schema(opts) do
    case Keyword.fetch(opts, :schema) do
      {:ok, schema} -> {:ok, schema}
      :error -> Loader.load(schema_path())
    end
  end

  defp sources(%{"context" => sources}, label) when is_map(sources) do
    Enum.flat_map(Enum.sort(sources), fn {key, source} -> source(sources, key, source, label) end)
  end

  defp sources(_project, _label), do: []

  defp source(sources, key, %{"same_as" => other} = source, label) do
    at = "#{label}.context.#{key}"

    extra =
      for field <- Map.keys(source), field != "same_as", do: "#{at}: unexpected key #{field}"

    cond do
      not is_binary(other) ->
        ["#{at}: same_as is not a string"]

      is_nil(follow(sources, key, [])) ->
        ["#{at}: same_as #{inspect(other)} names no source, or a chain that loops"]

      true ->
        extra
    end
  end

  defp source(_sources, key, %{"kind" => kind} = source, label) when kind in @kinds do
    at = "#{label}.context.#{key}"
    {field, type} = shape(kind)
    allowed = ["kind", "title", "why", field]

    missing =
      for required <- ["title", "why", field],
          not Map.has_key?(source, required),
          do: "#{at}: missing required key #{required}"

    unexpected =
      for present <- Map.keys(source),
          present not in allowed,
          do: "#{at}: unexpected key #{present} for kind #{kind}"

    wrong =
      for {name, value} <- Map.take(source, ["title", "why"]),
          not (is_binary(value) and value != ""),
          do: "#{at}.#{name}: expected a non-empty string"

    missing ++ unexpected ++ wrong ++ typed(at <> "." <> field, source[field], type)
  end

  defp source(_sources, key, %{"kind" => kind}, label),
    do: [
      "#{label}.context.#{key}: kind #{inspect(kind)} is not one of #{inspect(@kinds)}"
    ]

  defp source(_sources, key, _source, label),
    do: ["#{label}.context.#{key}: a source has a kind (#{Enum.join(@kinds, ", ")}) or a same_as"]

  defp shape("docs"), do: {"glob", :string}
  defp shape("files"), do: {"paths", :list}
  defp shape("glob"), do: {"globs", :list}

  defp typed(_at, nil, _type), do: []

  defp typed(at, value, :string) do
    if relative?(value), do: [], else: ["#{at}: expected a path relative to the root"]
  end

  defp typed(at, value, :list) do
    if is_list(value) and value != [] and Enum.all?(value, &relative?/1),
      do: [],
      else: ["#{at}: expected a non-empty list of paths relative to the root"]
  end

  defp relative?(value), do: is_binary(value) and value != "" and Path.type(value) == :relative

  defp context(project) do
    case project["context"] do
      %{} = sources -> sources
      _ -> %{}
    end
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp strings(value), do: for(item <- list(value), is_binary(item), do: item)
end
