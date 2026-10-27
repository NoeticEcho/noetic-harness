defmodule Noetic.Harness.Router do
  @moduledoc """
  Capability-based routing: work item → capabilities → workflow → team → lane.

  ## Why not route by name

  "Modify the TypeDB schema" must not resolve to "the agent called TypeDB
  Agent". It resolves to the capabilities `typedb.schema` and
  `semantic.modeling`, and those carry the official TypeQL skill, the
  `typeql-check` gate, the schema-inspection context and the migration
  discipline with them. Routing by capability means adding a better-suited role
  changes the route automatically, and it means the *requirements* of a piece of
  work are stated before anybody is assigned to it.

  ## The pipeline

      work item
        ↓  extract/2      signals fire on text, paths and declared kind
      capabilities
        ↓  select_workflow/2
      workflow
        ↓  compose_team/3  smallest set of roles covering the capabilities
      team
        ↓  lane/2
      gate lane

  ## The smallest competent team

  `compose_team/3` is a greedy set cover: repeatedly take the role covering the
  most still-uncovered capabilities, preferring narrower roles on a tie so that
  a generalist does not absorb work a specialist should hold. It stops at
  `:max_team`, which defaults to 5 — the registry has 270 roles and a task that
  appears to need eight of them has been described badly, not discovered to be
  complex.

  Steps marked `independent_of` get a different role from the step they review,
  which is how "the same agent should not be the only authority evaluating its
  own work" becomes a property of the assignment rather than an instruction in
  a prompt.

  ## Honest failure

  When no signal fires, the router does not guess. It reports low confidence and
  routes to intake (WF-001), because a route assembled from nothing is worse
  than saying the work item is too thin to route.
  """

  alias Noetic.Harness.{Loader, Plane, Policy, Registry, Workflow}

  @default_max_team 5

  @type work :: %{
          optional(:id) => String.t(),
          optional(:title) => String.t(),
          optional(:body) => String.t(),
          optional(:kind) => String.t(),
          optional(:paths) => [String.t()],
          optional(:risk) => String.t(),
          optional(:workflow) => String.t()
        }

  @type route :: %{
          title: String.t() | nil,
          capabilities: [String.t()],
          signals: [map()],
          confidence: :high | :medium | :low,
          confidence_score: non_neg_integer(),
          confidence_thresholds: %{high: integer(), medium: integer()},
          kind: %{value: String.t() | nil, source: :declared | :inferred | nil},
          workflow: map() | nil,
          workflow_reason: String.t(),
          candidates: [candidate()],
          team: [map()],
          uncovered: [String.t()],
          lane: String.t(),
          trust: String.t(),
          skills: [String.t()],
          tools: [String.t()],
          gates: [String.t()]
        }

  @typedoc """
  One scored workflow: its id and the four parts of its total. An earlier change —
  the router used to keep only the winner and a sentence about it, so "trigger
  match (score 3) among 9 candidates" could not be argued with.
  """
  @type candidate :: %{
          id: String.t(),
          total: non_neg_integer(),
          family: non_neg_integer(),
          kind: non_neg_integer(),
          keyword: non_neg_integer(),
          capability: non_neg_integer()
        }

  @doc """
  Route a work item. Options: `:max_team`.

  The development router: it chooses among development workflows, and refuses
  a requested runtime one, or a work item whose signals name a runtime
  capability, each by its rule. `validate` refuses such a signal
  before anything routes; this refuses one that reaches the router anyway.
  """
  @spec route(work(), keyword()) :: {:ok, route()} | {:error, String.t()}
  def route(work, opts \\ []) do
    with {:ok, registry} <- Registry.load(),
         {:ok, signals_doc} <- Loader.load(signals_path()),
         :ok <- Workflow.development_refusal(work[:workflow], "routes to"),
         {:ok, workflows} <- Workflow.list("development"),
         {capabilities, fired} = extract(work, signals_doc),
         :ok <- development_capabilities(registry, capabilities, fired) do
      {confidence, score} = confidence(fired, signals_doc)
      {workflow, reason} = select_workflow(work, workflows, capabilities, signals_doc)

      candidates =
        if work[:workflow],
          do: [],
          else:
            work
            |> score_workflows(workflows, capabilities, signals_doc)
            |> Enum.map(&candidate/1)

      {team, uncovered} =
        compose_team(registry, capabilities, Keyword.get(opts, :max_team, @default_max_team))

      lane = lane(workflow, work)
      trust = highest_step_trust(workflow)

      {:ok,
       %{
         # What was routed, so that a second opinion (`SecondOpinion`) judges
         # the same words the router did rather than the router's reading of them.
         title: work[:title],
         capabilities: capabilities,
         signals: fired,
         confidence: confidence,
         confidence_score: score,
         confidence_thresholds: thresholds(signals_doc),
         kind: %{
           value: kind(work, fired, signals_doc),
           source: kind_source(work, fired, signals_doc)
         },
         workflow: workflow,
         workflow_reason: reason,
         candidates: candidates,
         team: team,
         uncovered: uncovered,
         lane: lane,
         trust: trust,
         skills: collect(team, "skills"),
         tools: collect(team, "tools"),
         gates: collect(team, "gates")
       }}
    end
  end

  defp development_capabilities(registry, capabilities, fired) do
    case Enum.filter(capabilities, &Plane.runtime?(registry.capabilities[&1])) do
      [] ->
        :ok

      runtime ->
        signals =
          fired
          |> Enum.filter(fn signal ->
            Enum.any?(signal["capabilities"] || [], &(&1 in runtime))
          end)
          |> Enum.map_join(", ", & &1["id"])

        from = if signals == "", do: "this work item's kind", else: "the signals #{signals}"

        {:error,
         "the runtime capabilities #{Enum.join(runtime, ", ")} come from #{from}, and the " <>
           "development router routes only to development capabilities"}
    end
  end

  @doc """
  The capabilities a work item requires, and the signals that produced them.

  Signals fire independently and contribute additively. A path signal is worth
  more than a text signal in the confidence calculation because the paths are
  what the change actually touched, while the text is what somebody said about
  it — and those disagree often enough to be worth weighting.
  """
  @spec extract(work(), map()) :: {[String.t()], [map()]}
  def extract(work, signals_doc) do
    fired = fire(work, signals_doc)
    from_kind = get_in(signals_doc, ["kind_signals", kind(work, fired, signals_doc) || ""]) || []
    from_signals = Enum.flat_map(fired, & &1["capabilities"])

    case Enum.uniq(from_signals ++ from_kind) do
      [] -> {get_in(signals_doc, ["fallback", "capabilities"]), []}
      capabilities -> {Enum.sort(capabilities), fired}
    end
  end

  defp fire(work, signals_doc) do
    text = String.downcase(Enum.join([work[:title] || "", work[:body] || ""], "\n"))
    paths = work[:paths] || []

    for signal <- signals_doc["signals"],
        matches = signal_matches(signal, text, paths),
        matches != [],
        do: Map.put(signal, "matched_on", matches)
  end

  @doc """
  The work item's kind: what the caller declared, or what its signals imply.

  A kind is worth 4 to workflow selection and pulls capabilities out of
  `kind_signals`, and it used to arrive only from a caller — in practice only
  from a bead's `Type:`. A free-text prompt had none, and a prompt is what the
  `UserPromptSubmit` hook routes, which is now most of the routing done here.
  The result was that a crash reported in one domain's words scored 9 for
  WF-003 *Bug → Root Cause* and 10 for that domain's feature workflow: a bug is always
  **in** a domain, so the domain's keywords and capabilities always match it,
  and the failure verb always loses. That is an earlier change, and the intent it
  violated was already written in this module's own comment and in
  `signals.json`'s `weights` doc.

  The inference is data: `kind_inference.precedence` orders the families by how
  reliably each classifies the *kind* of work rather than its subject, and
  `kind_inference.kinds` maps a family to a kind where the two words differ
  (`operations` → `incident`). More than one family fires on a real sentence,
  which is why there is a precedence at all.
  """
  @spec kind(work(), map()) :: String.t() | nil
  def kind(work, signals_doc), do: kind(work, fire(work, signals_doc), signals_doc)

  defp kind(work, fired, signals_doc) do
    work[:kind] || inferred_kind(fired, signals_doc)
  end

  defp inferred_kind(fired, signals_doc) do
    families = fired |> Enum.map(& &1["family"]) |> Enum.reject(&is_nil/1) |> MapSet.new()
    inference = signals_doc["kind_inference"] || %{}

    case Enum.find(inference["precedence"] || [], &MapSet.member?(families, &1)) do
      nil -> nil
      family -> get_in(inference, ["kinds", family]) || family
    end
  end

  @doc """
  Choose the workflow.

  An explicit `:workflow` on the work item wins — a human naming a workflow is
  the most reliable signal there is. Otherwise the workflow whose trigger
  keywords and kinds best match, with capability overlap as the tiebreak. With
  no evidence at all it is WF-001, which is the workflow for "we do not yet know
  what this is".
  """
  @spec select_workflow(work(), [map()], [String.t()], map()) :: {map() | nil, String.t()}
  def select_workflow(work, workflows, capabilities, signals_doc) do
    cond do
      work[:workflow] ->
        case Enum.find(workflows, &(&1["id"] == work[:workflow])) do
          nil -> {nil, "requested workflow #{work[:workflow]} does not exist"}
          workflow -> {workflow, "requested explicitly"}
        end

      true ->
        case score_workflows(work, workflows, capabilities, signals_doc) do
          [{workflow, parts} | rest] ->
            {workflow, why(parts, workflow, rest)}

          [] ->
            fallback = get_in(signals_doc, ["fallback", "workflow"])

            {Enum.find(workflows, &(&1["id"] == fallback)),
             "no workflow trigger matched; falling back to #{fallback} because the item is under-specified"}
        end
    end
  end

  @doc """
  Every workflow with a non-zero score, best first, each with the four parts
  of its score. The order is the one `select_workflow/4` chooses from, tie-break
  included, so the head of this list is the route's workflow.
  """
  @spec score_workflows(work(), [map()], [String.t()], map()) :: [{map(), map()}]
  def score_workflows(work, workflows, capabilities, signals_doc) do
    text = String.downcase(Enum.join([work[:title] || "", work[:body] || ""], "\n"))

    # Families classify from the title alone. The title says what
    # the work *is*; the body says what it touches, and a bead body about a
    # toolchain upgrade that mentions "the onlooker" or "render" fired the
    # `visual` family, whose 5 outweighed the bead's declared kind. The body
    # still reaches the keywords and, through `fire/2`, the capabilities —
    # it informs the team, not the classification. Paths stay: they are what
    # the change touched, which `signals.json` already weights above text.
    # Measured on the corpus's
    # tune half before the held-out half was read: bead mode 50.5% → 59.4%.
    families = fired_families(%{title: work[:title], paths: work[:paths]}, signals_doc)
    family_weight = get_in(signals_doc, ["weights", "family"]) || 0
    kind = kind(work, signals_doc)

    # A workflow whose trigger says `explicit` is started by id and never
    # scored. WF-021, a worker's epic in a branch, carries the
    # commonest capabilities at the least authority but one, so it won every
    # tie in which only capabilities matched: 44 of the corpus's 438 routes
    # moved to it, and every edit under `.agents/` was told its lane was
    # `handoff`. Empty keywords could not stop that; the tie-break is by
    # authority, not by intent. `select_workflow/4`'s explicit branch
    # searches the full list, so `run --start WF-021` still reaches it.
    workflows
    |> Enum.reject(&(get_in(&1, ["trigger", "explicit"]) == true))
    |> Enum.map(&{&1, workflow_score(&1, kind, text, capabilities, families, family_weight)})
    |> Enum.reject(fn {_workflow, parts} -> parts.total == 0 end)
    |> Enum.sort_by(fn {workflow, parts} ->
      # This used to sort on the score alone, and
      # `Enum.sort_by/2` is stable — so a tie was broken by the order the
      # workflows happened to be loaded in. `update the dev-services
      # healthcheck for typedb` and `docker compose brings up two
      # services of three` both tied WF-015 Release against WF-016
      # Incident at one point of capability overlap, and Release won
      # because it sorts first. A coin flip was choosing the trust level,
      # the lane, and whether `git.push` was in the tool set.
      #
      # The tie-break is **the least authority**, then specificity.
      #
      # Specificity alone was tried first and is wrong on its own: it
      # sent `fix the qdrant client auth header` to WF-014 API
      # productization over WF-002 RFC → Implementation on 0.22 against
      # 0.18, a difference with no meaning, and undid an earlier change.
      #
      # Least-authority is not a preference, it is §8 of the
      # constitution — authority is scoped and not yours to raise. Two
      # workflows the evidence cannot separate must not be separated by
      # whichever hands out more: `git.push`, the protected gate and T4
      # are not a coin-flip's to give. Weight is the gate count of the
      # workflow's own declared lane, computed from the registry, so it
      # tracks the lanes rather than a list somebody has to maintain.
      #
      # Specificity stays as the second key, where it decides between
      # workflows of equal authority and cannot raise any.
      {-parts.total, authority(workflow), -specificity(workflow, capabilities), workflow["id"]}
    end)
  end

  defp candidate({workflow, parts}), do: Map.put(parts, :id, workflow["id"])

  @doc """
  The smallest set of roles covering the capabilities.

  Returns `{team, uncovered}`. `uncovered` is not an error — it is the honest
  answer that this repository has no role for part of this work, and it belongs
  in the route report rather than being silently dropped.
  """
  @spec compose_team(Registry.t(), [String.t()], pos_integer()) :: {[map()], [String.t()]}
  def compose_team(registry, capabilities, max_team \\ @default_max_team) do
    cover(registry, MapSet.new(capabilities), [], max_team)
  end

  defp cover(registry, remaining, team, max) do
    cond do
      MapSet.size(remaining) == 0 ->
        {Enum.reverse(team), []}

      length(team) >= max ->
        {Enum.reverse(team), remaining |> MapSet.to_list() |> Enum.sort()}

      true ->
        case best_role(registry, remaining, team) do
          nil ->
            {Enum.reverse(team), remaining |> MapSet.to_list() |> Enum.sort()}

          role ->
            covered = MapSet.intersection(remaining, MapSet.new(role["capabilities"]))
            cover(registry, MapSet.difference(remaining, covered), [role | team], max)
        end
    end
  end

  # Greedy: most uncovered capabilities first. Ties go to the role with the
  # fewest total capabilities — the specialist rather than the generalist — and
  # then to the nucleus, because a nucleus role is one the workflows already
  # route to and an adapter already exists for.
  #
  # Development roles only: a team is what the development engine staffs, and a
  # runtime role is never one of it.
  defp best_role(registry, remaining, team) do
    taken = MapSet.new(team, & &1["id"])

    registry.agents
    |> Enum.reject(
      &(MapSet.member?(taken, &1["id"]) or &1["status"] != "active" or Plane.runtime?(&1))
    )
    |> Enum.map(fn role ->
      gain = MapSet.size(MapSet.intersection(remaining, MapSet.new(role["capabilities"])))
      {role, gain}
    end)
    |> Enum.reject(fn {_role, gain} -> gain == 0 end)
    |> Enum.sort_by(fn {role, gain} ->
      {-gain, length(role["capabilities"]), if(role["nucleus"], do: 0, else: 1), role["id"]}
    end)
    |> case do
      [{role, _gain} | _] -> role
      [] -> nil
    end
  end

  @doc """
  The gate lane for this work.

  The workflow's `default_lane`, raised for high risk. Never lowered: a lane is
  a floor, and a caller that wants a cheaper check is asking to skip one.
  """
  @spec lane(map() | nil, work()) :: String.t()
  def lane(nil, _work), do: "fast"

  def lane(workflow, work) do
    base = workflow["default_lane"] || "focused"
    risk = work[:risk] || get_in(workflow, ["trigger", "risk"]) || "low"

    case {base, risk} do
      {"fast", "high"} -> "focused"
      {"focused", "high"} -> "full"
      {lane, _} -> lane
    end
  end

  @doc """
  Roles that may not both take the same pair of steps.

  Derived from `independent_of` in the workflow. The router reports the
  constraint; enforcing it is the orchestrator's job, but stating it explicitly
  is what turns "should be reviewed independently" into something checkable.
  """
  @spec independence_constraints(map() | nil) :: [{String.t(), String.t()}]
  def independence_constraints(nil), do: []

  def independence_constraints(workflow) do
    for step <- workflow["steps"] || [],
        other <- step["independent_of"] || [],
        do: {step["id"], other}
  end

  # The families implied by the signals that fired. A signal has already decided
  # what *kind* of work this is, and that classification beats counting domain
  # nouns: "the product channel crashes" is a bug report that mentions the product,
  # not a world feature that mentions a crash.
  defp fired_families(work, signals_doc) do
    work
    |> fire(signals_doc)
    |> Enum.map(& &1["family"])
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # How much authority the workflow hands out: the highest trust any of its
  # steps grants, then the gate count of its declared lane. Trust first because
  # it is what the constitution sentence above names — T4 is not a coin-flip's
  # to give — and gate count alone got it backwards: the evolution lane has
  # seven gates to `focused`'s nine and grants T4 to its T3, so a three-way tie
  # between WF-020, WF-009 and WF-002 went to the one that hands out the most.
  # `nil` for a workflow that declares no lane sorts last, because an
  # unknown authority is not a low one.
  defp authority(workflow) do
    {trust_rank(highest_step_trust(workflow)), lane_gates(workflow)}
  end

  defp trust_rank("T" <> n) do
    case Integer.parse(n) do
      {rank, ""} -> rank
      _ -> 99
    end
  end

  defp trust_rank(_), do: 99

  defp lane_gates(workflow) do
    case workflow["default_lane"] do
      nil ->
        999

      lane ->
        case Noetic.Harness.Gates.expand(lane) do
          {:ok, gates} -> length(gates)
          _ -> 999
        end
    end
  end

  # How much of the workflow this overlap accounts for. 1.0 means every
  # capability the workflow carries was claimed; a large workflow sharing one
  # capability scores near zero. Undefined for a workflow with no capabilities
  # at all, which is treated as no fit rather than a perfect one.
  defp specificity(workflow, capabilities) do
    theirs = MapSet.new(Workflow.capabilities(workflow))

    case MapSet.size(theirs) do
      0 -> 0.0
      n -> MapSet.size(MapSet.intersection(MapSet.new(capabilities), theirs)) / n
    end
  end

  # The sentence `--explain` prints, and an earlier change is about it saying two
  # things that were not true. It said "best trigger match (score N)" when no
  # trigger had matched at all — N was capability overlap and nothing else —
  # and it did not say that the workflow behind it had tied with another.
  # A reader uses that sentence to decide whether to believe the route.
  defp why(parts, workflow, rest) do
    tied =
      rest
      |> Enum.take_while(fn {_w, other} -> other.total == parts.total end)
      |> Enum.map(fn {w, _} -> w["id"] end)

    basis =
      if parts.family + parts.kind + parts.keyword > 0 do
        "trigger match (score #{parts.total})"
      else
        "capability overlap only, no trigger matched (score #{parts.total})"
      end

    tie =
      case tied do
        [] ->
          ""

        ids ->
          " — tied with #{Enum.join(ids, ", ")}, broken on least authority " <>
            "(#{highest_step_trust(workflow)}, #{workflow["default_lane"]}, " <>
            "#{lane_gates(workflow)} gates)"
      end

    "#{basis} among #{length(rest) + 1} candidates#{tie}"
  end

  defp workflow_score(workflow, kind, text, capabilities, families, family_weight) do
    trigger = workflow["trigger"] || %{}

    family_score =
      if MapSet.member?(families, workflow["family"]), do: family_weight, else: 0

    # `kind` here is the *effective* kind — declared, or inferred from the
    # fired families. See `kind/2`.
    kind_score =
      if kind && kind in (trigger["kinds"] || []), do: 4, else: 0

    # A leading word boundary and no trailing one. Substring matching sent a
    # TypeDB schema change to the release workflow because "authorship" contains
    # "ship"; a trailing boundary as well then lost "crashes" for the keyword
    # "crash", which sent a crash report to the product-feature workflow. Prefix
    # matching at a word boundary is what actually survives English inflection.
    keyword_score =
      (trigger["keywords"] || [])
      |> Enum.count(fn keyword ->
        Regex.match?(~r/\b#{Regex.escape(String.downcase(keyword))}/, text)
      end)
      |> Kernel.*(3)

    capability_score =
      MapSet.intersection(MapSet.new(capabilities), MapSet.new(Workflow.capabilities(workflow)))
      |> MapSet.size()

    %{
      family: family_score,
      kind: kind_score,
      keyword: keyword_score,
      capability: capability_score,
      total: family_score + kind_score + keyword_score + capability_score
    }
  end

  defp confidence(fired, signals_doc) do
    weights = signals_doc["weights"] || %{}

    score =
      Enum.reduce(fired, 0, fn signal, acc ->
        acc +
          Enum.reduce(signal["matched_on"], 0, fn kind, inner ->
            inner + (weights[kind] || 1)
          end)
      end)

    %{high: high, medium: medium} = thresholds(signals_doc)

    level =
      cond do
        score >= high -> :high
        score >= medium -> :medium
        true -> :low
      end

    {level, score}
  end

  # These were 6 and 2 in Elixir, and the score they were compared
  # with was never returned — so a `:low` that hid a prompt from the hook could
  # not be told apart from one that nearly made it. Data now, beside the weights
  # that produce the score, and both travel on the route.
  defp thresholds(signals_doc) do
    t = signals_doc["confidence"] || %{}
    %{high: t["high"] || 6, medium: t["medium"] || 2}
  end

  defp kind_source(work, fired, signals_doc) do
    cond do
      work[:kind] -> :declared
      inferred_kind(fired, signals_doc) -> :inferred
      true -> nil
    end
  end

  defp signal_matches(signal, text, paths) do
    text_match =
      case signal["text"] do
        nil -> false
        pattern -> Regex.match?(compile(pattern), text)
      end

    path_match =
      case signal["path"] do
        nil ->
          false

        pattern ->
          regex = compile(pattern)
          Enum.any?(paths, &Regex.match?(regex, &1))
      end

    Enum.reject([if(path_match, do: "path"), if(text_match, do: "text")], &is_nil/1)
  end

  defp compile(pattern), do: Regex.compile!(pattern, "i")

  defp highest_step_trust(nil), do: "T0"

  defp highest_step_trust(workflow) do
    (workflow["steps"] || [])
    |> Enum.map(& &1["trust"])
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce("T0", fn level, highest ->
      if Policy.at_least?(level, highest), do: level, else: highest
    end)
  end

  defp collect(team, key) do
    team |> Enum.flat_map(&(&1[key] || [])) |> Enum.uniq() |> Enum.sort()
  end

  defp signals_path, do: Path.join(Noetic.Harness.agents_path("registry"), "signals.json")
end
