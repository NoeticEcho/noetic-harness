defmodule Noetic.Harness.Validation do
  @moduledoc """
  What the harness considers a defect.

  Reading this module tells you the harness's actual contract — not what the
  documentation hopes is true, but what `noetic-harness validate` refuses to let
  pass. Every check here exists because the thing it catches is invisible to a
  reader: prose about a skill reads identically whether or not the file exists.

  ## The checks

  | Check | Catches |
  |---|---|
  | `registry` | duplicate ids, unknown domains/archetypes/capabilities, a capability naming a skill or tool that is not defined, a trust level above the domain ceiling |
  | `overlay_tool_claims` | an overlay telling a role it holds a tool it does not, or lacks one it has |
  | `overlay_authority` | an overlay instructing a role to take an action above its trust level |
  | `evaluator_fence` | a file the gates execute that a dispatched run could still edit |
  | `overlays` | **advisory** — a high-risk role the registry cannot distinguish from another, with no hand-authored overlay to do it. Warnings only: whether one is worth writing is a judgement, not a defect |
  | `skills` | any skill a role, capability or domain names that is not on disk |
  | `tools` | any tool a role or gate names that is not in the tool policy |
  | `planes` | a runtime tool of any kind but `function` or `data`, whatever plane it says; a signal, a declared kind or the router's fallback naming a runtime capability or workflow; a runtime role holding a development tool or capability, a trust above draft (T1) or a command gate; a runtime capability supplying a development tool or a command gate; a runtime workflow naming a development capability or running a command gate; a development workflow naming a runtime capability; a workflow, role or capability naming a role or workflow of the other plane, in either direction, as an escalation target or as the holder of a gate its steps, its lane or itself name |
  | `gates` | a lane naming a gate that does not exist, a gate whose holder is not a role, a gate requiring an undefined tool, an unreachable lane cycle |
  | `workflows` | unknown capability/gate/lane, dangling `independent_of`, a step consuming a later step's output, a capability nobody supplies, no completion criteria |
  | `pipelines` | a pipeline naming a workflow or gate that does not exist |
  | `prompts` | any registered agent that cannot compose a prompt; a template using a placeholder the renderer does not supply |
  | `schemas` | a `$schema` pointer that does not resolve; every definition file against its schema; a handoff named for another epic; `ready` with no lane, on a lane that did not pass, or with a child still open; a deferred child with no note, a reparented one with no `to` |
  | `memory` | duplicate ids, a dangling `superseded_by`, a retirement with no reason |
  | `profiles` | a profile id outside the six cloud profiles, or with no environment; a tracked file or a glob two profiles own that `shared` does not declare; a `shared` entry naming a profile that does not exist; everything `Noetic.Harness.Profiles.validate/1` refuses |
  | `evolution` | broken lineage, a candidate marked promoted without every stage. Run only where the build has the evolution engine (`engine_checks/1`), like `environments` |
  | `adapters` | a generated adapter that has drifted from what the canonical definitions would produce |
  | `mcp` | a tool in `.agents/policies/mcp.json` on a task outside `Noetic.Harness.MCP`'s read-only allow-list, given a flag it may not be, or missing the flag that keeps it read-only |
  | `models` | `review.models` in `.agents/policies/models.json` naming fewer than two model families, which would make the independent-review refusal unsatisfiable for work that family wrote |

  ## Why `prompts` is the expensive one

  It composes a prompt for all 270 roles. That takes a few seconds and it is the
  check worth having: "every registered agent has a usable prompt" is the claim
  the whole registry rests on, and it is false the moment a template gains a
  placeholder or a role gains a skill that does not exist.
  """

  alias Noetic.Harness.{
    Adapters,
    Environments,
    Evolution,
    Fence,
    Gates,
    Loader,
    MCP,
    Memory,
    Policy,
    Profiles,
    Prompt,
    Registry,
    Skills,
    Workflow
  }

  alias Noetic.Harness.Validation.Schema

  @type finding :: {:error | :warning, String.t()}

  @all ~w(registry overlays overlay_tool_claims overlay_authority evaluator_fence skills tools
           planes gates workflows pipelines prompts
           schemas memory evolution environments failure adapters mcp questions models profiles)a

  # The evolution engine is two modules a build may leave out. The published
  # harness left them out for one cut, until their guards were complete, and
  # carries them again. A check that named them
  # directly would not compile without them under `--warnings-as-errors`, so
  # each is called through the module it is held in, and only when that module
  # is loaded.
  # In a build that has the engine both checks run as before, and
  # `ValidationEngineTest` fails if either stops running here — the condition
  # is how a tree without the engine compiles, not a way to switch them off.
  @engine [evolution: Evolution, environments: Environments]

  @doc """
  Every check name this build can run.

  The `evolution` and `environments` checks are named only when the build has
  the module behind each (`engine_checks/1`).
  """
  @spec checks() :: [atom()]
  def checks do
    present = engine_checks()
    Enum.reject(@all, &(Keyword.has_key?(@engine, &1) and &1 not in present))
  end

  @doc """
  The evolution engine's checks whose module this build has, in order.

  `loaded?` answers whether a module is there; it is `Code.ensure_loaded?/1`,
  and a test passes another to ask about a build without the engine.
  """
  @spec engine_checks((module() -> boolean())) :: [atom()]
  def engine_checks(loaded? \\ &Code.ensure_loaded?/1) do
    for {check, module} <- @engine, loaded?.(module), do: check
  end

  @doc """
  Run every check, or the ones named.

  Returns `{:ok, findings}` where an empty list means the definitions are
  internally consistent. Warnings do not fail the run; errors do. The caller
  decides — `noetic-harness validate` exits non-zero on any error.
  """
  @spec run([atom()]) :: {:ok, [finding()]} | {:error, String.t()}
  def run(which \\ checks()) do
    case Registry.load() do
      {:error, message} ->
        {:error, message}

      {:ok, registry} ->
        findings =
          which
          |> Enum.flat_map(fn check -> apply(__MODULE__, :"check_#{check}", [registry]) end)
          |> Enum.uniq()

        {:ok, findings}
    end
  end

  @doc "True when there is nothing at `:error` severity."
  @spec ok?([finding()]) :: boolean()
  def ok?(findings), do: not Enum.any?(findings, &match?({:error, _}, &1))

  # ---- registry ------------------------------------------------------------

  @doc false
  def check_registry(registry) do
    duplicates =
      registry.agents
      |> Enum.frequencies_by(& &1["id"])
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(fn {id, count} -> error("registry: id #{id} appears #{count} times") end)

    legacy_duplicates =
      registry.agents
      |> Enum.frequencies_by(& &1["legacy_id"])
      |> Enum.filter(fn {id, count} -> count > 1 and not is_nil(id) end)
      |> Enum.map(fn {id, count} -> error("registry: legacy id #{id} appears #{count} times") end)

    references =
      Enum.flat_map(registry.agents, fn agent ->
        domain_problem =
          if Map.has_key?(registry.domains, agent["domain"]),
            do: [],
            else: [error("#{agent["id"]}: unknown domain #{agent["domain"]}")]

        archetype_problem =
          if Map.has_key?(registry.archetypes, agent["archetype"]),
            do: [],
            else: [error("#{agent["id"]}: unknown archetype #{agent["archetype"]}")]

        capability_problems =
          for capability <- agent["capabilities"],
              not Map.has_key?(registry.capabilities, capability),
              do: error("#{agent["id"]}: unknown capability #{capability}")

        trust_problem = trust_problem(agent, registry)

        domain_problem ++ archetype_problem ++ capability_problems ++ trust_problem
      end)

    empty =
      for agent <- registry.agents, agent["capabilities"] == [] do
        warning("#{agent["id"]}: holds no capabilities, so nothing can route to it")
      end

    nucleus =
      for id <- registry.nucleus, not Map.has_key?(registry.by_id, id) do
        error("nucleus names #{id}, which is not a registered role")
      end

    duplicates ++ legacy_duplicates ++ references ++ empty ++ nucleus ++ orphan_overrides()
  end

  # An override file is named for the role it amends, and until
  # this bead one named for a role that does not exist was loaded, matched
  # nothing and was dropped without a word. That was harmless while the hatch
  # could only amend — the file did nothing and the registry was unchanged —
  # and it stops being harmless the moment the hatch can *add*: a typo in a
  # filename now means a role that is simply absent from a registry of 270,
  # which is not a thing anyone notices.
  #
  # So the two cases are separated by what the file carries. Complete, and it
  # is a role. Incomplete, and it is named here with the fields it is missing.
  defp orphan_overrides do
    with {:ok, overrides} <- Registry.overrides(),
         {:ok, generated} <-
           Loader.cached_load(Noetic.Harness.agents_path("registry/agents.json")) do
      {_additions, orphans} = Registry.unmatched(Map.fetch!(generated, "agents"), overrides)

      for {id, spec} <- orphans do
        missing = Enum.reject(Registry.required_for_addition(), &Map.has_key?(spec, &1))

        error(
          "registry: overrides/#{id}.json matches no generated role and is missing " <>
            "#{Enum.join(missing, ", ")}. Either the filename is a typo, or it means to add a " <>
            "role and has to carry #{Enum.join(Registry.required_for_addition(), ", ")}."
        )
      end
    else
      _unreadable -> []
    end
  end

  defp trust_problem(agent, registry) do
    ceiling = get_in(registry.domains, [agent["domain"], "trust_ceiling"])

    cond do
      is_nil(ceiling) ->
        []

      Policy.at_least?(agent["max_trust"], ceiling) and agent["max_trust"] != ceiling ->
        [
          error(
            "#{agent["id"]}: max_trust #{agent["max_trust"]} exceeds the #{agent["domain"]} " <>
              "domain ceiling #{ceiling}"
          )
        ]

      true ->
        []
    end
  end

  # A role is a name, an archetype, a set of capabilities and a set of tools. If
  # two roles agree on the last three, the registry cannot tell them apart, and
  # `noetic-harness prompt` composes two prompts differing only in the name — which
  # reads as two specialists and is one.
  #
  # **This is one signal, not the rule.** An overlay is warranted where the
  # registry cannot distinguish a high-risk role *and* there is
  # repository-specific method to carry; this check can only see the first half.
  # Five of the twelve overlays written for an earlier change are for roles with a
  # signature all to themselves, and this check would never have nominated them.
  # A generic overlay is worse than none, so a warning here is a candidate to
  # judge rather than a task to do.
  #
  # Scoped to `high_risk` for the warning, deliberately, and the scope is a name
  # regex in `role_rules.json` rather than a curated judgement — read it as
  # "dangerous enough that the distinction is a safeguard", not as a ranking.
  # The grouping itself is over **all** active roles: a high-risk role sharing a
  # signature with a role that is not high-risk is just as indistinguishable,
  # and filtering first would hide it.
  @doc false
  def check_overlays(registry) do
    registry.agents
    |> Enum.filter(&(&1["status"] == "active"))
    |> Enum.group_by(&{&1["archetype"], Enum.sort(&1["capabilities"]), Enum.sort(&1["tools"])})
    |> Enum.reject(fn {_signature, roles} -> length(roles) == 1 end)
    |> Enum.flat_map(fn {_signature, roles} -> indistinguishable(roles) end)
    |> Enum.sort()
  end

  defp indistinguishable(roles) do
    {overlaid, bare} = Enum.split_with(roles, &overlay?(&1["id"]))
    high_risk = Enum.filter(bare, &("high_risk" in (&1["tags"] || [])))

    if high_risk == [] do
      []
    else
      [warning(indistinguishable_message(high_risk, roles, overlaid))]
    end
  end

  defp indistinguishable_message(high_risk, roles, overlaid) do
    subject = Enum.map_join(high_risk, ", ", & &1["id"])
    plural = length(high_risk) > 1

    shape =
      case overlaid do
        [] ->
          "and no role in the group has one to copy the shape from"

        [exemplar | _] ->
          "and #{exemplar["id"]} in the same group has one — that is the shape"
      end

    "#{subject} #{if plural, do: "are", else: "is"} high_risk with no overlay in " <>
      "`.agents/roles/`, in a group of #{length(roles)} role(s) sharing one archetype, " <>
      "capability set and tool set, #{shape}"
  end

  # An overlay is prose that becomes a standing instruction, so a false sentence
  # in it is not a stale comment — it tells an agent to use a tool it does not
  # have, or not to use one it does. An independent review found exactly that:
  # `security.abuse_case_designer` was told to write and run tests, holding
  # neither `edit` nor `mix.test`.
  #
  # Only the mechanical half is checkable. A paragraph saying "You hold" is
  # scanned for backticked tool ids, and each is compared against the grant.
  # Everything else an overlay claims — a path, an ADR, a count — is checked by
  # nobody, which is the standing weakness of this whole mechanism.
  @doc false
  def check_overlay_tool_claims(registry) do
    case Policy.tools_by_id() do
      {:ok, defs} -> Enum.flat_map(registry.agents, &tool_claims(&1, MapSet.new(Map.keys(defs))))
      {:error, message} -> [error(message)]
    end
  end

  defp tool_claims(agent, known) do
    case Registry.overlay(agent["id"]) do
      :error ->
        []

      {:ok, overlay} ->
        held = MapSet.new(agent["tools"])

        overlay
        |> String.split(~r/\n\s*\n/)
        |> Enum.filter(&String.contains?(&1, "You hold"))
        |> Enum.flat_map(&claimed_tools/1)
        |> Enum.flat_map(fn {tool, negated?} ->
          cond do
            not MapSet.member?(known, tool) -> []
            negated? and MapSet.member?(held, tool) -> [tool_claim_error(agent, tool, "no ")]
            not negated? and not MapSet.member?(held, tool) -> [tool_claim_error(agent, tool, "")]
            true -> []
          end
        end)
    end
  end

  defp claimed_tools(paragraph) do
    ~r/(no )?`([a-z][a-z._]*)`/
    |> Regex.scan(paragraph)
    |> Enum.map(fn [_, negation, tool] -> {tool, negation != ""} end)
  end

  defp tool_claim_error(agent, tool, negation) do
    error(
      ".agents/roles/#{agent["id"]}.md says the role holds #{negation}`#{tool}`, and the " <>
        "registry says the opposite. An overlay that is wrong about its own permissions is " <>
        "worse than one that does not mention them"
    )
  end

  # The tool check above catches an overlay claiming a *tool*. This one catches
  # an overlay **requiring an artifact the role may not produce** — which is
  # the failure that actually happened, four times over, in the release group.
  # `release.ci_cd_engineer` is capped at T3, T3's `may_not` names "change gate
  # definitions or CI workflow files", and the overlay closed with "Completion
  # evidence: the edited workflow". Nothing mechanical objected, because no
  # sentence in it mentioned a tool.
  #
  # **The scope is the completion-evidence line and nothing else, and that
  # narrowness was arrived at by failing twice.** Scanning the whole overlay
  # for privileged phrases gave sixteen findings, every one of them an overlay
  # correctly naming a forbidden action in order to forbid it. Requiring a
  # mutation verb beside the path, first per paragraph and then per sentence,
  # traded those false positives for a false negative: per paragraph a numbered
  # reading list lent "the changelog says what changed" to "`ci-local.sh` ran",
  # and per sentence the motivating defect itself — "Adding a job to ci.yml …
  # Edit both" — stopped firing. A check that reports clean on the example it
  # was written for is worse than no check, so the general form was abandoned.
  #
  # The evidence line survives because it is not prose about an action. It is a
  # closed list of artifacts the role must hand over, so naming one it cannot
  # lawfully produce is unambiguous — no verb to find, no context to weigh.
  # What this gives up is every instruction in the body of an overlay. That is
  # real and is not covered by anything; a reviewer is still the only thing
  # between a role and a sentence telling it to push to main.
  @privileged_artifacts [
    {~r/\bedited (workflow|ci|gate)|workflow (file|diff) you (edited|wrote)/i, "T4",
     "an edited CI workflow"},
    {~r/\bthe tag\b|\btags? (you )?(wrote|created|pushed)/i, "T4", "a tag"},
    {~r/\bthe (merge|push) to main\b|\bmain (was |is )?(pushed|merged)/i, "T4",
     "a push or merge to main"},
    {~r/\bthe deploy(ed|ment)?\b(?!.*\bunverified\b)/i, "T4", "a deployment"}
  ]

  @doc false
  def check_overlay_authority(registry) do
    Enum.flat_map(registry.agents, &authority_claims/1)
  end

  defp authority_claims(agent) do
    with {:ok, overlay} <- Registry.overlay(agent["id"]),
         {:ok, evidence} <- completion_evidence(overlay) do
      level = agent["max_trust"] || "T0"

      @privileged_artifacts
      |> Enum.filter(fn {pattern, needed, _what} ->
        below?(level, needed) and Regex.match?(pattern, evidence)
      end)
      |> Enum.map(fn {_pattern, needed, what} ->
        warning(
          ".agents/roles/#{agent["id"]}.md requires #{what} as completion evidence, which is " <>
            "#{needed}, and the role is capped at #{level}. A role cannot close on an artifact " <>
            "it may not lawfully produce; name what it hands over instead"
        )
      end)
    else
      _ -> []
    end
  end

  defp completion_evidence(overlay) do
    overlay
    |> String.split(~r/\n\s*\n/)
    |> Enum.find(&Regex.match?(~r/^completion evidence:/i, String.trim(&1)))
    |> case do
      nil -> :error
      paragraph -> {:ok, paragraph}
    end
  end

  defp below?(level, needed) do
    rank = fn "T" <> n -> String.to_integer(n) end
    rank.(level) < rank.(needed)
  rescue
    _ -> false
  end

  # A design decision puts a fence around what a dispatched run may not change, and
  # says the thing to design against is the list going stale: an evaluator
  # added next month that nobody adds to `.agents/policies/evaluators.json` is
  # unguarded, and nothing would say so.
  #
  # So this asserts the fence covers what the gates actually execute. Every
  # `command` in `gates.json` is scanned for repository-relative paths; each
  # one that exists on disk must be fenced. It **errors**, because an
  # unguarded evaluator is not a style question — and because the whole point
  # of the fence is that it is the thing standing between an autonomous loop
  # and its own scoreboard.
  #
  # What it cannot see: a gate whose command shells out to a script that in
  # turn runs something else. `ci-local.sh` is fenced by name and what it runs
  # internally is not chased. That residue is real and is why the fence lists
  # modules by hand as well.
  @doc false
  def check_evaluator_fence(_registry) do
    with {:ok, gates} <- Policy.gates(),
         {:ok, _entries} <- Fence.entries() do
      gates
      |> Map.get("gates", [])
      |> Enum.flat_map(&executed_paths/1)
      |> Enum.uniq()
      |> Enum.reject(&Fence.fenced?/1)
      |> Enum.map(fn path ->
        error(
          "#{path} is executed by a gate and is not in .agents/policies/evaluators.json. " <>
            "A dispatched run could edit the thing that judges it (" <>
            "constitution §23)"
        )
      end)
    else
      {:error, message} -> [error(message)]
    end
  end

  # A token is a candidate path when it contains a separator and names a file
  # that exists. `mix format --check-formatted` yields nothing; `./scripts/
  # ci-local.sh test` yields the script.
  defp executed_paths(gate) do
    gate
    |> Map.get("command", "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.trim_leading(&1, "./"))
    |> Enum.filter(&String.contains?(&1, "/"))
    |> Enum.filter(&File.regular?(Path.join(Noetic.Harness.root(), &1)))
  end

  defp overlay?(id), do: match?({:ok, _}, Registry.overlay(id))

  # ---- skills --------------------------------------------------------------

  @doc false
  def check_skills(registry) do
    from_roles = Enum.flat_map(registry.agents, & &1["skills"])

    from_capabilities =
      registry.capabilities |> Map.values() |> Enum.flat_map(&(&1["skills"] || []))

    from_domains = registry.domains |> Map.values() |> Enum.flat_map(&(&1["skills"] || []))

    missing = Skills.missing(from_roles ++ from_capabilities ++ from_domains)

    referenced = MapSet.new(from_roles ++ from_capabilities ++ from_domains)
    orphans = Skills.list() |> Enum.reject(&MapSet.member?(referenced, &1.name))

    Enum.map(missing, &error("skill #{&1} is referenced but not on disk")) ++
      Enum.map(orphans, fn skill ->
        warning("skill #{skill.name} exists at #{relative(skill.path)} but nothing routes to it")
      end) ++ stale_closure(registry)
  end

  # `agents.json` stores each role's skills as a flat list, produced once by
  # `.agents/tools/build_registry.py` from the capability closure. Nothing
  # recomputes it — `noetic-harness sync` regenerates the *prompts*, not the
  # registry — so adding a skill to a capability silently reaches no role at
  # all. It happened twice in one afternoon: `harness` and `simplify` were both
  # attached to capabilities, passed the orphan check because something
  # referenced them, and appeared in zero prompts.
  #
  # This is the check that makes the staleness loud. It compares what each
  # role's capabilities imply against what the role actually records.
  defp stale_closure(registry) do
    implied_by = fn capability_id ->
      case registry.capabilities[capability_id] do
        nil -> []
        capability -> capability["skills"] || []
      end
    end

    registry.agents
    |> Enum.flat_map(fn agent ->
      recorded = MapSet.new(agent["skills"] || [])

      (agent["capabilities"] || [])
      |> Enum.flat_map(implied_by)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(recorded, &1))
      |> Enum.map(&{agent["id"], &1})
    end)
    |> Enum.group_by(fn {_id, skill} -> skill end, fn {id, _skill} -> id end)
    |> Enum.map(fn {skill, ids} ->
      error(
        "skill #{skill} is supplied by a capability but missing from #{length(ids)} role(s) " <>
          "that hold it (#{Enum.join(Enum.take(Enum.sort(ids), 3), ", ")}#{if length(ids) > 3, do: ", …"}). " <>
          "Re-run `python3 .agents/tools/build_registry.py`, then `noetic-harness sync`."
      )
    end)
  end

  # ---- tools ---------------------------------------------------------------

  @doc false
  def check_tools(registry) do
    case Policy.tools_by_id() do
      {:error, message} ->
        [error(message)]

      {:ok, defs} ->
        from_roles =
          for agent <- registry.agents,
              tool <- agent["tools"],
              not Map.has_key?(defs, tool),
              do: error("#{agent["id"]}: tool #{tool} is not defined in the tool policy")

        from_capabilities =
          for {id, capability} <- registry.capabilities,
              tool <- capability["tools"] || [],
              not Map.has_key?(defs, tool),
              do: error("capability #{id}: tool #{tool} is not defined in the tool policy")

        Enum.uniq(from_roles ++ from_capabilities)
    end
  end

  # ---- planes --------------------------------------------------------------

  # The highest trust a runtime role may hold: T1, draft artifacts. A product's
  # AI employee drafts and proposes; what it drafts is accepted by a person or
  # by the product's own check, never by the role.
  @runtime_ceiling "T1"

  # The kinds a runtime tool may have: `function`, a product function the
  # product's engine calls by name, and `data`, a read of the product's own
  # data. Neither runs anything on a machine. The list is closed because the
  # label is self-declared: a tool that says `"plane": "runtime"` and has kind
  # `cli`, `service`, `mcp` or `builtin` still runs or reaches something where
  # it is called, and the plane it claims does not change that.
  @runtime_tool_kinds ~w(function data)

  # A definition's plane, `development` when it names none: every definition
  # written before the field is a development one, and stays so unchanged.
  defp plane(nil), do: "development"
  defp plane(definition), do: Map.get(definition, "plane", "development")

  @doc false
  def check_planes(registry) do
    with {:ok, tools} <- Policy.tools_by_id(),
         {:ok, gates} <- Policy.gates_by_id(),
         {:ok, workflows} <- Workflow.list() do
      runtime_capabilities =
        for {id, capability} <- registry.capabilities,
            plane(capability) == "runtime",
            into: MapSet.new(),
            do: id

      roles = Enum.flat_map(registry.agents, &runtime_role_problems(&1, registry, tools, gates))

      capabilities =
        for {id, capability} <- registry.capabilities,
            plane(capability) == "runtime",
            problem <- runtime_supply_problems("capability #{id}", capability, tools, gates),
            do: problem

      planes = %{
        roles: Map.new(registry.agents, &{&1["id"], plane(&1)}),
        workflows: Map.new(workflows, &{&1["id"], plane(&1)})
      }

      flows =
        Enum.flat_map(workflows, fn workflow ->
          workflow_plane_problems(workflow, runtime_capabilities, registry, gates, planes)
        end)

      holders =
        Enum.flat_map(registry.agents, &holder_problems(&1["id"], &1, gates, planes)) ++
          Enum.flat_map(registry.capabilities, fn {id, capability} ->
            holder_problems("capability #{id}", capability, gates, planes)
          end)

      tool_kinds =
        for {id, tool} <- Enum.sort(tools),
            plane(tool) == "runtime",
            tool["kind"] not in @runtime_tool_kinds,
            do:
              error(
                "tool #{id}: a runtime tool is of kind #{Enum.join(@runtime_tool_kinds, " or ")}, " <>
                  "which run nothing on a machine, not #{tool["kind"] || "(none)"}"
              )

      tool_kinds ++
        roles ++ capabilities ++ flows ++ holders ++ signal_problems(runtime_capabilities, planes)
    else
      {:error, message} -> [error(message)]
    end
  end

  defp runtime_role_problems(agent, registry, tools, gates) do
    if plane(agent) == "runtime" do
      id = agent["id"]

      capabilities =
        for capability <- agent["capabilities"],
            plane(registry.capabilities[capability]) != "runtime",
            do: error("#{id}: a runtime role holds the development capability #{capability}")

      trust =
        if Policy.at_least?(agent["max_trust"], @runtime_ceiling) and
             agent["max_trust"] != @runtime_ceiling,
           do: [
             error(
               "#{id}: a runtime role may hold at most #{@runtime_ceiling} (draft), " <>
                 "not #{agent["max_trust"]}"
             )
           ],
           else: []

      capabilities ++ runtime_supply_problems(id, agent, tools, gates) ++ trust
    else
      []
    end
  end

  # What a runtime role or capability supplies: tools of its own plane, and
  # gates that are checked, shown or reviewed, never run as a command.
  defp runtime_supply_problems(who, definition, tools, gates) do
    development_tools =
      for tool <- definition["tools"] || [],
          plane(tools[tool]) != "runtime",
          do: error("#{who}: a runtime definition holds the development tool #{tool}")

    command_gates =
      for gate <- definition["gates"] || [],
          get_in(gates, [gate, "kind"]) == "command",
          do: error("#{who}: a runtime definition names the command gate #{gate}")

    development_tools ++ command_gates
  end

  # Every role and workflow a workflow names: its escalations' targets, and
  # the holders of the gates its steps and its default lane run. A role or a
  # workflow of the other plane, named in any of them, is refused, in both
  # directions.
  defp workflow_plane_problems(workflow, runtime_capabilities, registry, gates, planes) do
    id = workflow["id"]
    own = plane(workflow)
    steps = workflow["steps"] || []
    capabilities = steps |> Enum.flat_map(&(&1["capabilities"] || [])) |> Enum.uniq()
    step_gates = steps |> Enum.flat_map(&(&1["gates"] || [])) |> Enum.uniq()

    lane_gates =
      case workflow["default_lane"] && Gates.expand(workflow["default_lane"]) do
        {:ok, ids} -> ids
        _ -> []
      end

    run_gates = Enum.uniq(step_gates ++ lane_gates)
    targets = Enum.filter(Enum.map(workflow["escalations"] || [], & &1["to"]), &is_binary/1)
    holders = Enum.flat_map(run_gates, &List.wrap(get_in(gates, [&1, "holder"])))

    roles =
      for role <- Enum.uniq(targets ++ holders),
          other = planes.roles[role],
          other != own,
          do: error("workflow #{id}: a #{own} workflow names the #{other} role #{role}")

    flows =
      for target <- Enum.uniq(targets),
          other = planes.workflows[target],
          other != own,
          do:
            error(
              "workflow #{id}: a #{own} workflow escalates to the #{other} workflow #{target}"
            )

    if own == "runtime" do
      development =
        for capability <- capabilities,
            plane(registry.capabilities[capability]) != "runtime",
            do:
              error(
                "workflow #{id}: a runtime workflow names the development capability #{capability}"
              )

      commands =
        for gate <- run_gates,
            get_in(gates, [gate, "kind"]) == "command",
            do: error("workflow #{id}: a runtime workflow runs the command gate #{gate}")

      development ++ commands ++ roles ++ flows
    else
      runtime =
        for capability <- capabilities,
            MapSet.member?(runtime_capabilities, capability),
            do:
              error(
                "workflow #{id}: a development workflow names the runtime capability #{capability}"
              )

      roles ++ runtime ++ flows
    end
  end

  # What the development router can be sent to from `signals.json`: each
  # signal's capabilities, each declared kind's, and the fallback's
  # capabilities and workflow. The router refuses a runtime one when it
  # reaches it; this refuses it before anything routes. A runtime pack
  # without a router has no signals file, and nothing to check.
  defp signal_problems(runtime_capabilities, planes) do
    case Loader.load(Noetic.Harness.agents_path("registry/signals.json")) do
      {:ok, doc} ->
        named =
          Enum.map(doc["signals"] || [], &{"signal #{&1["id"]}", &1["capabilities"]}) ++
            for(
              {kind, caps} <- doc["kind_signals"] || %{},
              is_list(caps),
              do: {"kind_signals #{kind}", caps}
            ) ++
            [{"fallback", get_in(doc, ["fallback", "capabilities"])}]

        capabilities =
          for {who, caps} <- named,
              capability <- caps || [],
              MapSet.member?(runtime_capabilities, capability),
              do:
                error(
                  "#{who}: names the runtime capability #{capability}, and the development " <>
                    "router routes only to development capabilities"
                )

        fallback = get_in(doc, ["fallback", "workflow"])

        workflow =
          if planes.workflows[fallback] == "runtime",
            do: [error("fallback: routes to the runtime workflow #{fallback}")],
            else: []

        capabilities ++ workflow

      {:error, _} ->
        []
    end
  end

  # A role or a capability naming a gate whose holder is a role of the other
  # plane: a development role's work reviewed by a product's AI employee, or a
  # runtime role's by a development role.
  defp holder_problems(who, definition, gates, planes) do
    own = plane(definition)

    for gate <- definition["gates"] || [],
        holder = get_in(gates, [gate, "holder"]),
        other = planes.roles[holder],
        other != own,
        do:
          error(
            "#{who}: a #{own} definition names the gate #{gate}, held by the #{other} role #{holder}"
          )
  end

  # ---- gates ---------------------------------------------------------------

  @doc false
  def check_gates(registry) do
    with {:ok, doc} <- Policy.gates(),
         {:ok, tool_defs} <- Policy.tools_by_id() do
      gate_ids = MapSet.new(doc["gates"], & &1["id"])
      lane_ids = MapSet.new(doc["lanes"], & &1["id"])

      unknown_in_lanes =
        for lane <- doc["lanes"],
            id <- lane["gates"],
            not MapSet.member?(gate_ids, id) and not MapSet.member?(lane_ids, id),
            do: error("lane #{lane["id"]}: #{id} is neither a gate nor a lane")

      holders =
        for gate <- doc["gates"],
            holder = gate["holder"],
            holder not in [nil, "human_architect"],
            not Map.has_key?(registry.by_id, holder),
            do: error("gate #{gate["id"]}: holder #{holder} is not a registered role")

      requires =
        for gate <- doc["gates"],
            tool <- gate["requires"] || [],
            not Map.has_key?(tool_defs, tool),
            do: error("gate #{gate["id"]}: requires undefined tool #{tool}")

      commandless =
        for gate <- doc["gates"],
            gate["kind"] == "command",
            gate["command"] in [nil, ""],
            do: error("gate #{gate["id"]}: kind is command but no command is defined")

      # An empty expansion means a lane that references only itself, or nothing
      # real — a lane that runs no gates while appearing to be a lane.
      empty_lanes =
        for lane <- doc["lanes"],
            {:ok, expanded} <- [Gates.expand(lane["id"])],
            expanded == [],
            do: error("lane #{lane["id"]} expands to no gates")

      unknown_in_lanes ++ holders ++ requires ++ commandless ++ empty_lanes
    else
      {:error, message} -> [error(message)]
    end
  end

  # ---- workflows -----------------------------------------------------------

  @doc false
  def check_workflows(registry) do
    with {:ok, workflows} <- Workflow.list(),
         {:ok, doc} <- Policy.gates() do
      gate_ids = MapSet.new(doc["gates"], & &1["id"])
      lane_ids = MapSet.new(doc["lanes"], & &1["id"])

      duplicates =
        workflows
        |> Enum.frequencies_by(& &1["id"])
        |> Enum.filter(fn {_id, count} -> count > 1 end)
        |> Enum.map(fn {id, _} -> error("workflow id #{id} is defined more than once") end)

      structural =
        workflows
        |> Enum.flat_map(&Workflow.validate(&1, registry, gate_ids, lane_ids))
        |> Enum.map(&error/1)

      duplicates ++ structural
    else
      {:error, message} -> [error(message)]
    end
  end

  # ---- pipelines -----------------------------------------------------------

  @doc false
  def check_pipelines(_registry) do
    with {:ok, pipelines} <- Workflow.pipelines(),
         {:ok, workflows} <- Workflow.list(),
         {:ok, doc} <- Policy.gates() do
      workflow_ids = MapSet.new(workflows, & &1["id"])
      gate_ids = MapSet.new(doc["gates"], & &1["id"])
      lane_ids = MapSet.new(doc["lanes"], & &1["id"])

      used_by =
        for pipeline <- pipelines,
            id <- pipeline["used_by"],
            not MapSet.member?(workflow_ids, id),
            do: error("pipeline #{pipeline["id"]}: used_by names #{id}, which is not a workflow")

      gates =
        for pipeline <- pipelines,
            {stage, gate} <- pipeline["gates"] || %{},
            not MapSet.member?(gate_ids, gate) and not MapSet.member?(lane_ids, gate),
            do: error("pipeline #{pipeline["id"]}/#{stage}: #{gate} is neither a gate nor a lane")

      stages =
        for pipeline <- pipelines,
            {stage, _gate} <- pipeline["gates"] || %{},
            stage not in pipeline["stages"],
            do:
              error(
                "pipeline #{pipeline["id"]}: gate is attached to stage #{stage}, which it does not have"
              )

      used_by ++ gates ++ stages
    else
      {:error, message} -> [error(message)]
    end
  end

  # ---- prompts -------------------------------------------------------------

  @doc false
  def check_prompts(registry) do
    placeholders =
      case Prompt.unknown_placeholders() do
        {:ok, []} ->
          []

        {:ok, unknown} ->
          Enum.map(unknown, &error("prompt template uses undeclared placeholder {{#{&1}}}"))

        {:error, message} ->
          [error(message)]
      end

    composition =
      registry.agents
      |> Enum.flat_map(fn agent ->
        case Prompt.compose(agent["id"]) do
          {:ok, prompt} ->
            if String.contains?(prompt, "{{") do
              [
                error(
                  "#{agent["id"]}: composed prompt still contains an unrendered {{placeholder}}"
                )
              ]
            else
              []
            end

          {:error, message} ->
            [error("#{agent["id"]}: cannot compose a prompt — #{message}")]
        end
      end)

    placeholders ++ composition
  end

  # ---- schemas -------------------------------------------------------------

  @doc false
  def check_schemas(_registry) do
    files = [
      {"registry/agents.json", "registry.schema.json"},
      {"registry/capabilities.json", "capabilities.schema.json"},
      {"registry/domains.json", "domains.schema.json"},
      {"registry/archetypes.json", "archetypes.schema.json"},
      {"registry/role_rules.json", "role_rules.schema.json"},
      {"policies/gates.json", "gates.schema.json"},
      {"policies/tools.json", "tools.schema.json"},
      {"policies/failure.json", "failure.schema.json"},
      {"policies/trust_levels.json", "trust_levels.schema.json"},
      # Both of these shipped with a schema nothing checked them against, which
      # is a schema that is decoration. `evaluators.json` arrived in an earlier change
      # and `models.json` in an earlier change, and neither was in this list until a
      # deliberate break of one of them validated clean.
      {"policies/evaluators.json", "evaluators.schema.json"},
      {"policies/models.json", "models.schema.json"},
      {"policies/dispatch.json", "dispatch.schema.json"},
      {"policies/mcp.json", "mcp.schema.json"},
      {"policies/identity.json", "identity.schema.json"},
      {"pipelines/pipelines.json", "pipelines.schema.json"}
    ]

    from_files =
      Enum.flat_map(files, fn {data_file, schema_file} ->
        validate_against(data_file, schema_file)
      end)

    workflows =
      Noetic.Harness.agents_path("workflows")
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        validate_against(
          Path.relative_to(path, Noetic.Harness.agents_path()),
          "workflow.schema.json"
        )
      end)

    environments =
      Noetic.Harness.agents_path(["evolution", "environments"])
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        validate_against(
          Path.relative_to(path, Noetic.Harness.agents_path()),
          "environment.schema.json"
        )
      end)

    memory =
      Noetic.Harness.agents_path(["memory", "records"])
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        validate_against(
          Path.relative_to(path, Noetic.Harness.agents_path()),
          "memory_record.schema.json"
        )
      end)

    questions =
      Noetic.Harness.Questions.dir()
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        validate_against(
          Path.relative_to(path, Noetic.Harness.agents_path()),
          "decision_question.schema.json"
        )
      end)

    # A candidate is what evolution proposes, and `Evolution.unmeasured/1`
    # refusing a bare string in `fitness_provenance` was code doing the
    # schema's job: this was the one schema under `.agents/schemas` that
    # nothing loaded. The archive holds promoted and rejected
    # candidates, which are the same shape and just as committed.
    candidates =
      [["evolution", "candidates"], ["evolution", "archive"]]
      |> Enum.flat_map(
        &(Noetic.Harness.agents_path(&1)
          |> Path.join("*.json")
          |> Path.wildcard())
      )
      |> Enum.flat_map(fn path ->
        validate_against(
          Path.relative_to(path, Noetic.Harness.agents_path()),
          "evolution_candidate.schema.json"
        )
      end)

    # A worker's claim about its epic. No directory
    # at all is fine: there is none until the first epic lands.
    handoffs =
      Noetic.Harness.agents_path("handoff")
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        relative = Path.relative_to(path, Noetic.Harness.agents_path())
        validate_against(relative, "handoff.schema.json") ++ handoff_rules(path, relative)
      end)

    from_files ++
      workflows ++
      environments ++ memory ++ candidates ++ questions ++ handoffs ++ dangling_schema_pointers()
  end

  # Two rules `handoff.schema.json` cannot state: the evaluator has no
  # `if`/`then`, and no schema sees a file name. A handoff is found by its
  # epic — merge-check reads `.agents/handoff/<epic>.json` at S — so one whose
  # `epic` names another bead is a claim filed where the landing will read it
  # as this epic's. And `ready` is the status a lane result belongs to: a
  # ready handoff with no `lane` asks to be landed on a verdict it does not
  # quote. merge-check trusts the run file over this copy either way; these
  # catch a worker's slip before a landing does.
  defp handoff_rules(path, relative) do
    stem = Path.basename(path, ".json")

    case Loader.load(path) do
      {:ok, %{} = handoff} ->
        misnamed =
          if is_binary(handoff["epic"]) and handoff["epic"] != stem,
            do: [
              error(
                "#{relative}: says epic #{handoff["epic"]}, and a handoff is named for its " <>
                  "epic — .agents/handoff/#{handoff["epic"]}.json"
              )
            ],
            else: []

        unquoted =
          if handoff["status"] == "ready" and not is_map(handoff["lane"]),
            do: [
              error(
                "#{relative}: is ready with no lane. A ready handoff quotes the lane result " <>
                  "of its finished WF-021 run"
              )
            ],
            else: []

        misnamed ++ unquoted ++ ready_rules(handoff, relative) ++ child_rules(handoff, relative)

      # Not an object, or not JSON: the schema pass has already said so.
      _ ->
        []
    end
  end

  # What the schema's descriptions promised and nothing enforced until an
  # independent review of an earlier change wrote handoffs that broke each rule and
  # watched `validate` pass them all. A description the evaluator does not
  # check is a lie in the schema, and merge-check, which would have caught
  # them, is not built yet.
  #
  # `ready` means the lane passed: `run --finish` refuses a failed lane, and a
  # partial one is a question for the coordinator, never a worker's own
  # `--accept-partial` (CLAUDE.md, the worker's protocol). And every child has
  # been decided — an `open` child at `ready` is the epic landing half done.
  defp ready_rules(%{"status" => "ready"} = handoff, relative) do
    verdict = get_in(handoff, ["lane", "verdict"])

    unpassed =
      if is_binary(verdict) and verdict != "passed",
        do: [error("#{relative}: is ready on a #{verdict} lane; ready means the lane passed")],
        else: []

    open =
      for %{"outcome" => "open", "id" => id} <- List.wrap(handoff["children"]),
          do: error("#{relative}: is ready with child #{id} still open")

    unpassed ++ open
  end

  defp ready_rules(_handoff, _relative), do: []

  # A deferral says why; a re-parenting says where to.
  defp child_rules(handoff, relative) do
    for %{} = child <- List.wrap(handoff["children"]),
        message <- child_problem(child),
        do: error("#{relative}: child #{child["id"]} #{message}")
  end

  defp child_problem(%{"outcome" => "deferred"} = child) do
    if blank?(child["note"]), do: ["is deferred with no note saying why"], else: []
  end

  defp child_problem(%{"outcome" => "reparented"} = child) do
    if blank?(child["to"]), do: ["is reparented with no `to` naming its new parent"], else: []
  end

  defp child_problem(_child), do: []

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp validate_against(data_file, schema_file) do
    data_path = Path.join(Noetic.Harness.agents_path(), data_file)
    schema_path = Path.join(Noetic.Harness.agents_path("schemas"), schema_file)

    with {:ok, data} <- Loader.load(data_path),
         {:ok, schema} <- Loader.load(schema_path) do
      data
      |> Schema.validate(schema, data_file)
      |> Enum.map(fn finding ->
        if String.contains?(finding, "does not implement"),
          do: warning(finding),
          else: error(finding)
      end)
    else
      {:error, message} -> [error(message)]
    end
  end

  defp dangling_schema_pointers do
    Noetic.Harness.agents_path()
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Loader.load(path) do
        {:ok, %{"$schema" => pointer}} when is_binary(pointer) ->
          if String.starts_with?(pointer, "http") do
            []
          else
            target = Path.expand(Path.join(Path.dirname(path), pointer))

            if File.exists?(target),
              do: [],
              else: [
                error("#{relative(path)}: $schema points at #{pointer}, which does not exist")
              ]
          end

        _ ->
          []
      end
    end)
  end

  # ---- memory & evolution --------------------------------------------------

  @doc false
  def check_memory(_registry), do: Enum.map(Memory.validate(), &error/1)

  @doc false
  def check_evolution(_registry) do
    case engine(:evolution) do
      nil -> []
      evolution -> Enum.map(evolution.validate(), &error/1)
    end
  end

  # The failure policy exists twice: as prose an agent reads in its prompt, and
  # as data the conductor dispatches on. Duplication with a check is the price
  # of not making the routing table's meaning depend on Markdown whitespace;
  # duplication without one is how the two quietly stop agreeing.
  @doc false
  def check_failure(_registry) do
    json_path = Path.join(Noetic.Harness.agents_path("policies"), "failure.json")
    md_path = Path.join(Noetic.Harness.agents_path("policies"), "failure.md")

    with {:ok, policy} <- Loader.load(json_path),
         {:ok, markdown} <- read_text(md_path),
         classes when is_list(classes) <- policy["classes"] do
      rows = failure_md_rows(markdown)

      table_drift(classes, rows) ++ pattern_errors(classes) ++ terminal_state_errors(policy)
    else
      {:error, reason} -> [error(reason)]
      _ -> [error("failure.json has no `classes` list, so the conductor can route nothing")]
    end
  end

  # Both columns the conductor depends on: the row heading, and the route
  # identifier. Checking only the first left the routes free to drift, and they
  # already had — `capability:qa.regression` against "regression analyst" — in
  # ways that still meant the same thing, which is the state immediately before
  # they stop meaning the same thing.
  defp table_drift(classes, rows) do
    declared = Map.new(classes, &{&1["observed"], &1["route"]})
    seen = Map.new(rows)

    missing_in_md =
      for {observed, _} <- declared,
          not Map.has_key?(seen, observed),
          do: error("failure.json declares #{inspect(observed)} and failure.md has no such row")

    missing_in_json =
      for {observed, _} <- seen,
          not Map.has_key?(declared, observed),
          do:
            error(
              "failure.md has a row #{inspect(observed)} that failure.json does not classify, " <>
                "so the conductor cannot route it"
            )

    drifted =
      for {observed, route} <- declared,
          md_route = Map.get(seen, observed),
          md_route != nil,
          md_route != route,
          do:
            error(
              "#{inspect(observed)} routes to #{inspect(route)} in failure.json and " <>
                "#{inspect(md_route)} in failure.md"
            )

    missing_in_md ++ missing_in_json ++ drifted
  end

  # A pattern that does not compile is silently `false` in the conductor, so the
  # next class in priority order claims the failure and nothing says why. One
  # typo in `test_failed` would reroute every test failure to the domain owner.
  defp pattern_errors(classes) do
    Enum.flat_map(classes, fn class ->
      case class["match"] do
        pattern when is_binary(pattern) ->
          case Regex.compile(pattern, "i") do
            {:ok, _} ->
              []

            {:error, reason} ->
              [
                error(
                  "failure.json class #{class["id"]} has a `match` that is not a regex " <>
                    "(#{inspect(reason)}); the conductor treats an uncompilable pattern as " <>
                    "never matching, so the next class in priority order would claim the failure"
                )
              ]
          end

        _ ->
          []
      end
    end)
  end

  defp terminal_state_errors(policy) do
    states = Map.keys(policy["terminal_states"] || %{})

    unknown =
      for state <- states -- Noetic.Harness.Run.outcomes(),
          do: error("failure.json names a terminal state #{state} the ledger does not accept")

    missing =
      for state <- Noetic.Harness.Run.outcomes() -- states,
          do: error("failure.json does not say where #{state} routes")

    unknown ++ missing
  end

  defp read_text(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  # Every row of the "Failure classes" table as `{observed, route}` — the only
  # table in that file whose header is `| Observed |`. A failed parse fails
  # loudly rather than quietly: `rows == []` makes every class report a missing
  # row, which is noise, and noise is findable.
  defp failure_md_rows(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "| Observed ")))
    |> Enum.drop(2)
    |> Enum.take_while(&String.starts_with?(&1, "|"))
    |> Enum.flat_map(fn line ->
      case line |> String.split("|", trim: true) |> Enum.map(&String.trim/1) do
        [observed, _prose, route | _] when observed != "" ->
          [{observed, String.trim(route, "`")}]

        _ ->
          []
      end
    end)
  end

  @doc false
  def check_environments(_registry) do
    case engine(:environments) do
      nil ->
        []

      environments ->
        %{errors: errors, warnings: warnings} = environments.validate()
        Enum.map(errors, &error/1) ++ Enum.map(warnings, &warning/1)
    end
  end

  # The module behind an engine check, or nil in a build without it. See `@engine`.
  defp engine(check) do
    module = Keyword.fetch!(@engine, check)
    if Code.ensure_loaded?(module), do: module
  end

  # ---- adapters ------------------------------------------------------------

  @doc false
  def check_adapters(registry) do
    Adapters.drift(registry)
    |> Enum.map(fn path ->
      warning(
        "generated adapter #{path} differs from what the canonical definitions produce — run `noetic-harness sync`"
      )
    end)
  end

  # ---- mcp -----------------------------------------------------------------

  # A question edited without a new version is an error: the
  # answers recorded against that version now claim to answer text they never
  # saw. `Noetic.Harness.Questions` says why it is not a warning.
  @doc false
  def check_questions(_registry), do: Noetic.Harness.Questions.check()

  @doc false
  def check_mcp(_registry) do
    case MCP.manifest() do
      {:ok, manifest} -> Enum.map(MCP.validate(manifest), &error/1)
      {:error, message} -> [error("mcp: " <> message)]
    end
  end

  # ---- models --------------------------------------------------------------

  # A review step is refused when every model in `review.models`
  # belongs to a family the step under review used. With two families on the
  # list that can never happen to work one model wrote; with one it happens to
  # every review of that family's work — the unsatisfiable guard this
  # repository's rule says somebody will switch off. So one family is an
  # error, checked here where an edit to the fenced policy would meet it.
  @doc false
  def check_models(_registry) do
    families =
      Noetic.Harness.Adapter.review_models()
      |> Enum.map(&Noetic.Harness.Adapter.model_family/1)
      |> Enum.uniq()

    if length(families) >= 2,
      do: [],
      else: [
        error(
          "models.json review.models names #{length(families)} model family(ies) " <>
            "(#{Enum.join(families, ", ")}); a review step needs a model other than its author's, " <>
            "so the list needs at least two families or the refusal cannot be satisfied"
        )
      ]
  end

  # ---- profiles ------------------------------------------------------------

  # `Profiles.validate/1`
  # already refuses a tracked file two profiles own and `shared` does not
  # declare; that is decided on files, so a glob two profiles both list
  # before any file matches it passed. The three checks here are the ones a
  # file cannot show: the id is one of the six cloud environments'
  # `HARNESS_AGENT` values (a seventh is a profile no worker can be), each
  # names its environment, and a glob or a `shared` entry names only
  # profiles that exist.
  @profile_ids ~w(content harness avatar knowledge memory visual-world)

  @doc false
  def check_profiles(_registry, opts \\ []) do
    loaded = if Keyword.has_key?(opts, :doc), do: {:ok, opts[:doc]}, else: Profiles.load()

    case loaded do
      {:ok, doc} ->
        Profiles.validate(Keyword.put(opts, :doc, doc)) ++
          profile_ids(doc) ++ profile_environments(doc) ++ profile_globs(doc)

      {:error, message} ->
        [error("profiles: " <> message)]
    end
  end

  defp profile_ids(doc) do
    for %{"id" => id} <- profile_entries(doc), id not in @profile_ids do
      error(
        "profiles: #{inspect(id)} is not a profile: the six are " <>
          Enum.join(@profile_ids, ", ")
      )
    end
  end

  defp profile_environments(doc) do
    for profile <- profile_entries(doc),
        not (is_binary(profile["environment"]) and profile["environment"] != "") do
      error("profiles: #{inspect(profile["id"])} names no environment")
    end
  end

  # A glob listed by two profiles, compared as text; and every profile a
  # `shared` entry names. The first is the overlap `Profiles` cannot see until
  # a file lands under it, when two workers may already hold it.
  defp profile_globs(doc) do
    ids = MapSet.new(for %{"id" => id} <- profile_entries(doc), do: id)

    shared =
      for %{"glob" => g, "profiles" => ps} when is_list(ps) <- list(doc, "shared"),
          do: {g, MapSet.new(ps)}

    twice =
      for profile <- profile_entries(doc),
          glob <- List.wrap(profile["owns"]),
          reduce: %{} do
        acc -> Map.update(acc, glob, [profile["id"]], &[profile["id"] | &1])
      end
      |> Enum.filter(fn {_glob, owners} -> length(Enum.uniq(owners)) > 1 end)
      |> Enum.reject(fn {glob, owners} ->
        Enum.any?(shared, fn {g, allowed} ->
          g == glob and MapSet.subset?(MapSet.new(owners), allowed)
        end)
      end)
      |> Enum.sort()
      |> Enum.map(fn {glob, owners} ->
        error(
          "profiles: the glob #{glob} is listed by " <>
            "#{owners |> Enum.uniq() |> Enum.sort() |> Enum.join(" and ")}, " <>
            "which `shared` does not declare"
        )
      end)

    unknown =
      for {glob, named} <- shared, id <- Enum.sort(named), id not in ids do
        error("profiles: `shared` #{glob} names #{inspect(id)}, which is not a profile here")
      end

    twice ++ unknown
  end

  defp profile_entries(doc), do: list(doc, "profiles")

  defp list(%{} = doc, key) do
    case doc[key] do
      items when is_list(items) -> Enum.filter(items, &is_map/1)
      _ -> []
    end
  end

  defp list(_doc, _key), do: []

  # ---- helpers -------------------------------------------------------------

  defp error(message), do: {:error, message}
  defp warning(message), do: {:warning, message}
  defp relative(path), do: Path.relative_to(path, Noetic.Harness.root())
end
