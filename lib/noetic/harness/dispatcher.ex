defmodule Noetic.Harness.Dispatcher do
  @moduledoc """
  The part of the harness that acts.

  A design decision reversed a design decision's decline, and this is the module it decided to
  build. It is the third thing beside `Run` and `Conductor`, not a widening of
  either: `Run`'s moduledoc is built on "this module never decides what happens
  next" and `Conductor`'s on "never calls an agent", and those two sentences
  are why the ledger is trustworthy.

  So the division is:

      Conductor   decides   — what step, at what trust, behind which gates
      Dispatcher  acts      — composes the prompt, calls the agent, fences the
                              result, hands it back
      Run         records   — and neither of the other two writes to it directly

  Everything this module decides, the conductor already decided. Everything it
  records goes through `Run`. What it adds is the `System.cmd` and everything
  that makes a `System.cmd` safe.

  ## What it refuses, which is the product

  `prepare/2` answers whether a dispatch may happen at all, and it is where the
  reading happens. A caller that skips it and calls the adapter directly has
  left the fence outside, so `dispatch/2` will not do that: it prepares first
  and refuses on anything `prepare/2` returns.

  Four refusals, each naming its rule and the file the rule lives in, like
  every conductor refusal:

  * **the conductor says no** — stalled, exhausted, looping, blocked, or a debt
    outstanding. The dispatcher does not second-guess it and does not have its
    own copy of the reasoning.
  * **depth**. Depth is the axis on which a bounded thing becomes
    unbounded, and no per-step attempt count can see it.
  * **wall-clock** — inherited as *remaining*, not as a fresh allowance, or
    depth 2 on a 30-minute budget is 90 minutes wearing a 30-minute label.
  * **trust** — `Policy.derive_trust/3`, which only narrows. There is no path
    by which a parent hands a child more than it holds.

  And after the agent has run, before anything is handed back:

  * **the fence** — `Noetic.Harness.Fence`. A dispatched run that changed a
    file the evaluator fence protects does not land, and the refusal names the
    path. A design decision and constitution §4/§23.

  ## What it does not do

  **It does not land anything.** A dispatched run's product is a diff and a
  ledger entry. Pushing, merging, or touching a branch anything else has is the
  parent's business and, above T3, a human's.

  **It does not choose the agent.** `adapter/0` resolves one from configuration
  so that `claude -p` is a default rather than a fact compiled into the fence.
  The default adapter in tests records the call and runs nothing, because a
  test suite that spends money is a test suite nobody runs.

  **It does not know whether the work was good.** Success is handed back for the
  caller to judge and record. What it *does* know is its own failures, and it
  writes those itself:

      dispatch can record a `failed`. It can never record a `done`.

  That asymmetry is the enforcement of "a dispatched step that produced no
  evidence is `failed`, not `done`". The ledger already refuses a `done` with no
  evidence; making dispatch structurally unable to write one means it cannot
  become the way round that either, and it is one property to test rather than a
  sentence every caller has to be trusted to have read.

  The three failures it owns: the adapter erred, the fence refused, or the agent
  returned nothing. Each is recorded through `Run.record/2` with the evidence and
  with `Conductor.classify/1`'s routing in the note — one answer to "where does
  this failure go", not a second copy of it.

  **The tree is fingerprinted before the call as well as after.** `Run.record/2`
  takes the fingerprint at record time, which is the *after*; `tree_before` on
  the result is the other half, and a dispatched attempt that changed nothing is
  a stall the conductor can already see — but only if the dispatcher records
  honestly, including when nothing happened.
  """

  alias Noetic.Harness.{Adapter, Conductor, Context, Fence, Git, Policy, Prompt, Run, Workspace}

  @default_depth 2
  @default_wall_clock_ms 30 * 60 * 1000
  @default_cost_usd 5.0

  @halting ~w(stalled exhausted looping blocked)

  # Read by `Run.start/1`. See `as_parent/2`.
  @parent_env "NOETIC_HARNESS_PARENT_RUN"

  @typedoc """
  What a dispatch needs to know about the run that asked for it.

  `depth` is how many dispatches deep this already is; `remaining_ms` is what
  is left of the *parent's* wall-clock, not a fresh allowance; `trust` is the
  parent's effective trust, which is a ceiling and never a grant.
  """
  @type parent :: %{
          optional(:depth) => non_neg_integer(),
          optional(:remaining_ms) => non_neg_integer(),
          optional(:trust) => String.t() | nil
        }

  @doc """
  The adapter module, when one is pinned directly.

  Three levels, most specific first:

      config :noetic_harness, :dispatch_adapter, SomeModule   # a module, for tests
      config :noetic_harness, :dispatch_adapter_id, "claude_code"
      .agents/policies/models.json  →  "default"

  The first is how a test injects one and is deliberately not how anything else
  should; the second and third go through `Noetic.Harness.Adapter`, which can
  only name an adapter this code already has. A configuration key that can name
  an arbitrary module is a configuration key that can run arbitrary code.
  """
  @spec adapter() :: module() | nil
  def adapter, do: Application.get_env(:noetic_harness, :dispatch_adapter)

  @doc """
  The depth ceiling. A design decision, `.agents/policies/dispatch.json`.

  The policy is the source; application config overrides it, which is how a
  test pins a ceiling of 0 without editing a fenced file. The policy lives
  inside the evaluator fence so that a *dispatched* run cannot raise its own
  ceiling — which application config, being code, equally cannot be reached by
  an agent whose diff is fenced.
  """
  @spec depth_ceiling() :: non_neg_integer()
  def depth_ceiling do
    Application.get_env(:noetic_harness, :dispatch_depth) ||
      policy_number(["depth", "max"], @default_depth)
  end

  @doc """
  The wall-clock ceiling for a whole dispatch tree, in milliseconds. 
  """
  @spec wall_clock_ceiling() :: pos_integer()
  def wall_clock_ceiling do
    Application.get_env(:noetic_harness, :dispatch_wall_clock_ms) ||
      policy_number(["wall_clock", "max_ms"], @default_wall_clock_ms)
  end

  @doc """
  The cost ceiling for a whole dispatch tree, in US dollars. 

  It binds only on what an adapter actually reported. `claude -p` returns
  `total_cost_usd`; the API adapters return token counts and no price, and an
  unknown cost is recorded as unknown rather than as zero — a zero would make
  this ceiling unreachable by exactly the adapters whose spend is hardest to
  see. The honest consequence is that a run whose cost is unknown is bounded
  by depth and wall-clock alone, and `prepare/2` says so in the plan rather
  than letting it pass silently (§32).
  """
  @spec cost_ceiling() :: float()
  def cost_ceiling do
    Application.get_env(:noetic_harness, :dispatch_cost_usd) ||
      policy_number(["cost", "max_usd"], @default_cost_usd)
  end

  defp policy_number(path, default) do
    case Policy.dispatch() do
      {:ok, doc} -> get_in(doc, path) || default
      {:error, _} -> default
    end
  end

  @doc """
  Whether this dispatch may happen, and with what.

  Returns `{:ok, plan}` — carrying the role, the composed prompt, the derived
  trust, the depth and the wall-clock left — or `{:refused, reasons}`, a list
  of maps each with a `:rule` and a `:why`.

  This is the reading half, and it is separate from `dispatch/2` on purpose: a
  caller can ask "would this be allowed?" without anything happening, which is
  what `noetic-harness conduct` wants and what a test wants.
  """
  @spec prepare(String.t(), parent()) :: {:ok, map()} | {:refused, [map()]}
  def prepare(run_id, parent \\ %{}) do
    # The ledger first, the argument second, and the *stricter* of the two.
    # `parent` used to be the only source, so a caller that passed `%{}` —
    # including an agent that had itself been dispatched — was believed to be
    # at depth 0 with a full allowance. A ceiling checked against a number the
    # bounded thing supplies is not a ceiling.
    spent = Run.spent(run_id)
    depth = max(Map.get(parent, :depth, 0), Run.depth(run_id))

    remaining =
      min(
        Map.get(parent, :remaining_ms, wall_clock_ceiling()),
        max(wall_clock_ceiling() - spent.elapsed_ms, 0)
      )

    with [] <- ceiling_refusals(depth, remaining, spent),
         [] <- stop_refusals(run_id),
         {:ok, advice} <- advice(run_id),
         [] <- conductor_refusals(advice) do
      plan(advice, parent, depth, remaining, spent)
    else
      {:error, message} -> {:refused, [%{rule: "run", why: message}]}
      refusals when is_list(refusals) -> {:refused, refusals}
      {:refused, _} = refused -> refused
    end
  end

  @doc """
  Dispatch an agent at a prompt, in a workspace somebody else opened.

  `dispatch/2` runs a **workflow step**: it asks the conductor what is next,
  staffs it from the registry, derives a trust from the parent's and the
  role's, and refuses on everything a step can be refused on. Scoring a
  candidate is not a workflow step — it is one task handed to an agent in two
  different trees, and the comparison is the point — so this is the entry that
  keeps the bounds without the staffing.

  What it keeps, and these are the parts that matter: the depth, wall-clock and
  cost ceilings, read from the **ledger** rather than from the caller; the
  stop, read before the adapter; the evaluator fence over what changed in the
  workspace; the spend recorded back to the run; and the refusal to dispatch
  anything at T4 or T5.

  What it does not have is a step, a role or a derived trust, so it cannot and
  does not write a step outcome: `record: false` is forced. A scoring attempt's
  result belongs to the scoring run's own record, not to the caller's step
  ledger.

  ## `:task_paths`, which is the one place the fence is narrowed

  The files the task named — an environment's `verifier.source_paths`. The
  fence judges everything the run changed *except* these.

  Without it, an environment whose source paths are fenced cannot be scored at
  all — exactly the files a self-developing loop most needs to be measured on.
  `.agents/policies/evaluators.json` fences **fourteen** globs, of which eight
  are the harness's own modules: `validation.ex`, `gates.ex`, `conductor.ex`,
  `dispatcher.ex`, `environments.ex`, `evolution.ex`, `scoring.ex` and
  `tree.ex`. (An earlier draft of this paragraph said five, having dropped an
  "including" from the run ledger on the way in. The three it lost were
  `gates.ex`, `conductor.ex` and the module you are reading.) Refusing them
  was the safe direction and it is what happened, so an earlier change was a
  limitation rather than a hole; the cost was that the benchmark silently
  excluded the half of the suite that is about the harness itself.

  What keeps the exemption narrow, stated as what is actually enforced:

  * **`dispatch/2` cannot be given one.** The exemption lives in the *plan*,
    and `plan/5` — the workflow path, the one that produces a diff a human is
    asked to land — writes `[]` there. There is no option that reaches it.
    Note what this does **not** say: `attempt/3` is public and takes a
    `:workspace` from its caller, so the enforced property is about
    `dispatch/2` and not about every diff anybody might land.
  * **It may not reach what defines passing.** `Fence.unexemptible/1`: the
    policy marks the ten harness modules `exemptible` and does not mark
    `.agents/**`, `.github/workflows/**` or `scripts/ci-local.sh`. Without
    that distinction the exemption covered two CI workflow files of a real
    derived environment.
  * **Exact paths as git spells them.** A `*`, a `./`, a `..`, an absolute
    path or an empty string is refused. The reason is not that a glob would
    widen anything — `paths -- task_paths` is string subtraction, so a glob
    exempts nothing — it is that `Tree.confine/3` would then revert the
    solver's correct fix and the arm would score `false` rather than refuse.
    A wrong number is worse than a refusal.
  * **It is subtracted, not switched.** A solver that does the task *and*
    rewrites a policy arrives as one diff, and the second half is still
    refused.

  What it does **not** buy, because an independent review built the
  counter-example and ran it: a scoring tree is **not** a containment
  boundary. `mix test` compiles the solver's file before ExUnit loads the
  verifier, so a module body in a task path is code the scoring host runs —
  it can rewrite the restored oracle, and it can write outside the worktree,
  which no fence here sees. `Scoring` hashes the verifier before and after the
  run and calls a mismatch `unusable`, which catches the naive case and is
  detection rather than prevention. The fence's own guarantee is
  about what **lands**, and that one is intact: a scoring worktree lands
  nothing and is discarded.
  """
  @spec attempt(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:refused, [map()]} | {:error, term()}
  def attempt(run_id, prompt, opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    label = Keyword.get(opts, :label, "attempt")
    trust = Keyword.get(opts, :trust, "T2")
    spent = Run.spent(run_id)
    depth = Run.depth(run_id)
    remaining = max(wall_clock_ceiling() - spent.elapsed_ms, 0)

    with {:ok, exempt} <- task_paths(opts),
         :ok <- protected?(trust, trust),
         [] <- ceiling_refusals(depth, remaining, spent),
         [] <- stop_refusals(run_id),
         {:ok, agent_plan} <- agent_for(trust) do
      plan = %{
        run: run_id,
        step: label,
        role: "task",
        trust: trust,
        depth: depth + 1,
        remaining_ms: remaining,
        spent_ms: spent.elapsed_ms,
        spent_usd: spent.cost_usd,
        cost_known?: spent.cost_known?,
        adapter: agent_plan.id,
        adapter_module: agent_plan.module,
        model: agent_plan.model,
        restricted: true,
        task_paths: exempt,
        prompt: prompt
      }

      run_in(plan, workspace, opts |> Keyword.delete(:workspace) |> Keyword.put(:record, false))
    else
      {:refused, _} = refused -> refused
      refusals when is_list(refusals) -> {:refused, refusals}
    end
  end

  @doc """
  Prepare, call the agent, and fence what came back.

  Never lands anything. The caller records the outcome through `Run`, with the
  evidence this returns — and a dispatch that produced no output is a failure
  rather than a step that quietly counts as done.

  The agent runs **inside the run's own git worktree** and is told so: `opts`
  reach the adapter with `:cwd` set to it. A run that cannot be isolated is
  refused before the adapter is called, rather than being allowed to write into
  whoever's tree the parent happens to be standing in.

  The fence then judges what changed *in that worktree*, which is the only
  place a dispatched run can have changed anything. `Workspace.changed_paths/1`
  answering `{:error, _}` is a refusal and not an empty list: "could not see"
  and "nothing to see" are different facts.

  `:workspace` supplies one instead of opening it, which is what a caller
  driving several dispatches into one tree does. There is deliberately no
  option that turns the worktree off.
  """
  @spec dispatch(String.t(), keyword()) :: {:ok, map()} | {:refused, [map()]} | {:error, term()}
  def dispatch(run_id, opts \\ []) do
    parent = Keyword.get(opts, :parent, %{})

    case prepare(run_id, parent) do
      {:refused, _} = refused ->
        refused

      {:ok, plan} ->
        case workspace(run_id, opts) do
          {:ok, workspace} -> guard_then_run(plan, workspace, run_id, opts)
          {:refused, _} = refused -> refused
        end
    end
  end

  # Opening a worktree is cheap and a dispatch is minutes, so the stop is read
  # once more here — between the plan and the call, which is the window a stop
  # issued by a person is most likely to land in.
  defp guard_then_run(plan, workspace, run_id, opts) do
    case stop_refusals(run_id) do
      [] -> run_in(plan, workspace, opts)
      refusals -> {:refused, refusals}
    end
  end

  # §33, and the one refusal here that happens before anything runs: a run that
  # cannot be isolated is not run unisolated. The adapter is never reached.
  defp workspace(run_id, opts) do
    case Keyword.fetch(opts, :workspace) do
      {:ok, workspace} ->
        {:ok, workspace}

      :error ->
        case Workspace.open(run_id) do
          {:ok, workspace} -> {:ok, workspace}
          {:error, message} -> {:refused, [%{rule: "workspace", why: message}]}
        end
    end
  end

  defp run_in(plan, workspace, opts) do
    started = System.monotonic_time(:millisecond)
    before = fingerprint()

    adapter_opts =
      opts
      |> Keyword.put(:trust, plan.trust)
      |> Keyword.put(:cwd, workspace.path)
      |> Keyword.put(:model, plan.model)
      |> Keyword.put(:restricted, plan.restricted)
      |> Keyword.delete(:workspace)

    case as_parent(plan.run, fn -> plan.adapter_module.call(plan.prompt, adapter_opts) end) do
      {:ok, output} ->
        elapsed = System.monotonic_time(:millisecond) - started
        settle(plan, workspace, output, before, elapsed, opts)

      {:error, reason} ->
        fail(plan, ["the agent could not be called: #{inspect(reason)}"], opts)
        {:error, reason}
    end
  end

  # The dispatching run's id, exported for the duration of the call.
  #
  # `Run.start/1` reads `NOETIC_HARNESS_PARENT_RUN`, so an agent that opens a
  # run of its own while it is being dispatched opens a *child*. Without this
  # nothing in the repository ever wrote a non-`nil` `parent_run` outside the
  # suite: the depth ceiling bounded a tree that could not be built, and
  # `Evolution`'s independence walk — which exists precisely to catch a run
  # scoring a candidate its parent proposed — walked a chain of length one.
  # An independent review found the walk describing a path that did not exist.
  #
  # A process-global for something that is per-call, which is worth saying out
  # loud. `System.put_env/2` is the only channel that reaches a program started
  # by an adapter — the agent is a separate OS process and cannot read an
  # Elixir process dictionary — and dispatch inside one run is sequential:
  # `dispatch/2` and `attempt/3` are synchronous, and two *concurrent*
  # dispatches are two runs, each in its own worktree. The previous value is
  # restored rather than deleted so that a dispatch nested inside a dispatch
  # leaves the outer one's parent intact.
  defp as_parent(run_id, fun) do
    previous = System.get_env(@parent_env)
    System.put_env(@parent_env, run_id)

    try do
      fun.()
    after
      case previous do
        nil -> System.delete_env(@parent_env)
        value -> System.put_env(@parent_env, value)
      end
    end
  end

  defp fingerprint do
    case Git.tree_fingerprint() do
      {:ok, tree} -> tree
      :error -> nil
    end
  end

  # An agent that returned nothing is a failed attempt, not a step with a thin
  # summary. "It ran" and "it produced something" are different facts and this
  # is the place they must not be conflated.
  defp settle(plan, workspace, output, before, elapsed, opts) do
    if empty?(output) do
      fail(plan, ["the agent was called and returned nothing"], opts)

      {:refused,
       [%{rule: "no_output", why: "the agent returned nothing, so there is no work to fence"}]}
    else
      fence(plan, workspace, output, before, elapsed, opts)
    end
  end

  defp empty?(nil), do: true
  defp empty?(output) when is_binary(output), do: String.trim(output) == ""
  defp empty?(output) when is_map(output), do: map_size(output) == 0
  defp empty?(output) when is_list(output), do: output == []
  defp empty?(_), do: false

  # The one write this module makes, and it is one-directional: `failed`, never
  # `done`. `:record false` is for a caller driving `prepare/2` itself; it is
  # not a way to record a success, because there is no code path here that
  # records one.
  defp fail(plan, evidence, opts) do
    if Keyword.get(opts, :record, true) do
      Run.record(plan.run,
        step: plan.step,
        outcome: "failed",
        evidence: evidence,
        note: routing(evidence),
        agent: plan.role
      )
    end

    :ok
  end

  # `:none` is a designed answer, not a gap: routing an unclassified failure to
  # whichever role sounded closest is worse than admitting the class is
  # unknown. So it is written down as unknown rather than left out, because a
  # missing note reads as "nobody asked".
  defp routing(evidence) do
    case Conductor.classify(evidence) do
      {:ok, class} ->
        "#{class["id"]} → #{class["route"]}"

      :none ->
        "unclassified — no pattern in .agents/policies/failure.json matched this evidence, " <>
          "so it routes nowhere"
    end
  end

  # ---- refusals -------------------------------------------------------------

  defp ceiling_refusals(depth, remaining, spent) do
    []
    |> then(fn acc ->
      if spent.cost_known? and spent.cost_usd >= cost_ceiling() do
        [
          %{
            rule: "cost",
            why:
              "this dispatch tree has spent $#{:erlang.float_to_binary(spent.cost_usd, decimals: 2)} " <>
                "and the ceiling is $#{:erlang.float_to_binary(cost_ceiling() / 1, decimals: 2)} " <>
                "(.agents/policies/dispatch.json). The figure is what the adapters reported, " <>
                "not an estimate"
          }
          | acc
        ]
      else
        acc
      end
    end)
    |> then(fn acc ->
      if depth >= depth_ceiling() do
        [
          %{
            rule: "depth",
            why:
              "this dispatch would be #{depth + 1} deep and the ceiling is " <>
                "#{depth_ceiling()}. Depth is the axis on which a bounded thing becomes " <>
                "unbounded, and no per-step attempt count can see it"
          }
          | acc
        ]
      else
        acc
      end
    end)
    |> then(fn acc ->
      if remaining <= 0 do
        [
          %{
            rule: "wall_clock",
            why:
              "no wall-clock budget remains. A child inherits what is left of its " <>
                "parent's, never a fresh allowance"
          }
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp advice(run_id) do
    case Conductor.next(run_id) do
      {:ok, advice} -> {:ok, advice}
      {:error, message} -> {:error, message}
    end
  end

  defp conductor_refusals(%{state: state} = advice) when state in @halting do
    [
      %{
        rule: "conductor",
        why:
          "the conductor says this run is #{state}: #{advice.reason}. The dispatcher does " <>
            "not second-guess it and has no second copy of the reasoning"
      }
    ]
  end

  defp conductor_refusals(%{state: state}) when state in ~w(complete closed) do
    [%{rule: "conductor", why: "this run is #{state}; there is no step to dispatch"}]
  end

  defp conductor_refusals(%{refusals: [_ | _] = refusals}) do
    Enum.map(refusals, &%{rule: "conductor", why: to_string(&1)})
  end

  defp conductor_refusals(%{step: nil}) do
    [%{rule: "conductor", why: "the conductor named no step to take"}]
  end

  defp conductor_refusals(_advice), do: []

  # ---- the plan -------------------------------------------------------------

  defp plan(advice, parent, depth, remaining, spent) do
    step = advice.step

    with {:ok, agent, uncovered} <- staff(step),
         {:ok, run} <- Run.fetch(advice.run) do
      trust = Policy.derive_trust(Map.get(parent, :trust), agent["max_trust"], step["trust"])

      with :ok <- protected?(step["trust"], trust),
           :ok <- independent?(step, agent["id"], run),
           {:ok, agent_plan} <- agent_for(trust),
           {:ok, agent_plan} <- reviewer_model(step, agent_plan, run) do
        {:ok,
         %{
           run: advice.run,
           workflow: advice.workflow,
           lane: advice.lane,
           step: step["id"],
           role: agent["id"],
           uncovered: uncovered,
           trust: trust,
           depth: depth + 1,
           remaining_ms: remaining,
           spent_ms: spent.elapsed_ms,
           spent_usd: spent.cost_usd,
           # False as soon as one dispatch in the chain reported no price.
           # Carried into the plan rather than dropped, because "this tree has
           # spent $0.34" and "this tree has spent at least $0.34 and nobody
           # knows the rest" are different facts (§32).
           cost_known?: spent.cost_known?,
           adapter: agent_plan.id,
           adapter_module: agent_plan.module,
           model: agent_plan.model,
           restricted: agent_plan.restricted,
           # Whether this step is reviewing work a *different* model produced.
           # It is not a refusal — see `independent?/3` — but it is a fact a
           # promotion gate has to be able to read, so it is in
           # the plan rather than inferred later from a transcript.
           independent_model?: independent_model?(step, agent_plan.model, run),
           # The workflow path never narrows the fence. See `attempt/3`: a
           # dispatched step produces a diff somebody is asked to land, and
           # `.agents/policies/evaluators.json` is the answer to what may be in
           # one. A scoring attempt is the other case and says so there.
           task_paths: [],
           prompt: compose(agent["id"], advice, run, step, trust)
         }}
      end
    else
      {:refused, _} = refused -> refused
      {:error, message} -> {:refused, [%{rule: "run", why: message}]}
    end
  end

  # `.agents/constitution.md` §23 and an earlier change: "independent review" by the
  # thing under review is not review. Every workflow that has a review step
  # already declares `independent_of` on it — WF-003's `verify` is
  # `independent_of: ["patch"]` — and until now `Router.independence_constraints/1`
  # *reported* the constraint while its own moduledoc said "enforcing it is the
  # orchestrator's job". The dispatcher is the orchestrator, and nobody was
  # doing the job.
  #
  # The refusal is on the **role** here, and on the **model** in
  # `reviewer_model/3`. The model refusal was once judged unsatisfiable — "a
  # single-adapter setup has one model" — and that was wrong: one adapter runs
  # several models, and `claude_code` runs every one the subscription has.
  # What makes it satisfiable is the policy, not the adapter count.
  defp independent?(step, role, run) do
    conflicting =
      for other <- step["independent_of"] || [],
          entry <- steps_named(run, other),
          entry["agent"] == role,
          do: other

    case Enum.uniq(conflicting) do
      [] ->
        :ok

      others ->
        {:refused,
         [
           %{
             rule: "independence",
             why:
               "#{step["id"]} is declared `independent_of` #{Enum.join(others, ", ")}, and " <>
                 "#{role} already took #{Enum.join(others, ", ")} in this run. Review by the " <>
                 "thing under review is not review (constitution §23). Staff it with another " <>
                 "role, or record the step by hand with the reviewer named"
           }
         ]}
    end
  end

  # A review step — one declared `independent_of` another — is given
  # the first model in `models.json`'s `review.models` that the step under
  # review did not use, and is refused when every one of them was used.
  #
  # "Used" is read three ways, because a step reaches the ledger three ways:
  # the model a dispatch's plan named, the model its adapter reported, and —
  # for a step a session recorded by hand — the actor's name, which is the
  # model's id when `HARNESS_AGENT` is set the way this repository sets it.
  # The last is a claim nothing checked (`by_attested`), and it is used only to
  # *avoid* a model, never to admit one: a false match costs the review its
  # first choice, a missed one is the same-model review this exists to stop.
  #
  # Compared by `Adapter.model_family/1`, so an alias, a full id and a router's
  # prefixed id are one model, and two versions of a family are one model too.
  # The first choice is Opus and the second Sonnet: the author steps these
  # review are T1 and T2, which `by_trust` gives to Sonnet, so the stronger
  # model reviews; a step Opus wrote is reviewed by Sonnet rather than by
  # itself. The validator requires two families in the list, which is what
  # makes this refusal one that can always be satisfied.
  defp reviewer_model(step, agent_plan, run) do
    case step["independent_of"] || [] do
      [] ->
        {:ok, agent_plan}

      named ->
        used = families_used(named, run)

        candidates =
          Adapter.review_models()
          |> Enum.map(&Adapter.effective_model(agent_plan.module, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        case Enum.find(candidates, &(Adapter.model_family(&1) not in used)) do
          nil ->
            {:refused,
             [
               %{
                 rule: "independent_model",
                 why:
                   "#{step["id"]} reviews #{Enum.join(named, ", ")}, which used " <>
                     "#{used |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")}, and every " <>
                     "model review.models offers#{adapter_note(agent_plan)} is one of those. " <>
                     "A review by the model that wrote the work is not a review (constitution " <>
                     "§23). Record the review by hand with a different model named, or " <>
                     "run it on an adapter that runs a different model"
               }
             ]}

          model ->
            {:ok, %{agent_plan | model: model}}
        end
    end
  end

  defp adapter_note(%{id: id}) when id in ["pinned", nil], do: ""
  defp adapter_note(%{id: id}), do: " on #{id}"

  defp families_used(named, run) do
    dispatched =
      for dispatch <- run["dispatches"] || [],
          dispatch["step"] in named,
          model <- [dispatch["model"], dispatch["model_reported"]],
          do: model

    recorded =
      for entry <- run["steps"] || [],
          entry["step"] in named,
          name <- [get_in(entry, ["actor", "name"]), entry["by"]],
          do: name

    (dispatched ++ recorded)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new(&Adapter.model_family/1)
  end

  # Kept in the plan: a promotion gate reads it. With the choice
  # above it is true for every review step that was dispatched at all; it can
  # be false only for a step with no `independent_of`, where it means nothing
  # was reviewed.
  defp independent_model?(step, model, run) do
    case step["independent_of"] || [] do
      [] -> true
      named -> Adapter.model_family(model) not in families_used(named, run)
    end
  end

  defp steps_named(run, step_id),
    do: Enum.filter(run["steps"] || [], &(&1["step"] == step_id))

  # A stop is a statement by somebody who is not this run, and it
  # binds the whole chain: stopping a parent stops what it dispatches, or the
  # stop is a suggestion. Checked in `prepare/2` so that nothing runs, and
  # again in `dispatch/2` immediately before the adapter — a dispatch takes
  # minutes and the stop arrives during them, which is the entire point of
  # being stoppable from outside.
  defp stop_refusals(run_id) do
    if Run.stopped?(run_id) do
      [
        %{
          rule: "stopped",
          why:
            "this run, or one above it, has been stopped. `noetic-harness run --run #{run_id} " <>
              "--status` says by whom and why. A stopped run is not resumed: open a new one " <>
              "for the work that is left"
        }
      ]
    else
      []
    end
  end

  # §33, and the refusal most likely to be argued with: an adapter whose key or
  # binary is missing is `unavailable`, and the dispatch stops. It does **not**
  # quietly become a different adapter. Falling back turns "which model
  # produced this measurement?" into a guess, and an earlier change's promotion gate
  # is the thing that has to answer it.
  defp agent_for(trust) do
    case adapter() do
      nil ->
        case Adapter.resolve(trust) do
          {:ok, plan} ->
            {:ok, plan}

          {:unavailable, why} ->
            {:refused, [%{rule: "adapter", why: why}]}
        end

      module ->
        # A module pinned directly bypasses the policy, which is what a test
        # wants and what nothing else should do. It gets no model and no
        # restriction, because the policy is where those come from.
        {:ok,
         %{
           id: "pinned",
           module: module,
           model: Adapter.effective_model(module, nil),
           restricted: true
         }}
    end
  end

  # T4 and T5 are not dispatched, at any depth, including depth zero.
  #
  # `.agents/policies/trust_levels.json` says T4 requires "a separate reviewer
  # role that did not author the change" and T5 that "no agent may hold T5 by
  # role; it is granted per action or not at all". A dispatched agent is the
  # author, so it can satisfy neither by construction — and an earlier change names
  # this as the ceiling a parent must not be able to hand down.
  #
  # **Both trusts are checked, and the first version checked only the derived
  # one.** WF-016's `contain` step declares T4 and is staffed by
  # `release.ci_cd_engineer`, whose ceiling is T3 — so `derive_trust/3`
  # narrowed it to T3 and a protected step dispatched with no refusal at all.
  # The step's declaration is what says the *operation* is protected; the
  # derived trust only says what this particular role could hold while doing
  # it. A role too small for the step does not make the step smaller.
  defp protected?(declared, derived) do
    case Enum.find([declared, derived], &(&1 in ~w(T4 T5))) do
      nil ->
        :ok

      trust ->
        {:refused,
         [
           %{
             rule: "protected",
             why:
               "this step is #{trust}, which is not dispatched. " <>
                 ".agents/policies/trust_levels.json requires a reviewer who did not author " <>
                 "the change (T4) and per-action human authorisation (T5), and a dispatched " <>
                 "agent is the author. Take this step in a run a human started"
           }
         ]}
    end
  end

  # A workflow step is staffed by a *team*, and `Registry.supplying/2` wants one
  # role holding every capability at once. So a partial cover is the common case
  # and not the exception — `Conductor.who/1` says so in its own moduledoc, from
  # having got this wrong: WF-002's first step asks for `runtime.context` and
  # `architecture.domain` together and no single role has both. Refusing a
  # partial cover would refuse the commonest step there is, so a partial cover
  # dispatches and the plan carries what it does not cover.
  defp staff(step) do
    case Conductor.who(step) do
      {:ok, agent} ->
        {:ok, agent, []}

      {:partial, agent, uncovered} ->
        {:ok, agent, uncovered}

      :none ->
        {:refused,
         [
           %{
             rule: "role",
             why:
               "no role in the registry supplies any of " <>
                 "#{inspect(List.wrap(step["capabilities"]))}, so there is nobody to dispatch " <>
                 "this step to. `noetic-harness validate` is where that is a defect"
           }
         ]}
    end
  end

  # The *runtime* prompt, not the standing one: the same `Prompt.compose/2` a
  # human gets from `noetic-harness prompt`, given the workflow, the step, the task
  # and the context bundle. One code path, as a design decision requires of `conduct` —
  # two would drift, and the drift would be invisible because both would look
  # right.
  #
  # Passing the derived trust is safe rather than a second opinion:
  # `Prompt.compose/2` resolves `min(role.max_trust, given)`, and the derived
  # trust is already at or below the role's ceiling, so the min cannot raise it.
  defp compose(role_id, advice, run, step, trust) do
    task = %{id: run["bead"], title: run["title"], paths: []}

    bundle =
      case Context.build(task, capabilities: List.wrap(step["capabilities"])) do
        {:ok, assembled} -> assembled
        {:error, _} -> nil
      end

    Prompt.compose!(role_id,
      workflow: advice.workflow,
      step: step["id"],
      task: task,
      context: bundle,
      trust: trust,
      lane: advice.lane
    )
  end

  # ---- the fence ------------------------------------------------------------

  # §33: a fence that cannot see what changed refuses rather than assuming the
  # change was clean. "Could not determine" and "nothing to see" are different
  # facts and this is the place they must not be conflated.
  defp fence(plan, workspace, output, before, elapsed, opts) do
    case Workspace.changed_paths(workspace) do
      {:ok, paths} ->
        # The files the task named are not judged; everything else is,
        # including when the two arrive in the same diff. A solver that edits
        # the file it was asked to fix is doing the task; a solver that edits
        # `.agents/policies/evaluators.json` is not, and the second is still
        # refused when it comes with the first.
        case Fence.refuse(paths -- Map.get(plan, :task_paths, [])) do
          {:ok, []} ->
            landed(plan, workspace, output, before, elapsed, paths)

          {:refused, refusals} ->
            why = String.trim(Fence.explain(refusals)) <> "\n\n" <> kept(workspace)
            fail(plan, [why], opts)
            {:refused, [%{rule: "evaluator_fence", why: why, workspace: workspace}]}
        end

      {:error, message} ->
        why =
          "could not determine what this run changed (#{message}), so the fence refuses. " <>
            "A fence that cannot see is not a fence (§33)"

        fail(plan, [why], opts)
        {:refused, [%{rule: "evaluator_fence", why: why, workspace: workspace}]}
    end
  end

  # An exemption is a list of exact repository-relative paths, none of which is
  # a fenced path the policy has not marked `exemptible`.
  #
  # **Spelling.** A `*`, an empty string, a `./` prefix and a `..` segment are
  # each refused rather than normalised. The comparison downstream is
  # `paths -- task_paths` — exact string subtraction against what
  # `Workspace.changed_paths/1` emits — so a spelling git never emits exempts
  # nothing, and `Tree.confine/3`'s `keep` then matches nothing either, which
  # does not refuse: it reverts the solver's correct fix and scores `false` for
  # both arms. A wrong number is worse than a refusal, and that, rather than
  # any widening, is what these guards are for. An independent review removed
  # them and showed a glob exemption still refusing, correctly, for that
  # reason. `./` was previously normalised *here* and nowhere else, so
  # `confine` reported the task's own file as reverted while leaving it alone;
  # one rule, applied once, instead.
  #
  # **Reach.** `Fence.unexemptible/1`. The exemption exists so that an
  # environment about the harness's own modules can be scored; it may not
  # reach a path that says what passing *means* outside this worktree —
  # `.agents/**`, `.github/workflows/**`, `scripts/ci-local.sh`. That was
  # missing from the first version, and `Environments.derive/2` takes
  # everything a commit changed except prose, `.beads/` and `.agents/`, so a
  # real commit on this branch derives an environment whose source paths are
  # two CI workflow files.
  defp task_paths(opts) do
    paths = opts |> Keyword.get(:task_paths, []) |> List.wrap() |> Enum.map(&to_string/1)

    with [] <- Enum.filter(paths, &misspelt?/1) |> refuse_spelling(),
         [] <- Fence.unexemptible(paths) |> refuse_reach() do
      {:ok, paths}
    else
      refusals -> {:refused, refusals}
    end
  end

  defp misspelt?(path) do
    path == "" or String.contains?(path, "*") or String.starts_with?(path, "./") or
      ".." in Path.split(path) or String.starts_with?(path, "/")
  end

  defp refuse_spelling([]), do: []

  defp refuse_spelling(bad) do
    [
      %{
        rule: "task_paths",
        why:
          "#{Enum.join(bad, ", ")} is not how git spells a path in a diff, so it would exempt " <>
            "nothing and `Tree.confine/3` would revert the solver's own fix"
      }
    ]
  end

  defp refuse_reach([]), do: []

  defp refuse_reach(refused) do
    Enum.map(refused, fn %{path: path, why: why} ->
      %{
        rule: "task_paths",
        why:
          "#{path} is fenced and is not exemptible: #{why}. A scoring attempt may be exempted " <>
            "from the harness's own modules, and never from what says what passing means " <>
            "outside the worktree it was given (.agents/policies/evaluators.json)"
      }
    end)
  end

  defp landed(plan, workspace, output, before, elapsed, paths) do
    # The ledger learns what this cost, from what the adapter reported. Note
    # that this is the *only* write here that is not a failure — and it is not
    # an outcome: it records spend, never `done`. The asymmetry the whole
    # module rests on is untouched.
    # Two models, kept apart. `model` is the one the plan named — after the
    # adapter's own `runs_model/1` (jido's planner runs one local model at every
    # trust) — and is what `independent_model?` compares, because it is known
    # before the call. `model_reported` is what the adapter says ran, which for
    # `api` and `router` is the provider's full id rather than the alias. The
    # first version recorded only the reported one, and a review step's alias
    # never equalled an earlier step's full id: jido reviewing jido read as
    # independent.
    reported = usage_of(output, :model)

    Run.spend(plan.run,
      step: plan.step,
      adapter: plan.adapter,
      model: plan.model,
      model_reported: reported,
      elapsed_ms: elapsed,
      cost_usd: usage_of(output, :cost_usd),
      usage: usage_of(output, :usage)
    )

    {:ok,
     %{
       run: plan.run,
       step: plan.step,
       role: plan.role,
       trust: plan.trust,
       depth: plan.depth,
       elapsed_ms: elapsed,
       remaining_ms: max(plan.remaining_ms - elapsed, 0),
       spent_ms: plan.spent_ms + elapsed,
       cost_known?: plan.cost_known? and not is_nil(usage_of(output, :cost_usd)),
       tree_before: before,
       tree_after: fingerprint(),
       adapter: plan.adapter,
       model: plan.model,
       model_reported: reported,
       cost_usd: usage_of(output, :cost_usd),
       usage: usage_of(output, :usage),
       workspace: workspace,
       paths: paths,
       diff: diff(workspace),
       output: output
     }}
  end

  # An adapter that can tell what it cost says so; one that cannot returns nil
  # rather than a zero, because "free" and "not measured" are different facts
  # and a telemetry sum over them would be a lie.
  defp usage_of(output, key) when is_map(output), do: Map.get(output, key)
  defp usage_of(_output, _key), do: nil

  defp diff(workspace) do
    case Workspace.diff(workspace) do
      {:ok, patch} -> patch
      {:error, message} -> message
    end
  end

  # The refusal path leaves the evidence. A rejected run is
  # diagnosable or the rejection taught nobody anything, so the refusal says
  # where the tree still is rather than quietly removing it.
  defp kept(workspace) do
    "The work is not discarded. It is on branch #{workspace.branch} at " <>
      "#{workspace.path}; read the diff there, and remove it with " <>
      "`Workspace.close/2` once you have."
  end

  defmodule NullAdapter do
    @moduledoc """
    The adapter that runs nothing.

    It is the default deliberately. A harness whose test suite spends money on
    a model call is a harness whose test suite nobody runs, and a default that
    dispatches for real is one misconfiguration away from doing so in CI.

    It returns the prompt it was handed, so a caller can assert on what would
    have been sent — which is the property worth testing about composition.
    """
    @behaviour Noetic.Harness.Adapter

    @impl true
    def available?, do: :ok

    @impl true
    def call(prompt, opts) do
      {:ok, %{dispatched: false, prompt: prompt, opts: Keyword.delete(opts, :parent)}}
    end
  end
end
