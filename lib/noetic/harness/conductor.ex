defmodule Noetic.Harness.Conductor do
  @moduledoc """
  What happens next in a run, and what will not be advised.

  This is an earlier change's executor, and a design decision is why it is called a conductor
  instead. "Executor" names two things: **dispatch** — compose a role's prompt,
  call a model, take the result as the step's output — and **control** — which
  step is next, whether its budget is spent, whether the last attempt was a
  retry or a stall, where this failure routes, which artifact the step owes.

  Everything the bead enumerates is control. None of it is dispatch. So this
  module does all of the first and none of the second: it never calls an agent,
  and the agent performing the work is whoever is reading its output.

  That distinction is what makes the bead's warning survivable. "A half-built
  executor is worse than none because it looks like it ran the workflow" is true
  of a dispatcher and cannot be true of this, which visibly does nothing except
  say what is next and refuse things.

  ## It advises, and it refuses. Only the refusals are load-bearing.

  An agent that follows bad advice has still done the work; an agent that is
  refused has to argue with a rule. So every refusal names the rule and the file
  the rule lives in, and `next/1` returns them separately from the suggestion.

  ## The four obligations

    * **Retry budget.** `retry_budget` sits on every workflow and nothing read
      it. Non-`done` attempts at a step are counted against it, and on
      exhaustion the conductor refuses another attempt and names the workflow's
      own escalation — for WF-002, "the same step fails three times → WF-020".

    * **Stall, which is not a retry.** `.agents/policies/failure.md`: "an attempt
      only counts as an attempt if it changed something. Re-running an identical
      command against an unchanged tree is not a retry, it is a stall, and the
      workflow terminates on detecting one." Two consecutive attempts at one
      step over an identical tree fingerprint with identical evidence is a
      stall. A missing fingerprint — an entry written before `Run` recorded one,
      or a tree git could not read — is **unknown**, never equal.

    * **Loop.** A stall is one step repeating with nothing changing; a loop is a
      *cycle* of steps repeating. `implement → test → implement → test → …` is
      progress the first time and a symptom the fourth, and neither the per-step
      budget nor the stall check can see it, because each attempt changes the
      tree and no single step exceeds its budget.

    * **Artifacts.** Where a step's declared `outputs` name a kind in
      `Artifact.kinds/0`, an envelope is owed, and advancing past a step that
      owes one and attached nothing is refused. Where they name prose — "beads
      filed", "contract list" — they stay descriptive: inventing an envelope
      kind to make the rule uniform is how a rule stops being believed.

  ## Failure routing

  `.agents/policies/failure.json` is the dispatchable form of the policy's
  table; the Markdown is the explanation, and `noetic-harness validate` asserts the
  two agree. A failure's evidence is matched against each class's pattern, and
  the first match names where it goes. An unmatched failure routes nowhere and
  says so, which is better than routing it somewhere plausible.
  """

  alias Noetic.Harness.{Artifact, Loader, Registry, Run, Workflow}

  @states ~w(running complete blocked stalled exhausted looping closed)

  # How many times a cycle must repeat before it is a loop. Deliberately **not**
  # the retry budget, which is a different quantity that happened to share a
  # name: at `retry_budget: 1` — WF-015 Release and WF-016 Incident — `budget`
  # repetitions of a cycle is one, so every pair of distinct consecutive steps
  # was a loop and a healthy release halted on its second entry. At 2 it called
  # `implement → test → implement → test` a loop, which is one failed test and
  # one fix.
  @loop_repeats 3

  @type advice :: map()

  @doc "The states a run can be conducted into."
  @spec states() :: [String.t()]
  def states, do: @states

  # ---- the failure policy --------------------------------------------------

  @doc "The failure policy, as data."
  @spec policy() :: {:ok, map()} | {:error, String.t()}
  def policy do
    Loader.cached_load(Path.join(Noetic.Harness.agents_path("policies"), "failure.json"))
  end

  @doc """
  Which failure class this evidence looks like.

  Returns `{:ok, class}` or `:none`. `:none` is a real answer: a failure whose
  class cannot be established routes nowhere, and saying so beats routing it to
  whichever role sounded closest.

  **First match wins, in the order `failure.json` lists them**, which is the
  order of the table in `failure.md`. Evidence often matches two classes — a
  test run that failed to compile is both — and the order is the policy's
  judgement about which reading to act on.
  """
  @spec classify([String.t()] | String.t()) :: {:ok, map()} | :none
  def classify(evidence) do
    text = evidence |> List.wrap() |> Enum.join("\n")

    with {:ok, policy} <- policy(),
         classes when is_list(classes) <- policy["classes"] do
      classes
      |> Enum.filter(& &1["match"])
      |> Enum.find(fn class ->
        case Regex.compile(class["match"], "i") do
          {:ok, regex} -> Regex.match?(regex, text)
          {:error, _} -> false
        end
      end)
      |> case do
        nil -> :none
        class -> {:ok, class}
      end
    else
      _ -> :none
    end
  end

  # ---- counting ------------------------------------------------------------

  @doc "Every entry for a step, oldest first."
  @spec attempts(map(), String.t()) :: [map()]
  def attempts(run, step_id) do
    run["steps"] |> List.wrap() |> Enum.filter(&(&1["step"] == step_id))
  end

  @doc """
  Attempts that count against the budget: every entry for the step that is not
  `done`.

  A stall is not excluded, and does not need to be: a stall terminates the run
  rather than costing it one of three tries, so nothing ever reads the count
  afterwards.

  Failures *before* a later `done` keep counting, which is a policy choice and
  not an oversight: a step sent back by review has already cost the run those
  attempts, and forgiving them is how a budget stops bounding anything.
  """
  @spec spent(map(), String.t()) :: non_neg_integer()
  def spent(run, step_id) do
    run |> attempts(step_id) |> Enum.count(&(&1["outcome"] != "done"))
  end

  @doc "The workflow's retry budget, falling back to the policy default."
  @spec budget(map()) :: pos_integer()
  def budget(workflow) do
    case workflow["retry_budget"] do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        case policy() do
          {:ok, %{"retry_budget_default" => n}} when is_integer(n) -> n
          _ -> 3
        end
    end
  end

  # ---- stalls and loops ----------------------------------------------------

  @doc """
  Is the most recent attempt at this step a stall?

  `{:stalled, reason}` when the last two entries for the step have the same tree
  fingerprint *and* the same evidence. `:no` otherwise, including when either
  fingerprint is missing: a run recorded before fingerprints existed must not
  read as a tree that never changed.
  """
  @spec stalled(map(), String.t()) :: {:stalled, String.t()} | :no
  def stalled(run, step_id) do
    case run |> attempts(step_id) |> Enum.reverse() |> Enum.take(2) do
      [latest, previous] -> compare_attempts(step_id, latest, previous)
      _ -> :no
    end
  end

  defp compare_attempts(step_id, latest, previous) do
    cond do
      is_nil(latest["tree"]) or is_nil(previous["tree"]) ->
        :no

      latest["tree"] != previous["tree"] ->
        :no

      latest["evidence"] != previous["evidence"] ->
        :no

      true ->
        {:stalled,
         "#{step_id} was attempted twice over an identical tree (#{latest["tree"]}) with " <>
           "identical evidence. `.agents/policies/failure.md` calls that a stall rather than a " <>
           "retry, and the workflow terminates on one: re-running the same command against an " <>
           "unchanged tree cannot produce a different answer."}
    end
  end

  @doc """
  Is the run going round in a cycle?

  A stall is one step repeating with nothing changing. A loop is a *sequence*
  repeating — `implement → test → implement → test` — where every attempt does
  change the tree and no single step exceeds its budget, so neither of the other
  two checks can see it.

  Reports the shortest cycle repeated `#{@loop_repeats}` times. Detection needs
  the run's tail to be **exactly** periodic: one out-of-band entry — a `context`
  re-read, a `document` touch — hides the cycle until it scrolls out of the
  window. That is the conservative direction, and it is a real limit rather than
  a tuning parameter.
  """
  @spec looping(map()) :: {:looping, String.t()} | :no
  def looping(run) do
    sequence = run["steps"] |> List.wrap() |> Enum.map(& &1["step"])

    2..max(div(length(sequence), @loop_repeats), 2)//1
    |> Enum.find_value(:no, fn size -> cycle_at(sequence, size) end)
  end

  defp cycle_at(sequence, size) do
    needed = size * @loop_repeats
    tail = Enum.take(sequence, -needed)

    with true <- length(tail) == needed,
         cycle = Enum.take(tail, size),
         true <- tail == List.flatten(List.duplicate(cycle, @loop_repeats)),
         true <- Enum.uniq(cycle) == cycle do
      {:looping,
       "#{Enum.join(cycle, " → ")} has repeated #{@loop_repeats} times with no step reaching " <>
         "its own budget. Every attempt changed something, so this is not a stall; the cycle is " <>
         "the symptom. `.agents/policies/failure.md` routes a workflow that keeps failing the " <>
         "same way to WF-020 — the workflow is the defect."}
    else
      _ -> nil
    end
  end

  # ---- artifacts -----------------------------------------------------------

  @doc """
  Artifact kinds a step declared and did not attach.

  Only outputs naming a kind in `Artifact.kinds/0` count. The rest of a step's
  `outputs` are prose describing what it produced, and treating "beads filed" as
  a missing envelope would make the rule unbelievable within a day.

  An attachment settles a debt only if an artifact **with that id exists on
  disk and carries that kind**. The first version compared the id against the
  kind name as a substring, so `"notes-about-the-codepatch"` settled a
  `CodePatch` — a refusal that cites the constitution on provenance while
  accepting a string as proof that provenance exists.
  """
  @spec owed(map(), map()) :: [String.t()]
  def owed(step, entry) do
    kinds = MapSet.new(Artifact.kinds())
    attached = attached_kinds(entry)

    step
    |> Map.get("outputs")
    |> List.wrap()
    |> Enum.filter(&MapSet.member?(kinds, &1))
    |> Enum.reject(&MapSet.member?(attached, &1))
  end

  defp attached_kinds(entry) do
    wanted =
      entry |> Map.get("artifacts") |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()

    Artifact.list()
    |> Enum.filter(&MapSet.member?(wanted, &1["id"]))
    |> MapSet.new(& &1["kind"])
  end

  @doc """
  Every artifact debt in the run, not only the newest step's.

  The first version checked `owed/2` against the most recent entry alone, which
  made the refusal "you may not record the next step *right now*" — satisfied by
  recording the next step anyway. Two steps of the run that built this feature
  were in exactly that state.
  """
  @spec debts(map(), map()) :: [{String.t(), [String.t()]}]
  def debts(run, workflow) do
    run
    |> latest_by_step()
    |> Enum.filter(fn {_id, entry} -> entry["outcome"] == "done" end)
    |> Enum.flat_map(fn {id, entry} ->
      case step_def(workflow, id) do
        nil ->
          []

        step ->
          case owed(step, entry) do
            [] -> []
            kinds -> [{id, kinds}]
          end
      end
    end)
    |> Enum.sort()
  end

  # ---- the advice ----------------------------------------------------------

  @doc """
  What to do next in this run.

  Returns `{:ok, advice}` where `advice` carries the run's `state`, the `step`
  to attempt (or `nil`), the `refusals` that stand in the way, the budget
  position, where the last failure routes, and what the last step still owes.

  The suggestion is a suggestion. The refusals are the product.
  """
  @spec next(String.t()) :: {:ok, advice()} | {:error, String.t()}
  def next(run_id) do
    with {:ok, run} <- Run.fetch(run_id),
         {:ok, workflow} <- fetch_workflow(run["workflow"]) do
      {:ok, advise(run, workflow)}
    end
  end

  # `Workflow.fetch/1` answers a bare `:error`, which would escape `next/1`'s
  # own spec and reach the Mix task's `case` as an unmatched clause — a stack
  # trace out of the one tool whose whole job is to say no legibly.
  defp fetch_workflow(id) do
    case Workflow.fetch(id) do
      {:ok, workflow} ->
        {:ok, workflow}

      :error ->
        {:error,
         "this run names workflow #{inspect(id)}, which `.agents/workflows/` does not define. " <>
           "Either it was renamed or a definition file is malformed — `noetic-harness validate`."}
    end
  end

  defp advise(run, workflow) do
    budget = budget(workflow)
    last = run["steps"] |> List.wrap() |> List.last()

    base = %{
      run: run["id"],
      workflow: workflow["id"],
      lane: run["lane"],
      budget: budget,
      state: "running",
      step: nil,
      reason: nil,
      refusals: [],
      routing: nil,
      owed: []
    }

    cond do
      run["status"] != "open" ->
        %{
          base
          | state: "closed",
            reason: "this run is #{run["status"] || "in no recorded status"}; nothing follows it"
        }

      is_nil(last) ->
        first_outstanding(base, run, workflow, "nothing has been recorded yet")

      true ->
        base
        |> from_last(run, workflow, last, budget)
        |> with_loop(run)
        |> with_debts(run, workflow)
    end
  end

  # Every outstanding artifact debt, on every piece of advice — not only when
  # the run completes. A debt that is mentioned once and then goes quiet is a
  # prompt, not an obligation.
  defp with_debts(%{state: "complete"} = advice, _run, _workflow), do: advice

  defp with_debts(advice, run, workflow) do
    # Not the step the advice is already about: `from_last/6` has said that one
    # in full, with the rule it comes from, and repeating it here reads as two
    # separate refusals.
    current = advice.step && advice.step["id"]

    run
    |> debts(workflow)
    |> Enum.reject(fn {step, _kinds} -> step == current end)
    |> case do
      [] ->
        advice

      debts ->
        owed = debts |> Enum.flat_map(fn {_step, kinds} -> kinds end) |> Enum.uniq()

        %{
          advice
          | owed: Enum.uniq(advice.owed ++ owed),
            refusals:
              advice.refusals ++
                [
                  "Still owed from earlier: " <>
                    Enum.map_join(debts, "; ", fn {step, kinds} ->
                      "#{step}: #{Enum.join(kinds, ", ")}"
                    end) <> ". Record those steps again with `--artifact`."
                ]
        }
    end
  end

  defp from_last(base, run, workflow, last, budget) do
    case step_def(workflow, last["step"]) do
      nil -> orphan(base, workflow, last)
      step -> from_last(base, run, workflow, last, step, budget)
    end
  end

  # A ledger outlives the workflow it names. Renaming a step leaves runs whose
  # entries point at nothing, and the first version handed that `nil` to
  # `Map.get/3` and raised.
  defp orphan(base, workflow, last) do
    %{
      base
      | state: "blocked",
        reason:
          "this run's last entry is #{inspect(last["step"])}, which #{workflow["id"]} no longer " <>
            "declares. A run ledger outlives the workflow it names; nothing here can say what " <>
            "follows a step that does not exist."
    }
  end

  defp from_last(base, run, workflow, last, step, budget) do
    case last["outcome"] do
      "done" ->
        case owed(step, last) do
          [] ->
            first_outstanding(base, run, workflow, "#{last["step"]} is done")

          kinds ->
            %{
              base
              | step: step,
                owed: kinds,
                reason: "#{last["step"]} declared an artifact it did not attach",
                refusals: [
                  "#{last["step"]} declares #{Enum.join(kinds, ", ")} in its `outputs` and the " <>
                    "entry attached none. Write the envelope and record the step again with " <>
                    "`--artifact`; an artifact with no provenance cannot be evaluated, only " <>
                    "believed (`.agents/constitution.md` §6)."
                ]
            }
        end

      "blocked" ->
        %{
          base
          | state: "blocked",
            reason: "#{last["step"]} is blocked",
            routing: terminal_routing("blocked"),
            refusals: [
              "A blocked step does not get worked around. File the blocker as a bead with a " <>
                "`discovered-from` link, escalate to the holder, and stop " <>
                "(`.agents/policies/failure.md`, terminal states)."
            ]
        }

      outcome ->
        failed(base, run, workflow, last, step, outcome, budget)
    end
  end

  defp failed(base, run, workflow, last, step, outcome, budget) do
    spent = spent(run, last["step"])
    routing = failure_routing(last, outcome)

    case stalled(run, last["step"]) do
      {:stalled, reason} ->
        %{
          base
          | state: "stalled",
            step: step,
            reason: reason,
            routing: routing,
            refusals: [
              "The workflow terminates on a stall. Change something — the diagnosis, the " <>
                "command, the hypothesis — or record the run `--abandon`ed with what was learned."
            ]
        }

      :no when spent >= budget ->
        %{
          base
          | state: "exhausted",
            step: step,
            reason:
              "#{last["step"]} has spent #{spent} of #{budget} attempts, all non-done. " <>
                escalation(workflow),
            routing: routing,
            refusals: [
              "No further attempt at #{last["step"]} is advised. On exhaustion the workflow emits " <>
                "a FAILED artifact containing every attempt, its diagnosis and its evidence, " <>
                "files a bead, and stops (`.agents/policies/failure.md`, retry budget). The " <>
                "evidence is not reverted along with the code."
            ]
        }

      :no ->
        %{
          base
          | step: step,
            reason:
              "#{last["step"]} is #{outcome}; attempt #{spent + 1} of #{budget}" <>
                retry_caveat(outcome),
            routing: routing
        }
    end
  end

  defp retry_caveat("uncertain"),
    do: ". `uncertain` is not a soft `done` — route to something that could settle it"

  defp retry_caveat("needs_review"), do: ". It needs a reviewer who did not author the work"
  defp retry_caveat(_), do: ""

  defp with_loop(%{state: "running"} = advice, run) do
    case looping(run) do
      {:looping, reason} ->
        %{
          advice
          | state: "looping",
            reason: reason,
            refusals: advice.refusals ++ ["Take the cycle to WF-020 rather than round again."]
        }

      :no ->
        advice
    end
  end

  defp with_loop(advice, _run), do: advice

  defp first_outstanding(base, run, workflow, because) do
    done = run |> latest_by_step() |> Enum.filter(fn {_id, e} -> e["outcome"] == "done" end)
    done_ids = MapSet.new(done, fn {id, _} -> id end)
    recorded = MapSet.new(List.wrap(run["steps"]), & &1["step"])

    remaining = Enum.reject(workflow["steps"], &MapSet.member?(done_ids, &1["id"]))

    # A step counts towards completion only if it is optional *and untouched*.
    # An optional step recorded `failed` is something `Run.finish/2` refuses on,
    # and the conductor saying "complete" over it would put the two into
    # disagreement about what finishing means — of which the one that refuses to
    # close runs is the one to agree with.
    blocking =
      Enum.reject(remaining, fn step ->
        step["optional"] && not MapSet.member?(recorded, step["id"])
      end)

    case {List.first(remaining), blocking} do
      {nil, _} ->
        complete(base, run, workflow, [])

      {_first, []} ->
        complete(base, run, workflow, remaining)

      {step, _} ->
        %{base | step: step, reason: "#{because}; #{step["id"]} is next" <> optional_note(step)}
    end
  end

  defp complete(base, run, workflow, untouched_optional) do
    tail =
      case untouched_optional do
        [] ->
          ""

        steps ->
          " " <>
            Enum.map_join(steps, "; ", & &1["id"]) <>
            " was never recorded either way, which is allowed and is worth a note in the run " <>
            "rather than a silence."
      end

    reason =
      "every required step is done — `noetic-harness run --finish` runs the lane and closes it." <>
        tail

    case debts(run, workflow) do
      [] ->
        %{base | state: "complete", reason: reason}

      debts ->
        %{
          base
          | state: "complete",
            reason: reason,
            owed: debts |> Enum.flat_map(fn {_step, kinds} -> kinds end) |> Enum.uniq(),
            refusals: [
              "The run owes " <>
                Enum.map_join(debts, "; ", fn {step, kinds} ->
                  "#{step}: #{Enum.join(kinds, ", ")}"
                end) <>
                ". Each of those steps declares the kind in its `outputs` and attached no " <>
                "envelope with that id and kind. A debt that stops being mentioned once the " <>
                "next step is recorded is not an obligation, so it is mentioned here too."
            ]
        }
    end
  end

  defp optional_note(%{"optional" => true} = step) do
    ", and it is optional: it applies when #{step["applies_when"] || "the workflow says so"}. " <>
      "Record it or record why not — the conductor will not decide that for you"
  end

  defp optional_note(_), do: ""

  defp latest_by_step(run) do
    run["steps"]
    |> List.wrap()
    |> Enum.reduce(%{}, fn entry, acc -> Map.put(acc, entry["step"], entry) end)
  end

  defp step_def(workflow, step_id) do
    Enum.find(workflow["steps"], &(&1["id"] == step_id))
  end

  # By a typed key, never by the prose. Looking `when` up as a literal string
  # found WF-002 and missed the other nineteen, including WF-003, whose
  # equivalent is worded "reproduction fails after three attempts" — and would
  # have matched a workflow's "the budget cannot be met", which is a
  # performance budget and not a retry budget at all.
  defp escalation(workflow) do
    workflow
    |> Map.get("escalations")
    |> List.wrap()
    |> Enum.find(&(&1["on"] == "retry_budget_exhausted"))
    |> case do
      nil ->
        "#{workflow["id"]} declares no escalation for an exhausted budget, so this is a stop " <>
          "rather than a handover."

      %{"to" => to} ->
        "#{workflow["id"]} escalates an exhausted budget to #{to}."
    end
  end

  defp failure_routing(entry, outcome) do
    declared = terminal_routing(outcome)

    case classify(entry["evidence"]) do
      {:ok, class} ->
        Map.merge(declared, %{
          "class" => class["id"],
          "observed" => class["observed"],
          "route" => class["route"],
          "then" => class["then"],
          "stop" => class["stop"],
          "why" => class["why"]
        })

      :none ->
        Map.put(
          declared,
          "class",
          "unclassified — no pattern in failure.json matched this evidence, so it routes nowhere"
        )
    end
  end

  defp terminal_routing(outcome) do
    case policy() do
      {:ok, policy} -> get_in(policy, ["terminal_states", outcome]) || %{}
      _ -> %{}
    end
  end

  @doc """
  A role for this step, from the step's own capabilities.

  `Noetic.Harness.Registry.supplying/2` wants one agent holding *every*
  capability, and a workflow step is staffed by a team — WF-002's `context`
  asks for `architecture.domain` and `runtime.context` together and no single
  role in the registry has both. The first version reported "nothing in the
  registry supplies these capabilities" for the commonest invocation there is,
  and called it a registry defect. It is not: it is what
  `Noetic.Harness.Registry.partially_supplying/2` exists for, so a partial
  cover is reported as partial.

  Advice, not assignment. `noetic-harness route` composes the whole team, and the
  candidates here are unranked — the first the registry lists, not the best.
  """
  @spec who(map()) :: {:ok, map()} | {:partial, map(), [String.t()]} | :none
  def who(step) do
    wanted = List.wrap(step["capabilities"])

    with {:ok, registry} <- Registry.load() do
      case Registry.supplying(registry, wanted) do
        [agent | _] ->
          {:ok, agent}

        [] ->
          # `partially_supplying/2` answers `{agent, covered_count}` tuples,
          # already sorted by how much each covers.
          case Registry.partially_supplying(registry, wanted) do
            [{agent, _covered} | _] ->
              {:partial, agent, wanted -- List.wrap(agent["capabilities"])}

            [] ->
              :none
          end
      end
    else
      _ -> :none
    end
  end
end
