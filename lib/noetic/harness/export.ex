defmodule Noetic.Harness.Export do
  @moduledoc """
  A root's runtime plane as one JSON document, which a product loads as data
  (`harness export`).

  The product runs its own engine over harness-format definitions. What it
  needs from the harness is therefore what its engine cannot make: the
  definitions, checked; each role's prompt, composed by the same
  `Prompt.compose/2` the development roles use; and each role's grants in one
  place, for the product's check between a model's answer and an action.

  ## What it writes

  - `export`: this format's version, `1`.
  - `pack`: the pack's `name` and `version`, from the runtime manifest's
    `pack` (`.agents/runtime/templates/prompt/MANIFEST.json`). The person
    releasing the pack sets them; nothing here derives one.
  - `hash`: sha256 over the canonical encoding (`Noetic.Harness.Canonical`)
    of everything else in the document. It is a hash of what the product
    loads, not of the files it came from: a change to a development
    definition in the same root does not change it, and a hand edit to the
    exported file is found by recomputing it.
  - `definitions`: the runtime plane's roles, capabilities, workflows and
    tools, as written, with `"plane": "runtime"`; and the gates and lanes
    they name. A gate's kind is `check`, `evidence`, `review` or `manual`.
  - `roles`: per runtime role, its standing `prompt`, its prompt at each
    workflow step its capabilities let it take (`steps`), and its `grants`:
    the tools its trust ceiling grants (with each tool's kind and minimum
    trust), the ceiling, the gates on its own work grouped by kind (its own,
    its capabilities' and its steps'; a lane's gates judge a workflow's whole
    output and stay with the lane), and its escalations (the pack's standing
    ones, and those of each workflow it takes a step in).

  ## What it refuses, and what it never writes

  It refuses a root whose definitions fail `validate`'s definition checks
  (`definition_checks/0`), the `planes` check among them, so no export holds a
  definition that mixes the planes; a root with no runtime role; and a runtime
  manifest with no `pack`. Of `validate`'s other checks, seven read files of
  the development process a runtime pack does not carry, and the `adapters`
  check renders a coding client's files; they are a development root's, and
  run there.

  It never writes a command, a path into the harness or the root, or any text
  of the development plane: each prompt is composed from the runtime plane's
  own constitution and templates, which `Prompt.compose/2` refuses to mix, and
  no command gate reaches a runtime definition past `planes`. `$schema` keys,
  which are paths, are dropped.
  """

  alias Noetic.Harness.{Canonical, Loader, Plane, Policy, Prompt, Registry, Validation, Workflow}

  @format 1

  # The checks that read a pack's definitions. The rest read the development
  # process: the evaluator fence, pipelines, failure routing, the generated
  # coding-client adapters, MCP and the model families.
  @definition_checks ~w(registry overlays overlay_tool_claims overlay_authority skills tools
                        planes gates workflows prompts memory questions profiles)a

  @kinds ~w(check evidence review manual)

  @doc "The `validate` checks an export runs first."
  @spec definition_checks() :: [atom()]
  def definition_checks, do: @definition_checks

  @doc """
  The export of the current root's runtime plane, or why there is none: a
  list of messages, the definition checks' errors when they failed.
  """
  @spec build() :: {:ok, map()} | {:error, [String.t()]}
  def build do
    with :ok <- valid(),
         {:ok, pack} <- pack(),
         {:ok, registry} <- Registry.load(),
         {:ok, roles} <- runtime_roles(registry),
         {:ok, workflows} <- Workflow.list("runtime"),
         {:ok, tool_defs} <- Policy.tools_by_id(),
         {:ok, gates_doc} <- Policy.gates() do
      gate_defs = Map.new(gates_doc["gates"], &{&1["id"], &1})
      lanes = gates_doc["lanes"] || []
      capabilities = registry.capabilities |> Map.values() |> Enum.filter(&Plane.runtime?/1)

      ctx = %{
        registry: registry,
        workflows: workflows,
        tool_defs: tool_defs,
        gate_defs: gate_defs,
        lanes: lanes
      }

      body = %{
        "export" => @format,
        "pack" => pack,
        "definitions" => %{
          "roles" => Enum.map(roles, &data/1),
          "capabilities" => sorted(capabilities),
          "workflows" => Enum.map(workflows, &data/1),
          "tools" => tool_defs |> Map.values() |> Enum.filter(&Plane.runtime?/1) |> sorted(),
          "gates" =>
            ctx |> named_gates(roles) |> Enum.map(&Map.fetch!(gate_defs, &1)) |> sorted(),
          "lanes" => ctx |> named_lanes() |> sorted()
        },
        "roles" => Enum.map(roles, &role(&1, ctx))
      }

      {:ok, Map.put(body, "hash", Canonical.hash(body))}
    else
      {:error, messages} when is_list(messages) -> {:error, messages}
      {:error, message} -> {:error, [message]}
    end
  end

  @doc """
  The document as the file holds it: two-space JSON, object keys sorted at
  every depth, one newline at the end, so that a release's export reviews as a
  diff.
  """
  @spec encode(map()) :: String.t()
  def encode(export), do: (export |> nulls() |> :json.format() |> IO.iodata_to_binary()) <> "\n"

  @doc "Whether `export`'s hash is the hash of the rest of it."
  @spec intact?(map()) :: boolean()
  def intact?(%{"hash" => hash} = export), do: Canonical.hash(Map.delete(export, "hash")) == hash
  def intact?(_), do: false

  # ---- refusals ------------------------------------------------------------

  defp valid do
    {:ok, findings} = Validation.run(@definition_checks)

    case for({:error, message} <- findings, do: message) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp pack do
    path = Plane.manifest_path("runtime")

    case Loader.cached_load(path) do
      {:ok, %{"pack" => %{"name" => name, "version" => version}}}
      when is_binary(name) and name != "" and is_binary(version) and version != "" ->
        {:ok, %{"name" => name, "version" => version}}

      {:ok, _} ->
        {:error,
         ".agents/runtime/templates/prompt/MANIFEST.json names no pack: an export needs " <>
           ~s|"pack": {"name": ..., "version": ...}, which the person releasing it sets|}

      {:error, _} ->
        {:error,
         "this root has no runtime templates (.agents/runtime/templates/prompt/MANIFEST.json), " <>
           "so it has no runtime pack to export"}
    end
  end

  defp runtime_roles(registry) do
    case registry |> Registry.on_plane("runtime") |> Enum.sort_by(& &1["id"]) do
      [] ->
        {:error,
         "this root has no runtime role: an export is a product's AI employees, and a " <>
           "development role is never exported"}

      roles ->
        {:ok, roles}
    end
  end

  # ---- a role --------------------------------------------------------------

  defp role(agent, ctx) do
    steps = steps_for(agent, ctx.workflows)

    %{
      "id" => agent["id"],
      "prompt" => Prompt.compose!(agent["id"]),
      "steps" =>
        for {workflow, step} <- steps do
          %{
            "workflow" => workflow["id"],
            "step" => step["id"],
            "prompt" => Prompt.compose!(agent["id"], workflow: workflow["id"], step: step["id"])
          }
        end,
      "grants" => grants(agent, steps, ctx)
    }
  end

  # Every workflow step one of the role's capabilities covers.
  defp steps_for(agent, workflows) do
    held = MapSet.new(agent["capabilities"] || [])

    for workflow <- workflows,
        step <- workflow["steps"],
        Enum.any?(step["capabilities"] || [], &MapSet.member?(held, &1)),
        do: {workflow, step}
  end

  defp grants(agent, steps, ctx) do
    ceiling = agent["max_trust"]
    {granted, _withheld} = Policy.grant_tools(agent["tools"] || [], ceiling, ctx.tool_defs)

    # The gates on this role's own work: its own, its capabilities', and its
    # steps'. A workflow's lane judges the workflow's output, whoever wrote
    # each part, so it is in `definitions.lanes` and not in a role's grants.
    gates =
      (own_gates(agent, ctx.registry) ++
         Enum.flat_map(steps, fn {_, step} -> step["gates"] || [] end))
      |> Enum.uniq()

    %{
      "trust_ceiling" => ceiling,
      "tools" =>
        for id <- granted do
          tool = Map.fetch!(ctx.tool_defs, id)
          %{"id" => id, "kind" => tool["kind"], "min_trust" => tool["min_trust"]}
        end,
      "gates" =>
        Map.new(@kinds, fn kind ->
          {kind,
           gates |> Enum.filter(&(get_in(ctx.gate_defs, [&1, "kind"]) == kind)) |> Enum.sort()}
        end),
      "escalations" => %{
        "standing" => standing_escalations(),
        "workflows" =>
          for workflow <- steps |> Enum.map(&elem(&1, 0)) |> Enum.uniq_by(& &1["id"]),
              escalation <- workflow["escalations"] || [] do
            Map.put(Map.take(escalation, ["when", "to"]), "workflow", workflow["id"])
          end
      }
    }
  end

  defp own_gates(agent, registry) do
    (agent["gates"] || []) ++
      Enum.flat_map(
        agent["capabilities"] || [],
        &(get_in(registry.capabilities, [&1, "gates"]) || [])
      )
  end

  defp standing_escalations do
    {:ok, manifest} = Loader.cached_load(Plane.manifest_path("runtime"))
    get_in(manifest, ["defaults", "escalations"]) || []
  end

  # ---- what the definitions name -------------------------------------------

  defp named_gates(ctx, roles) do
    from_roles = Enum.flat_map(roles, &own_gates(&1, ctx.registry))

    from_workflows =
      Enum.flat_map(ctx.workflows, fn workflow ->
        Enum.flat_map(workflow["steps"], &(&1["gates"] || [])) ++
          lane_gates(workflow["default_lane"], ctx)
      end)

    (from_roles ++ from_workflows) |> Enum.uniq() |> Enum.filter(&Map.has_key?(ctx.gate_defs, &1))
  end

  defp named_lanes(ctx) do
    ctx.workflows
    |> Enum.map(& &1["default_lane"])
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&lane_closure(&1, ctx, MapSet.new()))
    |> Enum.uniq_by(& &1["id"])
  end

  # A lane, and every lane it names.
  defp lane_closure(id, ctx, seen) do
    lane = Enum.find(ctx.lanes, &(&1["id"] == id))

    if is_nil(lane) or MapSet.member?(seen, id) do
      []
    else
      seen = MapSet.put(seen, id)

      [lane | Enum.flat_map(lane["gates"] || [], &lane_closure(&1, ctx, seen))]
    end
  end

  defp lane_gates(nil, _ctx), do: []

  defp lane_gates(id, ctx) do
    id
    |> lane_closure(ctx, MapSet.new())
    |> Enum.flat_map(&(&1["gates"] || []))
    |> Enum.filter(&Map.has_key?(ctx.gate_defs, &1))
  end

  # ---- encoding ------------------------------------------------------------

  # A definition as data: as written, less `$schema`, which is a path.
  defp data(definition), do: Map.delete(definition, "$schema")

  defp sorted(definitions), do: definitions |> Enum.map(&data/1) |> Enum.sort_by(& &1["id"])

  # `:json.format/1` writes `nil` as the string "nil".
  defp nulls(nil), do: :null
  defp nulls(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, nulls(v)} end)
  defp nulls(list) when is_list(list), do: Enum.map(list, &nulls/1)
  defp nulls(value), do: value
end
