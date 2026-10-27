defmodule Noetic.Harness.Plane do
  @moduledoc """
  The two planes, and where the engine keeps them apart.

  - **`development`** is how a repository is built. Its roles hold tools such
    as `git.write`, its gates run commands, and its runs and memory are files
    committed to git. Every definition written before the field is one, and a
    definition that names no plane still is.
  - **`runtime`** is a product's AI employees. Its roles draft, check and
    propose; what they produce is accepted by a person or by the product's own
    check. The product loads the definitions as data (`harness export`); the
    development engine never runs them.

  ## Where the engine reads the field

  An earlier change added the field and `validate`'s `planes` check, and nothing
  else read it: in a root holding both planes a runtime role was composed
  with the development constitution, a `nucleus: true` runtime role got a
  coding-client adapter, and nothing refused starting a runtime workflow. The
  separation was a label and a choice of root. An earlier change made the engine
  read it:

  | Where | What it refuses |
  |---|---|
  | `Noetic.Harness.Prompt.compose/2` | a role composed from another plane's templates or constitution, with another plane's workflow, or (for a runtime role) a development tool or a command gate; the constitution and templates are picked by the role's plane, and a runtime pack that has none is refused rather than given the development ones |
  | `Noetic.Harness.Workflow.fetch/1` | a runtime workflow: it is the development engine's door, so `Run.start/1`, the conductor and the dispatcher cannot see one |
  | `Noetic.Harness.Router.route/2` | a requested runtime workflow, or a work item whose signals name a runtime capability |
  | `Noetic.Harness.Router.compose_team/3`, `Noetic.Harness.Registry.supplying/2` | a runtime role: no development step is staffed by one |
  | `Noetic.Harness.Registry.nucleus/1`, `Noetic.Harness.Adapters` | a runtime role: `sync` writes no coding-client file for one, whatever its `nucleus` says |
  | `noetic-harness run --start` | a runtime workflow, by name and rule |

  `validate` still refuses what can be refused before anything runs; these
  refuse what reaches the engine anyway.

  ## Where a plane's prompt lives

  The development plane's templates are `.agents/templates/prompt/` and its
  constitution is the manifest's `preamble`, `.agents/constitution.md`. The
  runtime plane's are `.agents/runtime/templates/prompt/` and the preamble
  its manifest names, conventionally `.agents/runtime/constitution.md`. A root
  can hold both, and a runtime-only pack holds only the second.

  Two more inputs are text written for one plane under names both share: the
  archetypes' loops, evidence and prohibitions, and the trust levels' may and
  may-not. The development plane's say "the commands you ran" and "change the
  project's source". `doc/2` picks them by plane: for a runtime role,
  `.agents/runtime/archetypes.json` and `.agents/runtime/trust_levels.json`,
  or the root's own files when they say `"plane": "runtime"` (a runtime-only
  pack); never the development plane's. The ids, `owner` to `investigator` and
  `T0` to `T5`, are the shared structure, and only the text is per plane.
  """

  alias Noetic.Harness.Loader

  @planes ~w(development runtime)

  @typedoc "`development` or `runtime`."
  @type t :: String.t()

  @doc "Both planes, development first."
  @spec all() :: [t()]
  def all, do: @planes

  @doc """
  A definition's plane: `development` when it names none, or when there is no
  definition at all. Every definition written before the field is a
  development one and stays so unchanged.
  """
  @spec of(map() | nil) :: t()
  def of(definition) when is_map(definition), do: Map.get(definition, "plane") || "development"
  def of(_), do: "development"

  @doc "Whether a definition is on the runtime plane."
  @spec runtime?(map() | nil) :: boolean()
  def runtime?(definition), do: of(definition) == "runtime"

  @doc "Whether a definition belongs to `plane`; `:any` takes both."
  @spec in?(map() | nil, t() | :any) :: boolean()
  def in?(_definition, :any), do: true
  def in?(definition, plane), do: of(definition) == plane

  @doc "The directory a plane's prompt templates and their manifest live in."
  @spec templates_dir(t()) :: Path.t()
  def templates_dir("runtime"), do: Noetic.Harness.agents_path("runtime/templates/prompt")
  def templates_dir(_development), do: Noetic.Harness.agents_path("templates/prompt")

  @doc "A plane's template manifest."
  @spec manifest_path(t()) :: Path.t()
  def manifest_path(plane), do: Path.join(templates_dir(plane), "MANIFEST.json")

  @shared %{
    archetypes: {"registry/archetypes.json", "archetypes"},
    trust_levels: {"policies/trust_levels.json", "trust levels"}
  }

  @doc """
  The archetypes or the trust levels written for `plane`.

  Development: the root's file, refused when it says it is the runtime
  plane's. Runtime: `.agents/runtime/<file>`, else the root's file when it
  says `"plane": "runtime"`, else refused: a runtime role is never given the
  development plane's text.
  """
  @spec doc(t(), :archetypes | :trust_levels) :: {:ok, map()} | {:error, String.t()}
  def doc(plane, kind) do
    {file, name} = Map.fetch!(@shared, kind)
    shared = Noetic.Harness.agents_path(file)

    if plane == "runtime" do
      own = Noetic.Harness.agents_path(Path.join("runtime", Path.basename(file)))

      Enum.find_value([own, shared], fn path ->
        case Loader.cached_load(path) do
          {:ok, doc} -> if runtime?(doc), do: {:ok, doc}
          {:error, _} -> nil
        end
      end) ||
        {:error,
         "this root has no runtime #{name}: neither .agents/runtime/#{Path.basename(file)} " <>
           "nor a .agents/#{file} that says plane runtime, and a runtime role is never " <>
           "composed from the development plane's"}
    else
      case Loader.cached_load(shared) do
        {:ok, doc} ->
          if runtime?(doc),
            do:
              {:error,
               ".agents/#{file} is the runtime plane's #{name}, and a development role is " <>
                 "composed from the development plane's"},
            else: {:ok, doc}

        error ->
          error
      end
    end
  end
end
