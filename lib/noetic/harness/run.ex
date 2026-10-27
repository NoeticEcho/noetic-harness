defmodule Noetic.Harness.Run do
  @moduledoc """
  A ledger of what an agent did against a workflow. **Not an executor.**

  ## The distinction, because everything here depends on it

  This module never runs a step, never calls an agent and never decides what
  happens next. It records what an agent says it did, checks that claim against
  the workflow's own definition, and **refuses to call a run finished** until
  every required step carries evidence and the gate lane has actually passed.

  That refusal is the whole value. An executor that drove the steps would be a
  larger thing and a worse one to build first: an earlier change says it, and the
  reason is that a half-built executor looks like it ran the workflow. A ledger
  cannot look like that, because it visibly does nothing except say no.

  What it replaces is an agent's own memory of its own diligence, which is the
  least reliable instrument in the system. "I ran the tests" is a sentence; a
  run whose `verify` step has no evidence entry is a fact.

  ## The three refusals

    * **A step cannot be recorded `done` with no evidence.** Evidence is a
      command and its result, in the artifact envelope's sense — "tests pass" is
      not an entry, `mix test` and its output are.
    * **A run cannot finish with a required step unrecorded.** Optional steps
      (`"optional": true` in the workflow) may be skipped; the rest may not, and
      the refusal names them.
    * **A run cannot finish on a lane this module did not watch pass.**
      `finish/2` runs the lane itself through `Noetic.Harness.Gates` rather than
      accepting a report, and stores the result. A `partial` lane — one with a
      gate that could not run — does not finish a run unless the caller
      acknowledges it explicitly with a written reason, and that acknowledgement
      is stored, so "the scanner was not installed" survives into the record
      instead of evaporating into a green tick.

  ## Terminal states

  The five from the constitution: `done`, `failed`, `blocked`, `uncertain`,
  `needs_review`. Only `done` counts towards completion. `uncertain` is not a
  soft `done`, and the ledger is where that stops being a matter of tone.

  Runs live in `.agents/runs/<id>.json` and are append-only in spirit: a step
  recorded twice keeps both entries, newest last, because how many attempts a
  step took is the most interesting number in the file.

  The lane is the same. Every `finish/2` that ran it appends to
  `finish_attempts` — a failed or partial attempt included, though the run
  still refuses to close — because how many finishes a run took is rework,
  and until an earlier change a refused finish wrote nothing and the ledger held only
  the attempt that passed.
  """

  alias Noetic.Harness.{Gates, Git, Identity, Loader, Owner, Workflow}
  alias Noetic.Harness.Identity.Signature
  alias Noetic.Harness.Redact

  @outcomes ~w(done failed blocked uncertain needs_review)
  @dir "runs"

  # A run opened while the test suite is running is not a run anybody is
  # working in, and `current/0` must not offer it to a session that asks "which
  # run am I in". Captured at compile time: the test build is the only build
  # where this is true, and a mix task runs from the dev build. It is a default
  # rather than a rule — `ephemeral: false` is available for a test that is
  # testing the non-ephemeral path, and `ephemeral: true` for a script that
  # wants the same protection outside the suite.
  @ephemeral_by_default Mix.env() == :test

  # A parent chain longer than this is a cycle or a mistake, and either way the
  # walk stops rather than looping. It is well above the depth ceiling on
  # purpose: the walk must be able to *see* a chain that is over the ceiling in
  # order to refuse it.
  @max_chain 50

  # The one channel that reaches a program an adapter started. See
  # `Noetic.Harness.Dispatcher.as_parent/2`, which is the only writer.
  @parent_env "NOETIC_HARNESS_PARENT_RUN"

  @type t :: map()

  @doc "The terminal states a step may be recorded in."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  # ---- lifecycle -----------------------------------------------------------

  @doc """
  Open a run against a workflow.

  Options: `:workflow` (required), `:title` (required), `:bead`, `:agent`,
  `:lane` (defaults to the workflow's `default_lane`), `:ephemeral`,
  `:parent_run`.

  **`:parent_run` is the run that caused this one**, and it has to be a run
  that exists. It falls back to `NOETIC_HARNESS_PARENT_RUN`, which is how a
  dispatched process inherits it without every adapter having to pass it
  along: `Dispatcher` exports it around the call, so a run opened by an agent
  it invoked is a *child* rather than a sibling. Before that there was no way
  to write a non-`nil` parent at all outside the suite — which made the
  independence walk in `Evolution` a walk over a chain nothing could build,
  and the one path that was available, `noetic-harness run --start`, produced a
  sibling that no check refused.

  An **ephemeral** run is one nobody is working in: `current/0` never returns
  it. The suite opens runs constantly — `dispatcher_test`, `conductor_test` and
  `run_test` all call this — and each one used to become the newest open run
  for every other process sharing the worktree. A `--step` recorded in that
  window was written into a test's run and deleted with it by `on_exit`, while
  the command printed `recorded implement: done`. That happened, and cost four
  steps' evidence. It defaults to true in the test environment
  for that reason.
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, String.t()}
  def start(opts) do
    with {:ok, workflow} <- fetch_workflow(opts[:workflow]),
         {:ok, title} <- require_opt(opts, :title, "a run needs a title: what is being done"),
         {:ok, parent_run} <- parent_for(opts) do
      lane = opts[:lane] || workflow["default_lane"]
      id = build_id(workflow["id"], opts[:bead], title)
      ephemeral = Keyword.get(opts, :ephemeral, @ephemeral_by_default)

      run = %{
        "id" => id,
        "workflow" => workflow["id"],
        "workflow_name" => workflow["name"],
        "title" => title,
        "bead" => opts[:bead],
        "agent" => opts[:agent],
        "lane" => lane,
        "status" => "open",
        "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
        # The commit this run started from, so that `finish/2` can ask what
        # the run changed rather than what happens to be uncommitted. `nil`
        # where git could not answer, and then `finish/2` says so.
        "base" => head_sha(),
        "finished_at" => nil,
        "steps" => [],
        "gates" => nil,
        "acknowledged" => nil,
        "ephemeral" => ephemeral,
        # The run that dispatched this one, or nil. Depth is walked from this
        # rather than passed in: `Dispatcher.prepare/2` used to read the depth
        # out of its own `parent` argument, so a caller that said nothing was
        # believed to be at depth 0. A ceiling checked against a
        # number the bounded thing supplies is not a ceiling.
        "parent_run" => parent_run,
        # What this run has actually spent, appended to by `spend/2` from what
        # an adapter reported. Never from an estimate.
        "dispatches" => []
      }

      # An ephemeral run is litter-to-be, and the broom must know whose
      # (`Noetic.Harness.Owner`). A real run is somebody's work and is
      # never swept, so it carries no owner.
      run = if ephemeral, do: Map.put(run, "owner_vm", Owner.current()), else: run

      with :ok <- write_new(run), do: {:ok, run}
    end
  end

  @doc """
  Record a step.

  Options: `:step` (required, a step id in the workflow), `:outcome` (required,
  one of `outcomes/0`), `:evidence` (required for `done`, a list), `:artifacts`,
  `:note`, `:agent`.
  """
  @spec record(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def record(run_id, opts) do
    with {:ok, run} <- fetch(run_id),
         {:ok, workflow} <- fetch_workflow(run["workflow"]),
         {:ok, step_id} <- require_opt(opts, :step, "which step?"),
         :ok <- known_step(workflow, step_id),
         {:ok, outcome} <- validate_outcome(opts[:outcome]),
         {:ok, evidence} <- validate_evidence(outcome, opts[:evidence]) do
      entry = %{
        "step" => step_id,
        "outcome" => outcome,
        # An agent's evidence quotes the command it just ran, which is the text
        # most likely to carry a home path or a token, and this file is
        # committed. Scrubbed here, before it is signed.
        "evidence" => Enum.map(evidence, &scrub/1),
        "artifacts" => List.wrap(opts[:artifacts]),
        "note" => scrub(opts[:note]),
        "agent" => opts[:agent] || run["agent"],
        # Who claims this step, and whether anything stands behind the claim:
        # `self-asserted` until `Identity.sign/4` below signs it.
        "actor" => Identity.actor(by: opts[:agent] || run["agent"]),
        "at" => DateTime.to_iso8601(DateTime.utc_now()),
        # What the tree looked like when this was claimed. The ledger records
        # facts about the product at record time, and this is the one fact that
        # separates a retry from a stall — see `Noetic.Harness.Conductor`. `nil`
        # where git could not answer, which the stall check reads as unknown
        # rather than as unchanged.
        "tree" => tree_fingerprint()
      }

      # Signed last, over everything above it and over where it goes: its
      # position and the record before it.
      entry = Identity.sign(entry, "run_step", run_id, position(run["steps"]))

      run = Map.update!(run, "steps", &(&1 ++ [entry]))
      with :ok <- write(run), do: {:ok, run}
    end
  end

  @doc """
  What a run still owes: unrecorded required steps, steps whose last outcome is
  not `done`, and the lane it has not passed.

  Returns `{:ok, %{outstanding: [...], attention: [...], lane: ..., attempts: n}}`.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, String.t()}
  def status(run_id) do
    with {:ok, run} <- fetch(run_id),
         {:ok, workflow} <- fetch_workflow(run["workflow"]) do
      latest = latest_by_step(run)

      outstanding =
        workflow["steps"]
        |> Enum.reject(& &1["optional"])
        |> Enum.reject(&Map.has_key?(latest, &1["id"]))
        |> Enum.map(& &1["id"])

      attention =
        latest
        |> Enum.reject(fn {_id, entry} -> entry["outcome"] == "done" end)
        |> Enum.map(fn {id, entry} -> {id, entry["outcome"]} end)
        |> Enum.sort()

      {:ok,
       %{
         run: run,
         workflow: workflow,
         outstanding: outstanding,
         attention: attention,
         lane: run["lane"],
         gates: run["gates"],
         attempts: length(run["steps"])
       }}
    end
  end

  @doc """
  Close a run, or refuse and say why.

  Runs the lane itself — it does not accept a report of it. Options:

    * `:paths` — passed to the gate runner.
    * `:accept_partial` — a written reason for finishing on a lane that had an
      unavailable gate. Stored in the run. Without it, a partial lane refuses.
    * `:abandon` — a written reason for closing a run that was not completed.
      The run is recorded `abandoned`, which is a real outcome and not a
      failure to have one.
  """
  @spec finish(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def finish(run_id, opts \\ []) do
    with {:ok, state} <- status(run_id) do
      cond do
        # Before anything else, including `--abandon`: a stop is a statement by
        # somebody who is not this run, and finishing over it would make it
        # advisory. 
        state.run["status"] == "stopped" ->
          stopped = state.run["stopped"] || %{}

          {:error,
           "#{run_id} was stopped by #{stopped["by"]} at #{stopped["at"]}" <>
             if(stopped["at_step"], do: " during #{stopped["at_step"]}", else: "") <>
             ": #{stopped["reason"]}\n\n" <>
             "A stop is not a close. The evidence and the run's worktree are kept " <>
             "deliberately (.agents/policies/failure.md). Open a new run for the work that " <>
             "is left."}

        reason = opts[:abandon] ->
          close(state.run, "abandoned", %{"reason" => reason})

        state.outstanding != [] ->
          {:error,
           "not finished: #{Enum.join(state.outstanding, ", ")} #{plural(state.outstanding)} no " <>
             "recorded outcome. Record them, or `--abandon \"<reason>\"` if this run is being stopped."}

        state.attention != [] ->
          {:error,
           "not finished: " <>
             Enum.map_join(state.attention, "; ", fn {id, outcome} -> "#{id} is #{outcome}" end) <>
             ". Only `done` completes a step — `uncertain` is not a soft `done`."}

        true ->
          with :ok <- committed_tree(state.run, workflow: state.workflow),
               do: finish_on_gates(state, opts)
      end
    end
  end

  @doc """
  Whether the lane is about to judge a commit, for a workflow whose
  `lane_paths` says `committed_only` (WF-021). `:ok`, or the refusal.

  merge-check reads the head that a passing finish recorded, and checks that
  S differs from it only by handoff and run files (plan §4). A lane run over a
  tree with uncommitted changes has judged something that is not that head,
  or any commit, so its verdict certifies nothing merge-check can compare.
  Untracked files count: a new module nobody added is the commonest way for
  the tree and the head to differ.

  The prefixes in `exclude` are exempt because they are written by the very
  act being checked. `record/2` rewrites the run file on every step, and the
  handoff is at `working` until after this finish. Without the exemption no
  WF-021 run could finish at all.

  **Every other workflow gets `:ok`.** Their lane is over the run's change
  including what is uncommitted, and that is `lane_paths/2`'s older rule and
  a deliberate one. When git cannot answer, a `committed_only` finish is
  refused: this cannot say the tree is clean, and saying so is the check.

  Public so that the refusal can be tested without running a lane.
  """
  @spec committed_tree(t(), keyword()) :: :ok | {:error, String.t()}
  def committed_tree(run, opts \\ []) do
    case lane_rule(run, opts) do
      %{"committed_only" => true} = rule ->
        exclude = rule["exclude"] || []

        case Git.uncommitted() do
          {:ok, paths} ->
            case Enum.reject(paths, &excluded?(&1, exclude)) do
              [] -> :ok
              dirty -> {:error, dirty_refusal(dirty, exclude)}
            end

          :error ->
            {:error,
             "git could not say whether the tree is clean, and this lane's verdict is recorded " <>
               "against a head. Nothing was run."}
        end

      _ ->
        :ok
    end
  end

  defp dirty_refusal(dirty, exclude) do
    shown = Enum.take(dirty, 20)
    more = length(dirty) - length(shown)

    "commit first — the lane's verdict is recorded against a head, and uncommitted changes " <>
      "are not in it. Not committed:\n" <>
      Enum.map_join(shown, "\n", &"  #{&1}") <>
      if(more > 0, do: "\n  … and #{more} more", else: "") <>
      exempt(exclude) <> "\n\nNothing was run."
  end

  defp exempt([]), do: ""

  defp exempt(exclude),
    do:
      "\n\n#{Enum.join(exclude, " and ")} are exempt: this run and the handoff are written " <>
        "by finishing it."

  @doc """
  The paths `finish/2` runs the lane over, and a sentence saying where they
  came from.

  Explicit `:paths` win. Then, when the run's workflow declares `lane_paths`
  (WF-021 does), the paths that rule names: see below. Otherwise it is
  everything changed since the run's `base` — committed, uncommitted and
  untracked — because that is what the run changed. A run opened before `base`
  was recorded falls back to the working tree and says so, because that is the
  weaker question and a reader of the run should know it was the one asked.

  ## A workflow's own rule

  A worker's epic is judged at its landing over `git diff
  merge-base(origin/develop, S)..S`, and its lane has to be run over the same
  set or the two verdicts are about different changes. The run's own `base` is
  the wrong start for that, twice over. The worker merges origin/develop into
  the branch before it finishes, and a diff from the base then counts
  everything develop gained since as the epic's own change. And a returned
  epic is finished again by a new run, whose base is the old S, so the epic's
  earlier commits are not in it. A two-dot diff against `origin/develop` has
  the first fault in reverse: whatever develop gains after the branch last
  merged it shows up as a change the branch undid.

  So `"since": "merge-base"` diffs from `git merge-base <ref> HEAD`. The
  prefixes in `exclude` are dropped: the run file and the handoff change as
  the run finishes, and the lane is not about them. `committed_only` leaves
  the working tree out, and `committed_tree/2` refuses a finish that has one.
  Paths are listed with `--no-renames`, so a rename is its old path and its
  new one; a gate that matches only the old path still applies.

  When git cannot find the merge-base — no `origin/develop` fetched, say — the
  answer is no paths, and the sentence says why. The gate runner reads no
  paths as "we do not know what changed" and applies every gate, which is the
  safe direction; falling back to the run's `base` would have been the
  quieter answer, and could skip `harness.test` for an epic whose harness
  change was committed before the run opened.

  Public so that a test can check the decision without running a lane: a lane
  takes minutes, and a test that takes minutes to say which paths it would
  have used is a test that does not get run. `:workflow` may carry the
  workflow already loaded, which `finish/2` has.
  """
  @spec lane_paths(t(), keyword()) :: {[String.t()], String.t()}
  def lane_paths(run, opts \\ []) do
    base = run["base"]

    cond do
      paths = opts[:paths] ->
        {paths, "given"}

      rule = lane_rule(run, opts) ->
        rule_paths(rule)

      is_binary(base) ->
        case Git.changed_since(base) do
          {:ok, paths} -> {paths, "changed since #{String.slice(base, 0, 12)}"}
          :error -> working_tree_paths("git could not diff against the run's base")
        end

      true ->
        working_tree_paths("this run recorded no base, so only uncommitted changes were seen")
    end
  end

  defp working_tree_paths(why) do
    case Git.changed_paths() do
      {:ok, paths} -> {paths, "working tree only — " <> why}
      :error -> {[], "none — git did not answer, and " <> why}
    end
  end

  # The run's workflow's `lane_paths`, or nil. Read from the workflow at
  # finish rather than copied into the run at start, as the lane's gates are:
  # both are rules about how a run is judged, and the run is the subject.
  defp lane_rule(run, opts) do
    workflow =
      case opts[:workflow] do
        %{} = workflow ->
          workflow

        _ ->
          case is_binary(run["workflow"]) && Workflow.fetch(run["workflow"]) do
            {:ok, workflow} -> workflow
            _ -> nil
          end
      end

    case workflow do
      %{"lane_paths" => %{} = rule} -> rule
      _ -> nil
    end
  end

  defp rule_paths(%{"since" => "merge-base", "ref" => ref} = rule) when is_binary(ref) do
    exclude = rule["exclude"] || []
    committed_only = rule["committed_only"] == true

    what =
      "merge-base(#{ref}, HEAD)..HEAD" <>
        if(exclude == [], do: "", else: ", minus #{Enum.join(exclude, ", ")}")

    with {:ok, merge_base} <- Git.merge_base(ref, "HEAD"),
         {:ok, paths} <- epic_diff(merge_base, committed_only) do
      {Enum.reject(paths, &excluded?(&1, exclude)),
       "#{what} — merge-base #{merge_base}" <>
         if(committed_only, do: ", committed changes only", else: "")}
    else
      :error ->
        {[],
         "none — git could not answer #{what}, so the lane was given no paths and every " <>
           "gate in it applied. Is #{ref} fetched?"}
    end
  end

  defp rule_paths(rule) do
    {[],
     "none — lane_paths #{inspect(rule)} is not a rule this ledger knows, so the lane was " <>
       "given no paths and every gate in it applied"}
  end

  defp epic_diff(merge_base, true), do: Git.committed_between(merge_base, "HEAD")
  defp epic_diff(merge_base, false), do: Git.changed_since(merge_base)

  defp excluded?(path, prefixes), do: Enum.any?(prefixes, &String.starts_with?(path, &1))

  defp head_sha do
    case Git.head_sha() do
      {:ok, sha} -> sha
      :error -> nil
    end
  end

  defp finish_on_gates(state, opts) do
    lane = state.lane

    {paths, paths_from} = lane_paths(state.run, Keyword.put(opts, :workflow, state.workflow))

    # The commit the lane ran at, for every workflow. `tree` says
    # whether two attempts saw the same tree; only a sha says *which* commit a
    # verdict is about, and merge-check compares a worker's S with exactly
    # this. Taken before the lane, because that is when it ran; `nil` where
    # git cannot answer, as `tree` is.
    head = head_sha()
    started = System.monotonic_time(:millisecond)

    case Gates.run(lane, paths: paths) do
      {:error, message} ->
        {:error, "the lane could not be resolved: #{message}"}

      {:ok, {gate_status, results}} ->
        summary = Gates.summarise(lane, {gate_status, results})

        # Whole seconds of wall clock, lane only. A handoff quotes it, and a
        # copy of a number is only checkable against an original.
        seconds =
          System.convert_time_unit(
            System.monotonic_time(:millisecond) - started,
            :millisecond,
            :second
          )

        recorded = %{
          "lane" => lane,
          "status" => to_string(gate_status),
          "summary" => summary,
          "head" => head,
          "seconds" => seconds,
          # What the lane was run over, and how that list was arrived at. A
          # lane's verdict is a statement about a set of paths, and a verdict
          # without its set cannot be checked by anyone reading the run later.
          "paths" => paths,
          "paths_from" => paths_from,
          # The per-gate outcomes as data, not only as the prose summary.
          # `Noetic.Harness.Telemetry` counts these across runs, and parsing
          # them back out of the summary would make a display string into a
          # contract.
          "results" =>
            Enum.map(results, fn result ->
              %{
                "id" => result.id,
                "outcome" => to_string(result.outcome),
                "severity" => result.severity,
                "detail" => String.slice(result.detail, 0, 400)
              }
            end)
        }

        run = attempted(state.run, lane, {gate_status, results}, paths, head, seconds)

        case {gate_status, opts[:accept_partial]} do
          {:passed, _} ->
            run |> Map.put("gates", recorded) |> close("done", nil)

          {:failed, _} ->
            with :ok <- write(run),
                 do: {:error, "the #{lane} lane failed. The failure is the work.\n\n#{summary}"}

          {:partial, nil} ->
            with :ok <- write(run),
                 do:
                   {:error,
                    "the #{lane} lane is partial — a blocking gate could not run, so this work " <>
                      "is unverified rather than verified.\n\n#{summary}\n\n" <>
                      "Install the tool, or finish with `--accept-partial \"<why that is " <>
                      "acceptable here>\"`. The reason is stored in the run."}

          {:partial, reason} ->
            run
            |> Map.put("gates", recorded)
            |> close("done", %{"partial_accepted" => reason})
        end
    end
  end

  # Every time `finish/2` ran the lane, whatever came of it. Until
  # this, a failed or unacknowledged partial lane returned its refusal and wrote
  # nothing, so the ledger held only the attempt that passed — and how many
  # finishes a run took, which is rework, the number a watcher of this ledger
  # most wants, was thrown away at the one place it was known.
  #
  # Ids and outcomes only. A gate's `detail` is tool output, unscrubbed, and
  # this file is committed; the closing attempt's detail is still in `gates`.
  defp attempted(run, lane, {gate_status, results}, paths, head, seconds) do
    attempt = %{
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "lane" => lane,
      "status" => to_string(gate_status),
      "paths" => length(paths),
      # What the tree was when the lane ran: two failed attempts over one
      # fingerprint are a retry that changed nothing.
      "tree" => tree_fingerprint(),
      # And which commit it was. The fingerprint cannot be turned
      # back into one.
      "head" => head,
      "seconds" => seconds,
      "results" => Enum.map(results, &%{"id" => &1.id, "outcome" => to_string(&1.outcome)})
    }

    Map.update(run, "finish_attempts", [attempt], &(&1 ++ [attempt]))
  end

  defp close(run, status, acknowledged) do
    run =
      run
      |> Map.put("status", status)
      |> Map.put("finished_at", DateTime.to_iso8601(DateTime.utc_now()))
      |> Map.put("acknowledged", acknowledged)

    with :ok <- write(run), do: {:ok, run}
  end

  # ---- reading -------------------------------------------------------------

  @doc "One run by id."
  @spec fetch(String.t()) :: {:ok, t()} | {:error, String.t()}
  def fetch(id) do
    case Loader.load(path_for(id)) do
      {:ok, run} -> {:ok, run}
      {:error, _} -> {:error, "no run #{id} — `noetic-harness run --list` shows what there is"}
    end
  end

  @doc """
  Whether a run id resolves to a file in the ledger.

  Used by `Evolution.unmeasured/1` to refuse a fitness number whose scoring run
  cannot be opened. It is deliberately a weak claim and is documented as one:
  a run that exists is a file a commit records, not proof that the run measured
  anything.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(id) when is_binary(id) do
    # Never an interpolated path from a candidate file. The id has to be a run
    # id and nothing else, or `../../etc/passwd` is a run.
    Regex.match?(~r/^[A-Za-z0-9._-]+$/, id) and File.regular?(path_for(id))
  end

  def exists?(_), do: false

  @doc """
  Is `ancestor` the run `run_id` itself, or anywhere above it?

  Walks `parent_run`, the same chain `depth/1` and `stopped?/1` walk, with the
  same cycle guard and the same `@max_chain` ceiling.

  `Evolution` asks this. Independence used to be `by != created_by`, two
  strings the same process wrote, which is answerable by typing a different
  name; after dispatch both are written by the same loop. What cannot be
  renamed is the shape of the ledger: a run has an id, a parent and a
  dispatch history, and a dispatched run can write `failed` to it and never
  `done`. So "did the candidate score itself" becomes a question about runs.

  **A walk that could not finish answers `true`.** Every caller reads `true` as
  "not independent", so the three ways of not knowing — a cycle, a chain past
  `@max_chain`, a `parent_run` naming a run that is not on disk — have to land
  on the refusing side or the ceiling is the laundering path: fifty-one runs in
  a chain, and the fifty-second is independent of its own author. `depth/1` and
  `stopped?/1` already refuse rather than default when they hit the same
  ceiling; this is that rule, stated for a function whose return type cannot
  say so. A `parent_run` of `nil` is not one of those cases: the walk reached
  the top and the answer is a real no.
  """
  @spec ancestor?(String.t(), String.t()) :: boolean()
  def ancestor?(ancestor, run_id) when is_binary(ancestor) and is_binary(run_id) do
    # Both sides trimmed, here, once. `Evolution.unmeasured/1` trims before
    # `exists?/1` and this did not, so `" run-a "` satisfied one check and
    # defeated the other — one space promoted a candidate that had scored its
    # own holdout. Two functions comparing the same string differently is the
    # third time that shape has appeared in this subsystem, so the trimming
    # lives in the thing being compared rather than in each caller.
    walk_ancestor(String.trim(run_id), String.trim(ancestor), MapSet.new()) != :no
  end

  # Not a run id on either side: there is no chain to walk and nothing to
  # establish. `Evolution` guards the shape before asking and `Scoring` passes
  # `to_string/1`, so this clause is reached by a caller that has no candidate
  # run at all — which is refused where it matters, by
  # `Evolution.held_out_by_its_own_run/1`, rather than here.
  def ancestor?(_ancestor, _run_id), do: false

  @spec walk_ancestor(String.t() | nil, String.t(), MapSet.t()) :: :yes | :no | :unknown
  defp walk_ancestor(nil, _ancestor, _seen), do: :no

  defp walk_ancestor(run_id, ancestor, seen) do
    cond do
      run_id == ancestor ->
        :yes

      MapSet.member?(seen, run_id) or MapSet.size(seen) >= @max_chain ->
        :unknown

      true ->
        case fetch(run_id) do
          {:ok, run} -> walk_ancestor(run["parent_run"], ancestor, MapSet.put(seen, run_id))
          _ -> :unknown
        end
    end
  end

  @doc "Every run, newest first."
  @spec list() :: [t()]
  def list do
    dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Loader.load(path) do
        {:ok, run} -> [run]
        {:error, _} -> []
      end
    end)
    |> Enum.sort_by(& &1["started_at"], :desc)
  end

  @doc """
  The run this session is in, if that question has one answer.

  Three outcomes rather than two, because the two-outcome version guessed. It
  skips **ephemeral** runs — see `start/1` — and it refuses when more than one
  real run is open, naming them, rather than picking the newest. More than one
  session can share a working directory here; "newest wins" silently writes one
  session's evidence into another session's ledger, and the older files stay
  open forever because nothing tells their owner they lost.

  `{:error, message}` is the refusal and is meant to be printed: it says to
  pass `--run`.
  """
  @spec current() :: {:ok, t()} | {:error, String.t()} | :error
  def current do
    case Enum.filter(list(), &open_and_real?/1) do
      [] ->
        :error

      [run] ->
        {:ok, run}

      runs ->
        {:error,
         "#{length(runs)} runs are open and I will not guess which one is yours:\n" <>
           Enum.map_join(runs, "\n", &"  #{&1["id"]}  #{&1["title"]}") <>
           "\n\nPass --run <id>. Close the ones that are finished with " <>
           "`noetic-harness run --run <id> --finish`, or abandon them with --abandon \"<reason>\"."}
    end
  end

  defp open_and_real?(run), do: run["status"] == "open" and run["ephemeral"] != true

  # ---- what a dispatching run has spent -------------------------------------

  @doc """
  How many dispatches deep this run is, walked from the files.

  Not asked of the caller. `Dispatcher.prepare/2` took `depth` out of its
  `parent` argument, so a run that passed `%{}` — including a dispatched agent
  starting a run of its own — was believed to be at depth 0 with a full
  allowance. This walks `parent_run` instead, which is written at
  `start/1` by whoever dispatched, and is therefore a fact about what happened
  rather than a claim about it.

  A chain that cannot be walked — a missing parent file, or a cycle — returns
  what was counted so far rather than raising. Under-counting is the failure
  mode to avoid, so a broken chain stops at the break and the caller still has
  its own claimed depth to take the maximum of.
  """
  @spec depth(String.t()) :: non_neg_integer()
  def depth(run_id), do: walk_depth(run_id, 0, MapSet.new())

  defp walk_depth(nil, count, _seen), do: count

  defp walk_depth(run_id, count, seen) do
    cond do
      MapSet.member?(seen, run_id) -> count
      count >= @max_chain -> count
      true -> step_up(run_id, count, seen)
    end
  end

  defp step_up(run_id, count, seen) do
    case fetch(run_id) do
      {:ok, %{"parent_run" => parent}} when is_binary(parent) ->
        walk_depth(parent, count + 1, MapSet.put(seen, run_id))

      _ ->
        count
    end
  end

  @doc """
  Record what one dispatch actually cost.

  `:elapsed_ms` is required. `:cost_usd` is optional and **must be left out
  when it is not known** rather than passed as zero: `claude -p` reports
  `total_cost_usd`, the API adapters report token counts and no price, and a
  zero there would make the cost ceiling unreachable by exactly the adapters
  whose spend is hardest to see. An unknown cost is recorded as unknown and
  `spent/1` says so.

  `:model` is the model the plan named and `:model_reported` what the adapter
  says ran, recorded only when it differs; both only in the shape of a model
  id. `:usage` is the adapter's token counts. Only the four counters `Usage` knows,
  and only as integers, reach the entry: run files are committed, and an
  adapter's `usage` map is the adapter's to fill — nothing else it put there
  is copied into git.
  """
  @spec spend(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def spend(run_id, opts) do
    with {:ok, run} <- fetch(run_id) do
      entry = %{
        "step" => opts[:step],
        "adapter" => opts[:adapter],
        "model" => model_id(opts[:model]),
        "elapsed_ms" => opts[:elapsed_ms] || 0,
        "cost_usd" => opts[:cost_usd],
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      entry =
        case tokens(opts[:usage]) do
          empty when empty == %{} -> entry
          tokens -> Map.put(entry, "usage", tokens)
        end

      reported = model_id(opts[:model_reported])

      entry =
        if is_binary(reported) and reported != entry["model"],
          do: Map.put(entry, "model_reported", reported),
          else: entry

      run = Map.update(run, "dispatches", [entry], &(&1 ++ [entry]))
      with :ok <- write(run), do: {:ok, run}
    end
  end

  @token_counters ~w(input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens)

  defp tokens(usage) when is_map(usage) do
    for {key, value} <- usage,
        key = to_string(key),
        key in @token_counters,
        is_integer(value) and value >= 0,
        into: %{},
        do: {key, value}
  end

  defp tokens(_), do: %{}

  # A model id is what an adapter says ran — for `router`, what a remote
  # service said — and it is written to a committed file. Only the shape of an
  # id gets there: `claude-sonnet-5`, `ollama/qwen3.5:0.8b`, `org/model@v2`.
  defp model_id(id) when is_binary(id) do
    if id =~ ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,199}\z/, do: id, else: "(not a model id)"
  end

  defp model_id(_), do: nil

  @doc """
  Record what a *session* cost, beside what the dispatches cost.

  A separate key from `dispatches` and a separate function from `spend/2`,
  because the two answer different questions and averaging them would answer
  neither. A dispatch is one agent call the harness made and can bound; a
  session is the whole of somebody working in this repository, which the
  harness does not bound and until now could not see at all — 21 runs, zero
  dispatches, $0.00.

  Keeping them apart also keeps the ceilings honest: `spent/1` walks
  `dispatches` and feeds `Dispatcher`'s cost ceiling, and a session's tokens
  must not silently start closing a budget that was written about dispatches.

  Idempotent by `session`: a hook that fires twice on the same transcript
  replaces the entry rather than adding a second one. A transcript grows
  monotonically within a session, so the later reading is the right one.
  """
  @spec observe(String.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def observe(run_id, summary) when is_map(summary) do
    with {:ok, run} <- fetch(run_id) do
      # Identity is `session`, a digest of the transcript's full path, and not
      # its basename: two transcripts in different directories share a
      # basename and would silently replace each other. `Usage.read/1` writes
      # both, and the fallback exists for a summary built by hand.
      session = summary["session"] || summary[:session] || summary["transcript"]

      entry =
        summary
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put("at", DateTime.to_iso8601(DateTime.utc_now()))

      kept =
        run["sessions"]
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.reject(&((&1["session"] || &1["transcript"]) == session))

      run = Map.put(run, "sessions", kept ++ [entry])

      with :ok <- write(run), do: {:ok, run}
    end
  end

  @decision_required ~w(provider model question policy_version projection_version projection_hash action)
  @decision_optional ~w(model_revision step)
  @decision_timings ~w(queue inference network total)
  # An identifier: no spaces, bounded. Free text has spaces; that is the test.
  @identifier ~r/\A[A-Za-z0-9_.@:\/+-]{1,128}\z/

  @doc """
  Record a decision a model took part in, beside the run it influenced
  (the addendum's Gap 13: a later agent sees `route = typedb` and
  cannot tell how it was produced).

  In the ledger rather than in a store of its own — the ledger already refuses
  a done step with no evidence, and a second place for decisions would be a
  second retention and a second drift.

  **Identifiers only, because this file is committed.** `noetic-harness usage`
  reads no content for the same reason. A trace carries who answered
  (`provider`, `model`, `model_revision`), which question and version, which
  policy version, which projection version and its **hash**, the timings and
  the resulting action — and never the projected state. The hash identifies
  the state; the state is what would carry somebody's prompt text into a
  repository. Every string field must be an identifier (no spaces, at most 128
  characters) and any key outside the list is refused, so free text cannot
  arrive under a field this function did not expect.
  """
  @spec decision(String.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def decision(run_id, trace) when is_map(trace) do
    with {:ok, run} <- fetch(run_id),
         {:ok, entry} <- decision_entry(Map.new(trace, fn {k, v} -> {to_string(k), v} end)) do
      run = Map.put(run, "decisions", List.wrap(run["decisions"]) ++ [entry])
      with :ok <- write(run), do: {:ok, run}
    end
  end

  defp decision_entry(trace) do
    allowed = @decision_required ++ @decision_optional ++ ["timings_ms"]

    errors =
      Enum.map(Map.keys(trace) -- allowed, &"#{&1} is not a decision-trace field") ++
        Enum.map(@decision_required -- Map.keys(trace), &"#{&1} is required") ++
        for {k, v} <- Map.take(trace, @decision_required ++ @decision_optional),
            not (is_binary(v) and Regex.match?(@identifier, v)),
            do: "#{k} is not an identifier; free text does not go in a committed file"

    timings = trace["timings_ms"] || %{}

    timing_errors =
      if is_map(timings) and
           Enum.all?(timings, fn {k, v} -> to_string(k) in @decision_timings and is_number(v) end),
         do: [],
         else: ["timings_ms holds only #{Enum.join(@decision_timings, ", ")}, as numbers"]

    case errors ++ timing_errors do
      [] ->
        {:ok,
         trace
         |> Map.put("timings_ms", Map.new(timings, fn {k, v} -> {to_string(k), v} end))
         |> Map.put("at", DateTime.to_iso8601(DateTime.utc_now()))}

      errors ->
        {:error, "decision trace refused: " <> Enum.join(errors, "; ")}
    end
  end

  @doc """
  What this run's sessions have cost, summed per token counter.

  Not walked up `parent_run`, unlike `spent/1`: a session is not dispatched by
  anything and does not belong to a tree.

  **Every field is guarded, because these files are written by people.** A
  run in `.agents/runs/` is JSON somebody or something else may have edited,
  and an independent review fed this a `sessions` entry that was not a map and
  one whose counts were strings: the first raised out of `Access.get/3` and
  the second out of arithmetic, and `noetic-harness run --status` died with a
  stack trace **halfway through its own output**, after printing the title.
  `Telemetry.usage_counts/1` already guarded the same data; this did not, and
  two readers of one file disagreeing about whether it can be trusted is how
  the disagreement becomes a crash.
  """
  @spec observed(String.t()) :: map()
  def observed(run_id) do
    sessions =
      case fetch(run_id) do
        {:ok, run} -> run["sessions"] |> List.wrap() |> Enum.filter(&is_map/1)
        _ -> []
      end

    Enum.reduce(sessions, %{"sessions" => length(sessions), "messages" => 0, "tokens" => %{}}, fn
      session, acc ->
        tokens =
          case session["tokens"] do
            counters when is_map(counters) ->
              Enum.reduce(counters, acc["tokens"], fn {key, value}, into ->
                Map.update(into, key, count(value), &(&1 + count(value)))
              end)

            _ ->
              acc["tokens"]
          end

        acc
        |> Map.put("tokens", tokens)
        |> Map.update!("messages", &(&1 + count(session["messages"])))
    end)
  end

  defp count(n) when is_integer(n), do: n
  defp count(_), do: 0

  @doc """
  What this run and everything above it has spent.

  `%{elapsed_ms: integer, cost_usd: float, cost_known?: boolean}`. The walk is
  up the `parent_run` chain, because the ceiling bounds a *tree* of dispatches
  and not one run — thirty minutes at depth 2 is ninety minutes wearing a
  thirty-minute label.

  `cost_known?` is false as soon as one dispatch in the chain reported no
  price. The number is still returned and is still a lower bound; what is
  false is that it can be compared against a ceiling and trusted.
  """
  @spec spent(String.t()) :: %{
          elapsed_ms: non_neg_integer(),
          cost_usd: float(),
          cost_known?: boolean()
        }
  def spent(run_id),
    do: walk_spend(run_id, %{elapsed_ms: 0, cost_usd: 0.0, cost_known?: true}, MapSet.new())

  defp walk_spend(nil, acc, _seen), do: acc

  defp walk_spend(run_id, acc, seen) do
    if MapSet.member?(seen, run_id) or MapSet.size(seen) >= @max_chain do
      acc
    else
      case fetch(run_id) do
        {:ok, run} ->
          acc = Enum.reduce(run["dispatches"] || [], acc, &add_spend/2)
          walk_spend(run["parent_run"], acc, MapSet.put(seen, run_id))

        _ ->
          acc
      end
    end
  end

  defp add_spend(entry, acc) do
    %{
      elapsed_ms: acc.elapsed_ms + (entry["elapsed_ms"] || 0),
      cost_usd: acc.cost_usd + (entry["cost_usd"] || 0.0),
      cost_known?: acc.cost_known? and not is_nil(entry["cost_usd"])
    }
  end

  # ---- stopping from outside ------------------------------------------------

  @doc """
  Stop a run, from outside it.

  A harness that acts must be stoppable by somebody who is not it.
  A stop is **not** a close — `finish/2` refuses a stopped run exactly as it
  refuses one with an unfinished step, because a run that can be finished after
  being stopped makes the stop advisory.

  What is recorded: who, when, and which step was outstanding. What survives:
  everything. `.agents/policies/failure.md` — "the evidence is not reverted
  along with the code" — was written for retry exhaustion and applies here
  unchanged, and the run's own worktree is kept so the partial writes are
  diagnosable rather than merely gone.
  """
  @spec stop(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def stop(run_id, opts \\ []) do
    with {:ok, reason} <- require_opt(opts, :reason, "a stop needs a reason: it goes in the run"),
         {:ok, run} <- fetch(run_id) do
      if run["status"] in ["open", nil] do
        run
        |> Map.merge(%{
          "status" => "stopped",
          "finished_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "stopped" =>
            Identity.sign(
              %{
                # One answer to "who", not two: `by` used to read $USER while
                # the actor read HARNESS_AGENT first, and a review found a stop
                # recording `by:` a person's login beside `actor.name: "claude"`.
                "by" => Identity.actor(by: opts[:by])["name"],
                "actor" => Identity.actor(by: opts[:by]),
                "reason" => scrub(reason),
                "at_step" => opts[:step] || last_step(run),
                "at" => DateTime.to_iso8601(DateTime.utc_now())
              },
              "run_stop",
              run_id,
              position(run["steps"])
            )
        })
        |> then(fn run -> with :ok <- write(run), do: {:ok, run} end)
      else
        {:error, "#{run_id} is already #{run["status"]}, so there is nothing to stop"}
      end
    end
  end

  # Paths and held secrets out, and a credential this process never held
  # withheld rather than written (Noetic.Harness.Redact).
  defp scrub(text) when is_binary(text) do
    scrubbed = Redact.scrub(text)

    if Redact.credential_url?(scrubbed),
      do:
        "(withheld: it contained a scheme://user:password@host run, and this file is committed)",
      else: scrubbed
  end

  defp scrub(other), do: other

  # Where a new record goes: after every step recorded so far.
  defp position(steps) do
    %{seq: length(steps), prev: steps |> List.last() |> then(&(&1 && Signature.digest(&1)))}
  end

  @doc """
  How much of a run is attested: each step checked at its
  own position against the one before it, and the stop, if there is one.

  Read from the file's bytes, not from `fetch/1`: a file that gives some
  object a key twice is a file two JSON readers disagree about, and has
  `duplicate_keys: true` and nothing attested. Deleting the *last* step leaves
  every earlier one attested — a chain proves what is in it, not that nothing
  followed.
  """
  @spec attestation(String.t()) ::
          {:ok,
           %{
             steps: non_neg_integer(),
             attested: non_neg_integer(),
             stop: boolean() | nil,
             duplicate_keys: boolean()
           }}
          | {:error, String.t()}
  def attestation(run_id) do
    with {:ok, bytes} <- File.read(path_for(run_id)),
         {:ok, run} <- fetch(run_id) do
      steps = run["steps"] || []
      duplicate? = Signature.duplicate_keys?(bytes)

      attested =
        if duplicate?,
          do: 0,
          else:
            steps
            |> Enum.with_index()
            |> Enum.count(fn {step, i} ->
              Identity.attested?(step, "run_step", run_id, position(Enum.take(steps, i)))
            end)

      stop =
        case run["stopped"] do
          nil ->
            nil

          stopped ->
            not duplicate? and Identity.attested?(stopped, "run_stop", run_id, position(steps))
        end

      {:ok, %{steps: length(steps), attested: attested, stop: stop, duplicate_keys: duplicate?}}
    else
      {:error, reason} when is_atom(reason) -> {:error, "no run #{run_id}: #{reason}"}
      {:error, message} -> {:error, message}
    end
  end

  @doc "Whether this run, or any run above it, has been stopped."
  @spec stopped?(String.t()) :: boolean()
  def stopped?(run_id), do: walk_stopped(run_id, MapSet.new())

  defp walk_stopped(nil, _seen), do: false

  defp walk_stopped(run_id, seen) do
    if MapSet.member?(seen, run_id) or MapSet.size(seen) >= @max_chain do
      false
    else
      case fetch(run_id) do
        {:ok, %{"status" => "stopped"}} -> true
        {:ok, run} -> walk_stopped(run["parent_run"], MapSet.put(seen, run_id))
        _ -> false
      end
    end
  end

  defp last_step(run) do
    case List.last(run["steps"] || []) do
      nil -> nil
      entry -> entry["step"]
    end
  end

  @doc """
  Remove a run's file.

  The one deletion in this module, and it is deliberately narrow: it exists so
  that `noetic-harness run --prune-ephemeral` can clear the files a crashed test
  left behind. Nothing else calls it, and nothing in the recording path does —
  a ledger that can erase its own entries is not a ledger.
  """
  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(id) do
    path = path_for(id)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, "no run #{id}"}
      {:error, reason} -> {:error, "could not remove #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Remove the open ephemeral runs a test suite left behind.

  `.agents/runs/` is committed, and `Mix.env() == :test` makes every run
  ephemeral, so a test that crashes before its `on_exit` runs leaves a file in
  the registry. It has happened repeatedly — twice by a callback that read an
  empty process dictionary because `on_exit` runs in another process, and
  again from two suite runs abandoned mid-flight.

  Only **open** ephemeral runs go. A closed one is the record of a suite that
  finished, and deleting records is not this function's job.

  Only runs this VM may sweep go (`Noetic.Harness.Owner.sweepable?/1`): its
  own, and those of a VM that no longer exists. Until an earlier change a finishing
  suite deleted the open runs of a suite still running beside it in the same
  checkout, which then failed with `no run run-...` mid-test.

  Returns the ids it removed. Called by `noetic-harness run --prune-ephemeral`
  and, so that nobody has to remember it, by `ExUnit.after_suite/1` in
  `test_helper.exs`.

  A tracked file is never removed, whatever its flags say — see
  `Artifact.tracked?/1` for what that guard cost to learn. Litter is untracked
  by definition.
  """
  @spec prune_ephemeral() :: [String.t()]
  def prune_ephemeral do
    list()
    |> Enum.filter(&(&1["ephemeral"] == true and &1["status"] == "open"))
    |> Enum.filter(&Owner.sweepable?(&1["owner_vm"]))
    |> Enum.reject(&Noetic.Harness.Artifact.tracked?(path_for(&1["id"])))
    |> Enum.filter(&match?(:ok, delete(&1["id"])))
    |> Enum.map(& &1["id"])
  end

  defp tree_fingerprint do
    case Git.tree_fingerprint() do
      {:ok, digest} -> digest
      :error -> nil
    end
  end

  # ---- internals -----------------------------------------------------------

  defp latest_by_step(run) do
    Enum.reduce(run["steps"], %{}, fn entry, acc -> Map.put(acc, entry["step"], entry) end)
  end

  defp fetch_workflow(nil), do: {:error, "which workflow? `noetic-harness workflows` lists them"}

  defp fetch_workflow(id) do
    case Workflow.fetch(id) do
      {:ok, workflow} -> {:ok, workflow}
      :error -> {:error, "no workflow #{id} — `noetic-harness workflows` lists them"}
    end
  end

  defp known_step(workflow, step_id) do
    ids = Enum.map(workflow["steps"], & &1["id"])

    if step_id in ids do
      :ok
    else
      {:error, "#{workflow["id"]} has no step #{step_id}. Its steps: #{Enum.join(ids, ", ")}"}
    end
  end

  defp validate_outcome(nil),
    do: {:error, "an outcome is required, one of: #{Enum.join(@outcomes, ", ")}"}

  defp validate_outcome(outcome) when outcome in @outcomes, do: {:ok, outcome}

  defp validate_outcome(other),
    do:
      {:error, "#{inspect(other)} is not a terminal state. One of: #{Enum.join(@outcomes, ", ")}"}

  defp validate_evidence("done", evidence) do
    case List.wrap(evidence) |> Enum.reject(&(to_string(&1) == "")) do
      [] ->
        {:error,
         "a step recorded `done` needs evidence: the command you ran and what it said. " <>
           "If there is nothing to cite, the honest outcome is `uncertain`."}

      list ->
        {:ok, Enum.map(list, &to_string/1)}
    end
  end

  defp validate_evidence(_outcome, evidence),
    do: {:ok, evidence |> List.wrap() |> Enum.map(&to_string/1)}

  defp require_opt(opts, key, message) do
    case opts[key] do
      nil -> {:error, message}
      "" -> {:error, message}
      value -> {:ok, value}
    end
  end

  # A parent has to be a run that exists. A typo writes a chain that starts
  # where it should not: `depth/1` counts from here, `spent/1` accumulates
  # along it and `ancestor?/2` decides independence by walking it, and all
  # three answer confidently for a parent nobody can open. It is refused at the
  # one moment anybody can still fix it. A parent deleted *later* is a
  # different thing and stays tolerated — `depth/1` stops at it and
  # `ancestor?/2` treats the unfinished walk as "cannot establish".
  defp parent_for(opts) do
    case opts[:parent_run] || System.get_env(@parent_env) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.trim(value) do
          "" ->
            {:ok, nil}

          parent ->
            if exists?(parent),
              do: {:ok, parent},
              else:
                {:error,
                 "no run #{inspect(parent)} to be dispatched by: a parent has to be a run in " <>
                   "the ledger, because depth, spend and independence are all walked from it"}
        end

      other ->
        {:error, "parent_run is #{inspect(other)}, which is not a run id"}
    end
  end

  # The date, the workflow and the bead say what the run was; the last part
  # says which one. Without it two runs of one workflow on one bead on one day
  # had one id, and the second `start/1` overwrote the first's file — every
  # step, signature and lane result in it — and printed success.
  # That is the ordinary case the moment two machines share a bead. Random
  # rather than `:erlang.unique_integer/1`, which is unique on one node only.
  defp build_id(workflow_id, bead, title) do
    suffix = bead || slug(title)
    nonce = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "run-#{Date.utc_today()}-#{String.downcase(workflow_id)}-#{suffix}-#{nonce}"
  end

  defp slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
  end

  defp plural([_one]), do: "has"
  defp plural(_many), do: "have"

  defp dir, do: Noetic.Harness.agents_path(@dir)
  defp path_for(id), do: Path.join(dir(), "#{id}.json")

  defp write(run) do
    File.mkdir_p!(dir())
    File.write(path_for(run["id"]), Loader.pretty!(run))
  end

  # A run's first write creates its file and must never replace one. The
  # nonce makes a collision improbable; this makes one an error instead of a
  # silent loss, which is the property the ledger needs.
  defp write_new(run) do
    File.mkdir_p!(dir())

    case File.write(path_for(run["id"]), Loader.pretty!(run), [:exclusive]) do
      :ok ->
        :ok

      {:error, :eexist} ->
        {:error, "#{run["id"]} already exists, and a run's file is never replaced. Start again."}

      {:error, reason} ->
        {:error, "#{run["id"]} could not be written: #{:file.format_error(reason)}"}
    end
  end
end
