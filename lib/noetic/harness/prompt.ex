defmodule Noetic.Harness.Prompt do
  @moduledoc """
  Composing a runtime subagent prompt.

      constitution
        + archetype        the working loop, evidence and prohibitions
        + domain           where in the repository this role lives
        + role overlay     the operational specifics, when the role has any
        + capabilities     what it owns, resolved to skills, tools and gates
        + trust            what it may do, as the minimum of role and step
        + workflow         which step, which inputs, which escalations
        + task context     the bundle the Context Builder assembled
        = prompt

  ## Why it is composed rather than written

  Two hundred and seventy hand-written prompts drift. One of them says "run the
  tests"; another says "run `mix test`"; a third forgets to mention that a
  compile is not a render. Composition means the evidence contract, the
  escalation rule and the security section are *the same text* in every prompt,
  because they come from the same file — and improving that text improves 270
  prompts at once, which is also what makes the prompt layer an evolvable
  artifact rather than 270 separate ones.

  The specificity that would be lost is recovered from three places: the
  archetype gives the working loop, the capabilities give the concrete evidence
  requirements, and `.agents/roles/<id>.md` gives the operational detail for
  roles that have specifics worth spelling out.

  ## Strict rendering

  An unknown `{{placeholder}}` raises. A section that renders empty when its
  manifest entry says `required: true` raises. Both are how "every agent can
  produce a prompt" stays a checkable claim: a template that silently rendered a
  blank evidence contract would produce a prompt that looks complete and asks
  for nothing.

  ## By plane

  The role's plane picks the template manifest and, through the manifest's
  `preamble`, the constitution (`Noetic.Harness.Plane`). A runtime role is
  composed from the runtime plane's or not at all: a root with no runtime
  templates refuses it rather than giving it the development ones, and so
  does a runtime manifest that declares no `"plane": "runtime"`, names the
  development constitution as its preamble or carries a copy of it.

  Four values the templates render were development text written into this
  module: three lines of every role's non-scope ("the human architect's",
  "any contract, boundary or ADR change"), the escalations of a prompt with no
  workflow, the lane `focused`, and the evidence asked for when nothing else
  says ("the commands you ran"). They are `development_defaults/0` now, and a
  runtime manifest supplies its own under `defaults`, every key of them, or
  the role is refused. A runtime prompt never borrows one.

  Composition also refuses a mix it is asked for: a role with another plane's
  workflow, and a runtime role holding a development tool or reaching a
  command gate through its own gates or its lane. `validate` refuses the same
  definitions before anything is composed; this is the engine refusing them
  when they arrive anyway.
  """

  alias Noetic.Harness.{Context, Loader, Plane, Policy, Registry, Skills, Workflow}

  # What the development templates are given where a definition says nothing.
  # Development text, so a runtime manifest must replace every one of these.
  @development_defaults %{
    "non_scope" => [
      "project direction, protected values, and anything irreversible — the human architect's;",
      "any contract, boundary or ADR change — propose it, do not land it;",
      "the definition of any gate, evaluator, benchmark or holdout that judges this work;",
      "work belonging to a capability you do not hold."
    ],
    "escalations" => [
      "anything requiring a trust level above yours;",
      "anything the human architect owns."
    ],
    "lane" => "focused",
    "evidence" => "(the commands you ran and their output)"
  }

  @type opts :: [
          workflow: String.t(),
          step: String.t(),
          task: map(),
          context: Context.bundle() | nil,
          trust: String.t() | nil
        ]

  @doc """
  Compose the prompt for one agent.

  With no workflow and no task this produces the agent's *standing* prompt —
  what it is, what it owns, how it works — which is exactly what the client
  adapters write to disk. With a workflow step and a task bundle it produces the
  runtime prompt for one unit of work.
  """
  @spec compose(String.t(), opts()) :: {:ok, String.t()} | {:error, String.t()}
  def compose(agent_id, opts \\ []) do
    with {:ok, registry} <- Registry.load(),
         {:ok, agent} <- fetch_agent(registry, agent_id),
         plane = Plane.of(agent),
         {:ok, manifest} <- manifest(plane, agent_id),
         {:ok, constitution} <- constitution(plane, manifest),
         {:ok, defaults} <- defaults(plane, manifest),
         {:ok, workflow} <- load_workflow(opts[:workflow], agent_id, plane),
         {:ok, archetypes} <- Plane.doc(plane, :archetypes),
         {:ok, trust_doc} <- Plane.doc(plane, :trust_levels),
         {:ok, tool_defs} <- Policy.tools_by_id(),
         {:ok, gate_defs} <- Policy.gates_by_id() do
      step = find_step(workflow, opts[:step])
      trust = Policy.resolve_trust(agent["max_trust"], opts[:trust] || step["trust"])
      lane = opts[:lane] || (workflow && workflow["default_lane"]) || defaults["lane"]

      with :ok <- runtime_supply(plane, agent, registry, lane, tool_defs, gate_defs) do
        values =
          build_values(agent, registry, %{
            plane: plane,
            defaults: defaults,
            archetypes: Map.new(archetypes["archetypes"] || [], &{&1["id"], &1}),
            workflow: workflow,
            step: step,
            trust: trust,
            trust_doc: trust_doc,
            tool_defs: tool_defs,
            gate_defs: gate_defs,
            task: opts[:task] || %{},
            bundle: opts[:context],
            lane: lane
          })

        case render_sections(manifest, values, Plane.templates_dir(plane)) do
          {:ok, body} -> {:ok, String.trim(constitution) <> "\n\n---\n\n" <> body}
          error -> error
        end
      end
    end
  end

  @doc "Compose or raise."
  @spec compose!(String.t(), opts()) :: String.t()
  def compose!(agent_id, opts \\ []) do
    case compose(agent_id, opts) do
      {:ok, prompt} -> prompt
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Every placeholder the templates use that the renderer does not supply.

  The validator calls this: a template referring to `{{agent.mission}}` when
  nothing produces one is a section that would render a literal `{{...}}` into a
  prompt, which is worse than a missing section because it looks like an
  instruction.
  """
  #
  # Every plane whose templates the root carries; with neither, the
  # development plane's, whose absence is then the answer.
  @spec unknown_placeholders() :: {:ok, [String.t()]} | {:error, String.t()}
  def unknown_placeholders do
    planes =
      case Enum.filter(Plane.all(), &File.exists?(Plane.manifest_path(&1))) do
        [] -> ["development"]
        present -> present
      end

    Enum.reduce_while(planes, {:ok, []}, fn plane, {:ok, acc} ->
      case unknown_placeholders(plane) do
        {:ok, unknown} -> {:cont, {:ok, acc ++ unknown}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, unknown} -> {:ok, unknown |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp unknown_placeholders(plane) do
    dir = Plane.templates_dir(plane)

    with {:ok, manifest} <- Loader.cached_load(Plane.manifest_path(plane)) do
      declared = MapSet.new(get_in(manifest, ["placeholders", "names"]) || [])

      used =
        manifest["sections"]
        |> Enum.flat_map(fn %{"file" => file} ->
          case File.read(Path.join(dir, file)) do
            {:ok, body} ->
              Regex.scan(~r/\{\{([a-z0-9_.]+)\}\}/, body) |> Enum.map(&Enum.at(&1, 1))

            _ ->
              []
          end
        end)
        |> MapSet.new()

      {:ok, used |> MapSet.difference(declared) |> MapSet.to_list() |> Enum.sort()}
    end
  end

  @doc """
  The values the development templates are given where a definition says
  nothing: development text, every one of which a runtime manifest replaces
  under `defaults`. Public so a test can look for them in a runtime
  prompt.
  """
  @spec development_defaults() :: %{String.t() => String.t() | [String.t()]}
  def development_defaults, do: @development_defaults

  # ---- the plane's inputs --------------------------------------------------

  defp manifest(plane, agent_id) do
    path = Plane.manifest_path(plane)

    case Loader.cached_load(path) do
      {:ok, manifest} ->
        declared = Plane.of(manifest)

        if declared == plane do
          {:ok, manifest}
        else
          {:error,
           "#{agent_id} is a #{plane} role, and #{relative(path)} is the #{declared} plane's " <>
             "manifest: a prompt is composed from its own plane's templates"}
        end

      {:error, message} when plane == "runtime" ->
        {:error,
         "#{agent_id} is a runtime role, and this root has no runtime templates (#{message}): " <>
           "a runtime role is never composed from the development plane's"}

      error ->
        error
    end
  end

  # The manifest's `preamble`, relative to the manifest. A development manifest
  # that names none means `.agents/constitution.md`, as it always did; a
  # runtime one must name its own, and it may be neither that file nor a copy.
  defp constitution(plane, manifest) do
    development = Path.expand(Noetic.Harness.agents_path("constitution.md"))

    path =
      case manifest["preamble"] do
        preamble when is_binary(preamble) -> Path.expand(preamble, Plane.templates_dir(plane))
        _ when plane == "development" -> development
        _ -> nil
      end

    cond do
      is_nil(path) ->
        {:error,
         "the runtime manifest names no preamble: a runtime prompt carries its own " <>
           "constitution, never the development one"}

      plane == "runtime" and path == development ->
        {:error,
         "the runtime manifest's preamble is the development constitution " <>
           "(#{relative(path)}), which no runtime prompt carries"}

      true ->
        case cached_read(path) do
          {:ok, text} ->
            if plane == "runtime" and copy_of?(text, development) do
              {:error,
               "the runtime constitution #{relative(path)} is a copy of the development " <>
                 "one, which no runtime prompt carries"}
            else
              {:ok, text}
            end

          {:error, reason} ->
            {:error, "constitution #{relative(path)}: #{:file.format_error(reason)}"}
        end
    end
  end

  defp copy_of?(text, path) do
    case cached_read(path) do
      {:ok, other} -> String.trim(other) == String.trim(text)
      {:error, _} -> false
    end
  end

  # The development plane may restate its defaults in its manifest; a runtime
  # manifest must give every one, and none of them the development text.
  defp defaults("runtime", manifest) do
    given = manifest["defaults"] || %{}
    missing = Enum.reject(Map.keys(@development_defaults), &Map.has_key?(given, &1))

    borrowed =
      for {key, value} <- @development_defaults,
          List.wrap(value) -- List.wrap(given[key]) != List.wrap(value),
          do: key

    cond do
      missing != [] ->
        {:error,
         "the runtime manifest gives no #{Enum.join(Enum.sort(missing), ", ")} under " <>
           "`defaults`: a runtime prompt never borrows the development plane's"}

      borrowed != [] ->
        {:error,
         "the runtime manifest's #{Enum.join(Enum.sort(borrowed), ", ")} under `defaults` " <>
           "repeat the development plane's text, which no runtime prompt carries"}

      true ->
        {:ok, given}
    end
  end

  defp defaults(_development, manifest),
    do: {:ok, Map.merge(@development_defaults, manifest["defaults"] || %{})}

  # What a runtime prompt would grant: its own tools, and the gates its role,
  # its capabilities and its lane name. None may be the development plane's.
  defp runtime_supply("runtime", agent, registry, lane, tool_defs, gate_defs) do
    tools =
      for tool <- agent["tools"] || [],
          not Plane.runtime?(tool_defs[tool]),
          do: "the development tool #{tool}"

    gates =
      (agent["gates"] || []) ++
        Enum.flat_map(
          agent["capabilities"] || [],
          &(get_in(registry.capabilities, [&1, "gates"]) || [])
        ) ++
        expand_lane(lane, gate_defs)

    commands =
      for gate <- Enum.uniq(gates),
          get_in(gate_defs, [gate, "kind"]) == "command",
          do: "the command gate #{gate}"

    case tools ++ commands do
      [] ->
        :ok

      found ->
        {:error,
         "#{agent["id"]} is a runtime role, and its prompt would grant #{Enum.join(found, ", ")}: " <>
           "a runtime prompt never does"}
    end
  end

  defp runtime_supply(_development, _agent, _registry, _lane, _tool_defs, _gate_defs), do: :ok

  # ---- value construction --------------------------------------------------

  defp build_values(agent, registry, ctx) do
    domain = Map.get(registry.domains, agent["domain"], %{})
    archetype = Map.get(ctx.archetypes, agent["archetype"], %{})

    capabilities =
      Enum.map(agent["capabilities"], &Map.get(registry.capabilities, &1, %{"id" => &1}))

    {granted, withheld} = Policy.grant_tools(agent["tools"], ctx.trust, ctx.tool_defs)
    level = Enum.find(ctx.trust_doc["levels"], &(&1["id"] == ctx.trust)) || %{}
    lane_gates = expand_lane(ctx.lane, ctx.gate_defs)

    %{
      "agent.id" => agent["id"],
      "agent.name" => agent["name"],
      "agent.domain" => agent["domain"],
      "agent.domain_summary" => Map.get(domain, "summary", "(domain not described)"),
      "agent.domain_owns" =>
        bullets(
          Map.get(domain, "owns", []),
          "`",
          "`",
          "(no repository area is assigned to this domain)"
        ),
      "agent.archetype" => agent["archetype"],
      "agent.archetype_name" => Map.get(archetype, "name", agent["archetype"]),
      "agent.archetype_stance" => Map.get(archetype, "stance", ""),
      "agent.capabilities" => Enum.join(agent["capabilities"], ", "),
      "agent.capability_detail" => capability_detail(capabilities),
      "agent.non_scope" => non_scope(agent, registry, domain, ctx.defaults["non_scope"]),
      "agent.skills" => Enum.join(agent["skills"], ", "),
      "agent.skill_detail" => skill_detail(agent["skills"]),
      "agent.tools" => Enum.join(granted, ", "),
      "agent.tool_detail" => tool_detail(granted, ctx.tool_defs),
      "agent.unavailable_tools" => unavailable_detail(agent["tools"], withheld, ctx.tool_defs),
      "agent.trust" => ctx.trust,
      "agent.trust_name" => Map.get(level, "name", "unknown"),
      "agent.trust_summary" => Map.get(level, "summary", ""),
      "agent.trust_may" => bullets(Map.get(level, "may", []), "", "", "(nothing)"),
      "agent.trust_may_not" =>
        bullets(Map.get(level, "may_not", []), "", "", "(nothing stated beyond the level above)"),
      "agent.tags" => Enum.join(agent["tags"] || [], ", "),
      "agent.status" => agent["status"],
      "role.overlay" => overlay_or_default(agent, archetype, ctx.plane),
      "loop" => Enum.join(Map.get(archetype, "loop", []), " → "),
      "loop_detail" => loop_detail(archetype),
      "evidence" => evidence(archetype, capabilities, ctx.defaults["evidence"]),
      "prohibited" =>
        bullets(Map.get(archetype, "prohibited", []), "", "", "(none beyond the constitution)"),
      "completion" => completion(archetype, capabilities),
      "artifact_kinds" => artifact_kinds(ctx.workflow, ctx.step),
      "lane" => ctx.lane || "none",
      "lane_gates" => Enum.join(lane_gates, ", "),
      "gate_detail" => gate_detail(lane_gates, ctx.gate_defs, agent["gates"] || []),
      "workflow.id" => value(ctx.workflow, "id", "(no workflow)"),
      "workflow.name" => value(ctx.workflow, "name", "(no workflow)"),
      "workflow.intent" =>
        value(ctx.workflow, "intent", "(standing prompt: no workflow selected)"),
      "workflow.step_id" => value(ctx.step, "id", "(no step)"),
      "workflow.step_name" => value(ctx.step, "name", "(no step)"),
      "workflow.inputs" =>
        bullets(Map.get(ctx.step, "inputs", []), "", "", "(whatever the task provides)"),
      "workflow.outputs" =>
        bullets(Map.get(ctx.step, "outputs", []), "", "", "(a report of what you found)"),
      "workflow.escalations" => escalations(ctx.workflow, ctx.defaults["escalations"]),
      "workflow.completion" =>
        bullets(
          value(ctx.workflow, "completion", []),
          "",
          "",
          "(no workflow criteria: the role's own criteria above are the whole test)"
        ),
      "workflow.retry_budget" => to_string(value(ctx.workflow, "retry_budget", 3)),
      "context.priorities" => context_priorities(capabilities),
      "context.bundle" => bundle_text(ctx.bundle),
      "memory.records" => memory_text(ctx.bundle),
      "task.id" => Map.get(ctx.task, :id, "(none)"),
      "task.title" => Map.get(ctx.task, :title, "(none)"),
      "task.body" => Map.get(ctx.task, :body, "(none)"),
      "task.terminal_states" =>
        Enum.map_join(Map.get(archetype, "terminal_states", ["DONE"]), ", ", &"`#{&1}`")
    }
  end

  defp render_sections(manifest, values, dir) do
    manifest["sections"]
    |> Enum.reduce_while({:ok, []}, fn %{"file" => file} = entry, {:ok, acc} ->
      path = Path.join(dir, file)

      case cached_read(path) do
        {:ok, template} ->
          case render(template, values, file) do
            {:ok, rendered} ->
              trimmed = String.trim(rendered)

              cond do
                trimmed == "" and entry["required"] ->
                  {:halt, {:error, "template #{file} is required but rendered empty"}}

                trimmed == "" ->
                  {:cont, {:ok, acc}}

                true ->
                  {:cont, {:ok, [trimmed | acc]}}
              end

            error ->
              {:halt, error}
          end

        {:error, reason} ->
          {:halt, {:error, "template #{file}: #{:file.format_error(reason)}"}}
      end
    end)
    |> case do
      {:ok, sections} -> {:ok, sections |> Enum.reverse() |> Enum.join("\n\n")}
      error -> error
    end
  end

  defp render(template, values, file) do
    Regex.scan(~r/\{\{([a-z0-9_.]+)\}\}/, template)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(values, &1))
    |> case do
      [] ->
        {:ok,
         Regex.replace(~r/\{\{([a-z0-9_.]+)\}\}/, template, fn _, key ->
           values |> Map.fetch!(key) |> to_string()
         end)}

      unknown ->
        {:error, "template #{file} uses unknown placeholders: #{Enum.join(unknown, ", ")}"}
    end
  end

  # ---- section content -----------------------------------------------------

  defp capability_detail(capabilities) do
    Enum.map_join(capabilities, "\n", fn capability ->
      note = if capability["note"], do: "\n  _#{capability["note"]}_", else: ""

      "- **`#{capability["id"]}`** — #{Map.get(capability, "doc", "(undocumented capability)")}#{note}"
    end)
  end

  # A role's non-scope is stated as the capabilities its own domain holds that
  # it does not, plus the lines its plane says no role decides. Deriving it
  # rather than writing it keeps it true when the registry changes.
  defp non_scope(agent, registry, domain, lines) do
    held = MapSet.new(agent["capabilities"])

    siblings =
      registry.agents
      |> Enum.filter(&(&1["domain"] == agent["domain"] and &1["id"] != agent["id"]))
      |> Enum.flat_map(& &1["capabilities"])
      |> MapSet.new()
      |> MapSet.difference(held)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.take(8)

    sibling_text =
      case siblings do
        [] ->
          ""

        list ->
          "\n\nOther roles in **#{Map.get(domain, "id", agent["domain"])}** hold these, and they are not yours:\n" <>
            bullets(list, "`", "`", "")
      end

    Enum.map_join(List.wrap(lines), "\n", &"- #{&1}") <> sibling_text
  end

  defp skill_detail(names) do
    available = Map.new(Skills.list(), &{&1.name, &1})

    Enum.map_join(names, "\n", fn name ->
      case Map.fetch(available, name) do
        {:ok, skill} ->
          "- **`#{name}`** — #{skill.description}\n  `#{relative(skill.path)}`"

        :error ->
          "- **`#{name}`** — **NOT FOUND ON DISK.** Report this; do not proceed as if the guidance did not exist."
      end
    end)
  end

  defp tool_detail(granted, defs) do
    case granted do
      [] ->
        "- (none: this role reads what it is given and reports)"

      list ->
        Enum.map_join(list, "\n", fn id ->
          definition = Map.get(defs, id, %{})
          doc = if definition["doc"], do: " — #{definition["doc"]}", else: ""

          "- `#{id}` (#{definition["kind"] || "?"}, needs #{definition["min_trust"] || "?"})#{doc}"
        end)
    end
  end

  defp unavailable_detail(wanted, withheld, defs) do
    absent =
      wanted
      |> Enum.filter(fn id -> Map.get(defs, id, %{})["present"] == false end)
      |> Enum.map(fn id ->
        definition = Map.get(defs, id, %{})
        install = if definition["install"], do: " (install: `#{definition["install"]}`)", else: ""
        "- `#{id}` is recorded as not present in this environment#{install}"
      end)

    blocked = Enum.map(withheld, fn {id, reason} -> "- `#{id}` withheld: #{reason}" end)

    case absent ++ blocked do
      [] -> "- (none: every tool this role needs is expected to be available)"
      list -> Enum.join(list, "\n")
    end
  end

  defp loop_detail(archetype) do
    notes = Map.get(archetype, "loop_notes", %{})

    Map.get(archetype, "loop", [])
    |> Enum.map_join("\n", fn step ->
      case Map.fetch(notes, step) do
        {:ok, note} -> "- **#{step}** — #{note}"
        :error -> "- **#{step}**"
      end
    end)
  end

  defp evidence(archetype, capabilities, default) do
    from_archetype = Map.get(archetype, "evidence_required", [])
    from_capabilities = capabilities |> Enum.flat_map(&Map.get(&1, "evidence", [])) |> Enum.uniq()

    bullets(from_archetype ++ from_capabilities, "", "", default)
  end

  defp completion(archetype, capabilities) do
    base = "- " <> Map.get(archetype, "completion", "the work is demonstrably done")

    per_capability =
      capabilities
      |> Enum.flat_map(fn capability ->
        case Map.get(capability, "gates", []) do
          [] -> []
          gates -> ["- `#{capability["id"]}` requires: #{Enum.map_join(gates, ", ", &"`#{&1}`")}"]
        end
      end)

    Enum.join([base | per_capability], "\n")
  end

  defp artifact_kinds(workflow, step) do
    from_step = Map.get(step, "outputs", [])
    from_workflow = get_in(workflow || %{}, ["artifacts", "out"]) || []

    case Enum.uniq(from_step ++ from_workflow) do
      [] -> "a written report of what you did, what you found and what remains unverified"
      list -> Enum.map_join(list, ", ", &"`#{&1}`")
    end
  end

  defp gate_detail(lane_gates, defs, role_gates) do
    ids = Enum.uniq(lane_gates ++ role_gates)

    case ids do
      [] ->
        "- (no gate applies to this work; say so in your report rather than implying one ran)"

      list ->
        Enum.map_join(list, "\n", fn id ->
          definition = Map.get(defs, id, %{})

          command =
            if definition["command"],
              do: "\n  `#{display_command(definition["command"])}`",
              else: ""

          note = if definition["note"], do: "\n  _#{definition["note"]}_", else: ""

          "- **#{id}** (#{definition["severity"] || "?"}) — #{definition["name"] || "undefined gate"}#{command}#{note}"
        end)
    end
  end

  # Gate commands carry their own `{{app}}` / `{{files}}` substitutions, filled in
  # by the gate runner from the actual change. Rendered into a prompt they would
  # look like unfilled prompt placeholders — and they are what the strict
  # renderer's "no {{ left in a prompt" check would otherwise trip over. Shown as
  # angle brackets they read as what they are: a slot the runner fills.
  defp display_command(command) do
    command
    |> String.replace("{{app}}", "<touched app>")
    |> String.replace("{{files}}", "<changed files>")
  end

  defp escalations(nil, lines), do: Enum.map_join(List.wrap(lines), "\n", &"- #{&1}")

  defp escalations(workflow, _lines) do
    Enum.map_join(workflow["escalations"] || [], "\n", fn escalation ->
      note = if escalation["note"], do: " _#{escalation["note"]}_", else: ""
      "- **#{escalation["when"]}** → #{escalation["to"]}#{note}"
    end)
  end

  defp context_priorities(capabilities) do
    capabilities
    |> Enum.flat_map(&Map.get(&1, "context", []))
    |> Enum.uniq()
    |> bullets("`", "`", "(no context sources are declared for these capabilities)")
  end

  defp bundle_text(nil),
    do:
      "_(No task bundle: this is the role's standing prompt. When you are given a task, the bundle appears here.)_"

  defp bundle_text(bundle), do: Context.render(bundle)

  defp memory_text(nil), do: "_(none attached)_"

  defp memory_text(bundle) do
    case bundle.memory do
      [] ->
        "_(nothing in project memory matched this task's scope. That is a fact about the store, not a guarantee the mistake is new.)_"

      records ->
        Enum.map_join(
          records,
          "\n",
          &"- **#{&1["title"]}** (#{&1["kind"]}, #{&1["confidence"]}) — #{&1["body"]}"
        )
    end
  end

  defp overlay_or_default(agent, archetype, plane) do
    case Registry.overlay(agent["id"]) do
      {:ok, overlay} ->
        overlay

      # The advice below is about this repository's overlay files, which a
      # product's AI employee has no use for.
      :error when plane == "runtime" ->
        "You are the **#{agent["name"]}**. #{Map.get(archetype, "stance", "")}"

      :error ->
        "You are the **#{agent["name"]}**. #{Map.get(archetype, "stance", "")}\n\n" <>
          "This role has no hand-authored operational overlay, so your method is the " <>
          "archetype's working loop below, applied to the capabilities you hold. If you " <>
          "find yourself repeatedly needing guidance this prompt does not carry, that is " <>
          "worth an overlay in `.agents/roles/#{agent["id"]}.md` — say so in your report."
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp expand_lane(lane_id, gate_defs) do
    case Policy.gates() do
      {:ok, doc} -> do_expand_lane(lane_id, doc["lanes"], gate_defs, MapSet.new())
      {:error, _} -> []
    end
  end

  defp do_expand_lane(lane_id, lanes, gate_defs, seen) do
    cond do
      MapSet.member?(seen, lane_id) ->
        []

      lane = Enum.find(lanes, &(&1["id"] == lane_id)) ->
        seen = MapSet.put(seen, lane_id)

        Enum.flat_map(lane["gates"], fn id ->
          if Map.has_key?(gate_defs, id),
            do: [id],
            else: do_expand_lane(id, lanes, gate_defs, seen)
        end)
        |> Enum.uniq()

      true ->
        []
    end
  end

  defp fetch_agent(registry, id) do
    case Registry.fetch(registry, id) do
      {:ok, agent} -> {:ok, agent}
      :error -> {:error, "no agent with id #{id}"}
    end
  end

  # An unknown id composes as no workflow, as it always has. A workflow of
  # the other plane is refused.
  defp load_workflow(nil, _agent_id, _plane), do: {:ok, nil}

  defp load_workflow(id, agent_id, plane) do
    case Workflow.fetch(id, :any) do
      {:ok, workflow} ->
        if Plane.of(workflow) == plane do
          {:ok, workflow}
        else
          {:error,
           "#{agent_id} is a #{plane} role, and #{id} is a #{Plane.of(workflow)} workflow: " <>
             "a prompt is composed from one plane"}
        end

      :error ->
        {:ok, nil}
    end
  end

  defp find_step(nil, _step_id), do: %{}
  defp find_step(_workflow, nil), do: %{}

  defp find_step(workflow, step_id) do
    Enum.find(workflow["steps"] || [], %{}, &(&1["id"] == step_id))
  end

  defp value(nil, _key, default), do: default
  defp value(map, key, default), do: Map.get(map, key) || default

  defp bullets([], _open, _close, empty), do: if(empty == "", do: "", else: "- #{empty}")

  defp bullets(items, open, close, _empty) do
    Enum.map_join(items, "\n", fn item -> "- #{open}#{item}#{close}" end)
  end

  # Same reasoning as Loader.cached_load/1: the constitution and the fifteen
  # templates are read once per composed prompt, and 270 prompts is 4,320 reads
  # of sixteen files that cannot change during the run.
  defp cached_read(path) do
    key = {__MODULE__, :file, path}

    case Process.get(key) do
      nil ->
        result = File.read(path)
        Process.put(key, result)
        result

      cached ->
        cached
    end
  end

  defp relative(path), do: Path.relative_to(path, Noetic.Harness.root())
end
