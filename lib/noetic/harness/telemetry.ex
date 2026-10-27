defmodule Noetic.Harness.Telemetry do
  @moduledoc """
  What the development system keeps doing wrong, counted rather than felt.

  WF-020 exists for the case where *the same work keeps failing the same way*,
  and its answer is to change the development system rather than retry the
  work. That decision needs a number. Before this module the inputs — gate
  results, run outcomes, memory records — were read by hand, which means they
  were read as impressions, and an impression is exactly what you get when you
  have just been annoyed by something three times.

  So: `collect/1` counts, `clusters/2` says which counts are a **family rather
  than an anecdote**, and `delta/2` turns two collections into the metric map
  the evolution gates read.

  ## The refusal that matters

  **A cluster requires a population, not just a count.** Three failures out of
  three observations is not a weakness cluster; it is all the data there is.
  `clusters/2` therefore returns `{:insufficient, needed}` until the relevant
  population reaches `:min_population` (default #{10}), and says how many more
  observations it needs.

  Without that floor the first three runs after installing a new gate would
  present as a weakness in the development system, WF-020 would fire, and an
  evolution experiment would be opened against noise — which is the Goodhart
  failure one level up: optimising the measure of the process that measures the
  work.

  ## What it reads, and what it says it could not read

  `.agents/runs/*.json` and `.agents/memory/records/*.json`, both on disk, plus
  beads when `bd` answers. A source that could not be read is named in
  `unverified` rather than treated as empty — an absent source and a source
  with nothing in it are different facts, and only one of them means "no
  problems here".

  It does not instrument anything at runtime. Everything here is already
  written down by the run ledger; this is arithmetic over it.
  """

  alias Noetic.Harness.{Beads, Hooks, Loader, Memory, Run, Usage}

  @min_population 10
  @cluster_threshold 3

  @type summary :: map()
  @type cluster :: map()

  @doc "The default threshold: three of the same shape, as WF-020 states it."
  @spec cluster_threshold() :: pos_integer()
  def cluster_threshold, do: @cluster_threshold

  # ---- collection ----------------------------------------------------------

  @doc """
  Count everything the development system has left on disk.

  Options: `:since` — an ISO8601 date or datetime string; runs and records
  started before it are excluded. Useful for `delta/2`, where the question is
  what changed after an experiment.
  """
  @spec collect(keyword()) :: summary()
  def collect(opts \\ []) do
    since = Keyword.get(opts, :since)

    runs = Run.list() |> Enum.filter(&after?(&1["started_at"], since))
    records = Memory.list() |> Enum.filter(&after?(&1["created_at"], since))

    %{
      "generated_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "since" => since,
      "population" => %{
        "runs" => length(runs),
        "memory_records" => length(records),
        "gate_observations" => runs |> Enum.flat_map(&gate_results/1) |> length(),
        "step_observations" => runs |> Enum.flat_map(&(&1["steps"] || [])) |> length(),
        "session_observations" => runs |> Enum.flat_map(&(&1["sessions"] || [])) |> length()
      },
      "runs" => run_counts(runs),
      "gates" => gate_counts(runs),
      "steps" => step_counts(runs),
      "lanes" => lane_counts(runs),
      "memory" => memory_counts(records),
      "usage" => usage_counts(runs),
      "beads" => bead_counts(runs),
      "hooks" => hook_counts(),
      "routing" => routing_counts(since),
      "unverified" => unverified()
    }
  end

  # The denominator every efficiency metric needs, and the reason an earlier change
  # is a bead rather than a line: "the harness got more efficient" is a ratio,
  # and this repository had no bottom half of one.
  #
  # **Closed** beads, counted **distinctly**, and only those whose run actually
  # recorded a session. A run that recorded no usage contributes zero tokens,
  # and dividing by it would report an improvement that is really a missing
  # measurement — the same failure `usage_counts/1` guards with
  # `runs_with_usage`. Two runs against one bead are one bead: the unit is the
  # work, not the bookkeeping.
  defp bead_counts(runs) do
    closed =
      runs
      |> Enum.filter(&(&1["status"] == "done" and is_binary(&1["bead"])))
      |> Enum.map(& &1["bead"])
      |> Enum.uniq()

    measured =
      runs
      |> Enum.filter(
        &(&1["status"] == "done" and is_binary(&1["bead"]) and (&1["sessions"] || []) != [])
      )
      |> Enum.map(& &1["bead"])
      |> Enum.uniq()

    %{"closed" => length(closed), "measured" => length(measured)}
  end

  @doc """
  What the work cost per unit of work. **Lower is better**, unlike `metrics/1`.

  `Evolution.gates/1` requires at least one declared efficiency
  metric to have improved, and nothing in this repository measured one:
  `metrics.efficiency` was a list of names and the names pointed at nothing.

  Every metric here is computed from data the ledger already holds. A metric
  whose denominator is zero is **absent** rather than zero — `Diff` omits a
  metric present on only one side, and a cost that could not be measured is
  not a low cost. That rule is why `gate_seconds_per_lane`, which
  An earlier change lists as a candidate, is **not** here: gate wall-clock is not
  in the ledger, and adding the name without the measurement is exactly the
  defect this bead was filed about.

  The four token counters stay four. Two billion cache-read tokens and ten
  million cache-creation tokens do not price the same way, and one `tokens`
  number would hide the one worth optimising.

  `.agents/evolution/baseline.json` holds the frozen first reading and, for
  each metric, the measurement that would catch it being gamed — because every
  one of these is the kind of number Goodhart eats. `output_tokens_per_bead`
  falls beautifully if the beads get smaller.
  """
  @spec efficiency(summary()) :: %{String.t() => float()}
  def efficiency(summary) do
    beads = get_in(summary, ["beads", "measured"]) || 0
    usage = summary["usage"] || %{}
    tokens = usage["tokens"] || %{}
    hooks = summary["hooks"] || %{}
    steps = Map.values(summary["steps"] || %{})

    %{}
    |> put_cost("output_tokens_per_bead", tokens["output_tokens"], beads)
    |> put_cost("cache_creation_tokens_per_bead", tokens["cache_creation_input_tokens"], beads)
    |> put_cost("cache_read_tokens_per_bead", tokens["cache_read_input_tokens"], beads)
    |> put_cost("input_tokens_per_bead", tokens["input_tokens"], beads)
    |> put_cost("thinking_tokens_per_bead", usage["thinking_tokens"], beads)
    |> put_cost("tool_calls_per_bead", usage["tools"] |> tool_total(), beads)
    |> put_cost("messages_per_bead", usage["messages"], beads)
    |> put_cost(
      "attempts_per_step",
      steps |> Enum.map(& &1["attempts"]) |> Enum.sum(),
      steps |> Enum.map(&(&1["runs"] || 0)) |> Enum.sum()
    )
    |> put_hook("hook_ms_per_prompt", hooks, "user_prompt", &(&1["p50"] / 1))
    |> put_hook("hook_bytes_per_prompt", hooks, "user_prompt", &(&1["bytes"] / &1["count"]))
  end

  @baseline_path ".agents/evolution/baseline.json"

  @doc """
  Where the frozen first reading lives.
  """
  @spec baseline_path() :: Path.t()
  def baseline_path, do: Path.join(Noetic.Harness.root(), @baseline_path)

  @doc """
  The frozen baseline, or `:none`.
  """
  @spec baseline() :: {:ok, map()} | :none
  def baseline do
    case Loader.load(baseline_path()) do
      {:ok, document} -> {:ok, document}
      _ -> :none
    end
  end

  @doc """
  Take the baseline, once.

  An earlier change, and the refusal is the feature. `.agents/policies/evolution.md`
  says metrics are frozen at proposal because "a tolerance moved after a result
  is in arrives looking like a result" — and a *baseline* moved after a result
  is in is the same thing one level down. So this writes the file when there
  is none and refuses when there is, naming the date of the one that exists.

  Re-taking it is a deliberate act with a reason, which means deleting a
  committed file: a diff a reviewer can see, rather than a number that quietly
  became easier to beat.
  """
  @spec take_baseline(summary()) :: {:ok, map()} | {:error, String.t()}
  def take_baseline(summary) do
    path = baseline_path()

    if File.exists?(path) do
      {:ok, existing} = Loader.load(path)

      {:error,
       "a baseline was taken on #{existing["taken_at"]} over " <>
         "#{get_in(existing, ["population", "beads_measured"])} bead(s). It is frozen. " <>
         "Delete #{@baseline_path} in a commit with a reason if it must be re-taken."}
    else
      document = %{
        "taken_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "doc" =>
          "The first reading of every efficiency metric, frozen. Lower is better. " <>
            "A candidate's efficiency gain is measured against this and not against a " <>
            "number chosen after seeing the candidate.",
        "population" => %{
          "runs" => get_in(summary, ["population", "runs"]),
          "beads_closed" => get_in(summary, ["beads", "closed"]),
          "beads_measured" => get_in(summary, ["beads", "measured"]),
          "runs_with_usage" => get_in(summary, ["usage", "runs_with_usage"])
        },
        "provisional" => (get_in(summary, ["beads", "measured"]) || 0) < @min_population,
        "provisional_note" =>
          "`beads_measured` is the denominator of every per-bead metric here. Below " <>
            "#{@min_population} it is the same population floor `--clusters` refuses under, " <>
            "and a candidate measured against it must say so.",
        "metrics" => efficiency(summary),
        "gaming" => gaming_questions()
      }

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Loader.pretty!(document))
      {:ok, document}
    end
  end

  @doc """
  For each efficiency metric, the measurement that would catch it being gamed.

  An earlier change is explicit that this bead "does not get to add a metric
  without also saying which held-out measurement would catch it being gamed",
  and it names the obvious one itself: tokens per closed bead falls
  beautifully if the beads get smaller.
  """
  @spec gaming_questions() :: %{String.t() => String.t()}
  def gaming_questions do
    smaller_beads =
      "Falls if the beads get smaller. The held-out check is the environment suite: " <>
        "`noetic-harness environments --verify` scores solving a fixed defect, and a bead " <>
        "that shrank does not make a fixed defect easier. If this improves while the " <>
        "holdout set's solve rate does not, the beads shrank."

    %{
      "output_tokens_per_bead" => smaller_beads,
      "cache_creation_tokens_per_bead" => smaller_beads,
      "cache_read_tokens_per_bead" => smaller_beads,
      "input_tokens_per_bead" => smaller_beads,
      "thinking_tokens_per_bead" =>
        smaller_beads <>
          " It also falls by thinking less, which is not obviously worse and not obviously " <>
          "better — pair it with `step_first_try_rate`, which falls if the thinking was " <>
          "load-bearing.",
      "tool_calls_per_bead" =>
        "Falls by batching, which is real, and by doing less, which is not. Pair it with " <>
          "`gate_pass_rate` and `run_completion_rate` as capability metrics with tolerances: " <>
          "fewer calls that finish fewer runs is not an improvement.",
      "messages_per_bead" =>
        "Falls if work moves out of the session and into an untracked place. The held-out " <>
          "check is `beads_measured` against `beads_closed` — if the gap widens, the work " <>
          "did not get cheaper, it stopped being recorded.",
      "attempts_per_step" =>
        "Falls if steps stop being retried because they stop being attempted. `step_first_" <>
          "try_rate` moving the same way is consistent; the ledger's `runs` per step moving " <>
          "down is the tell.",
      "hook_ms_per_prompt" =>
        "Falls to zero if the hook stops answering — `outcomes.silent` and `outcomes.timeout` " <>
          "in the hook log are the held-out check, and `injected` falling while this improves " <>
          "means the overhead went away with the routing.",
      "hook_bytes_per_prompt" =>
        "Falls by injecting nothing. Same check: `outcomes.injected` must not fall with it."
    }
  end

  defp tool_total(nil), do: nil
  defp tool_total(tools) when is_map(tools), do: tools |> Map.values() |> Enum.sum()

  defp put_cost(map, _name, nil, _denominator), do: map
  defp put_cost(map, _name, _numerator, 0), do: map
  defp put_cost(map, _name, _numerator, nil), do: map

  defp put_cost(map, name, numerator, denominator),
    do: Map.put(map, name, numerator / denominator)

  # The hook's own overhead, from the rolling latency log rather than from the
  # ledger. An earlier change measured it and an earlier change gave it a cutoff; this is
  # the same number read as a cost per prompt rather than as a budget.
  defp put_hook(map, name, hooks, event, take) do
    case get_in(hooks, ["events", event]) do
      %{"checked" => true} = stats -> Map.put(map, name, take.(stats))
      # `checked` is `false` below `Hooks.min_observations/0`, and a median of
      # four is not a median — the same floor `--clusters` refuses under. An
      # unmeasured overhead is absent here rather than zero.
      _not_enough_observations -> map
    end
  end

  # How often this repository has had to correct its own routing.
  #
  # The clusters this tool reported before that bead were
  # population artifacts — "23 lessons share the scope `harness`" names where
  # the work was, not a weakness. What *did* go wrong repeatedly, and was
  # uncounted, was routing: four bad routes in one session, each fixed by
  # editing `signals.json` or a workflow trigger. Every one of those is a
  # commit touching a routing file, which is a countable event with a shape.
  #
  # Counted from git rather than from the ledger, because the ledger records
  # runs and this is a property of the *registry's* history. A repository with
  # no git, or a shallow clone, gets `nil` — which the cluster reads as "not
  # measured" rather than as zero, the same rule `Usage` applies to an unknown
  # cost.
  @routing_files [".agents/registry/signals.json", ".agents/workflows"]

  defp routing_counts(since) do
    # `since` is `nil` when no window was asked for, and `--since nil` is not
    # an empty window — it is a git invocation that fails, which this function
    # would then read as "no git" and report as unmeasured. Found by the count
    # staying `nil` while `git log` on the same paths answered 13.
    window = if since, do: ["--since", since], else: []
    args = ["log", "--format=%H"] ++ window ++ ["--"] ++ @routing_files

    case System.cmd("git", args, cd: Noetic.Harness.root(), stderr_to_stdout: true) do
      {output, 0} ->
        %{"corrections" => output |> String.split("\n", trim: true) |> length()}

      _no_git_or_no_history ->
        %{"corrections" => nil}
    end
  rescue
    _ -> %{"corrections" => nil}
  end

  # What the sessions cost, summed over the runs in the window.
  #
  # The four counters stay four, for the reason `Usage`'s moduledoc gives: two
  # billion cache-read tokens and eight million cache-creation tokens do not
  # price the same way, and one `tokens` number would hide the one worth
  # optimising. `runs_with_usage` is beside them because a mean over runs that
  # recorded nothing is not a mean.6` is the bead that turns this
  # into a metric, and it cannot without a denominator it can name.
  defp usage_counts(runs) do
    sessions = Enum.flat_map(runs, &(&1["sessions"] || []))

    tokens =
      Enum.reduce(sessions, Map.new(Usage.counters(), &{&1, 0}), fn session, acc ->
        Enum.reduce(Usage.counters(), acc, fn key, into ->
          Map.update!(into, key, &(&1 + number(get_in(session, ["tokens", key]))))
        end)
      end)

    tools =
      Enum.reduce(sessions, %{}, fn session, acc ->
        Enum.reduce(session["tools"] || %{}, acc, fn {name, n}, into ->
          Map.update(into, name, number(n), &(&1 + number(n)))
        end)
      end)

    %{
      "sessions" => length(sessions),
      "runs_with_usage" => Enum.count(runs, &((&1["sessions"] || []) != [])),
      "messages" => Enum.reduce(sessions, 0, &(&2 + number(&1["messages"]))),
      "thinking_tokens" => Enum.reduce(sessions, 0, &(&2 + number(&1["thinking_tokens"]))),
      "tokens" => tokens,
      "tools" => tools
    }
  end

  # What the harness costs the session that carries it. Not filtered by
  # `:since`: the log is a rolling window of the last observations rather than
  # a dated record, and pretending it can be sliced by date would be a claim
  # about data that is not there.
  #
  # It is also the only source here that is **not** committed, for the reason
  # `Hooks` gives — a median over a laptop, a container and a CI runner is a
  # number from three populations. So a machine that has never run the hooks
  # reports `%{}` here, which is "not measured", not "fast".
  defp hook_counts do
    read = Hooks.observations()

    %{
      "path" => read["path"],
      "unreadable" => read["unreadable"],
      "events" => Hooks.latency(read)
    }
  end

  defp number(n) when is_integer(n), do: n
  defp number(_), do: 0

  defp run_counts(runs) do
    by_status = Enum.frequencies_by(runs, & &1["status"])

    %{
      "total" => length(runs),
      "by_status" => by_status,
      "partial_accepted" =>
        Enum.count(runs, &is_map_key(&1["acknowledged"] || %{}, "partial_accepted"))
    }
  end

  defp gate_counts(runs) do
    runs
    |> Enum.flat_map(&gate_results/1)
    |> Enum.group_by(& &1["id"])
    |> Map.new(fn {id, results} ->
      {id, Enum.frequencies_by(results, & &1["outcome"])}
    end)
  end

  # A run written before the ledger recorded structured gate results has only
  # the prose summary. Those runs contribute to no gate count rather than to a
  # guessed one: a parsed display string is not an observation.
  defp gate_results(run), do: get_in(run, ["gates", "results"]) || []

  # An attempt is a second entry for the same step **within one run**. Counting
  # entries across runs instead makes two runs of the same workflow look like a
  # step retried twice, which is the first thing this module got wrong and the
  # first thing reading its output showed: every additional run of WF-002 added
  # a phantom "2 attempts" to `context`.
  defp step_counts(runs) do
    runs
    |> Enum.flat_map(fn run ->
      run["steps"]
      |> List.wrap()
      |> Enum.group_by(& &1["step"])
      |> Enum.map(fn {step, entries} ->
        {"#{run["workflow"]}/#{step}", length(entries), Enum.map(entries, & &1["outcome"])}
      end)
    end)
    |> Enum.group_by(fn {key, _attempts, _outcomes} -> key end)
    |> Map.new(fn {key, occurrences} ->
      {key,
       %{
         # How many runs reached this step at all.
         "runs" => length(occurrences),
         # Entries recorded for it, summed over those runs.
         "attempts" => occurrences |> Enum.map(fn {_k, n, _o} -> n end) |> Enum.sum(),
         # The most attempts any single run needed — the number that says
         # whether a step is hard, which an average over runs would hide.
         "worst_run" => occurrences |> Enum.map(fn {_k, n, _o} -> n end) |> Enum.max(),
         "by_outcome" =>
           occurrences |> Enum.flat_map(fn {_k, _n, o} -> o end) |> Enum.frequencies()
       }}
    end)
  end

  # Every time a lane ran, not only the time it closed the run.
  # Counted from `gates` alone, a failed lane could never appear here — a
  # refused finish wrote nothing — so `lane.failed` was a cluster the ledger
  # made impossible. A run written before `finish_attempts` existed has only
  # the closing lane, and contributes that.
  defp lane_counts(runs) do
    runs
    |> Enum.flat_map(fn run ->
      case {run["finish_attempts"], get_in(run, ["gates", "lane"])} do
        {[_ | _] = attempts, _} -> Enum.map(attempts, &{&1["lane"], &1["status"]})
        {_, nil} -> []
        {_, lane} -> [{lane, get_in(run, ["gates", "status"])}]
      end
    end)
    |> Enum.group_by(fn {lane, _status} -> lane end, fn {_lane, status} -> status end)
    |> Map.new(fn {lane, statuses} -> {lane, Enum.frequencies(statuses)} end)
  end

  defp memory_counts(records) do
    records
    |> Enum.filter(&(&1["status"] != "retired"))
    |> Enum.flat_map(&(&1["scope"] || []))
    |> Enum.frequencies()
  end

  defp unverified do
    case Beads.ready(1) do
      {:ok, _} ->
        []

      :off ->
        [
          "beads: " <>
            Noetic.Harness.Integrations.off("beads") <>
            ", so nothing here counts " <>
            "issues reopened or closed. The run and memory counts are unaffected."
        ]

      :timeout ->
        [
          "beads: `bd` did not answer within #{div(Beads.timeout(), 1000)}s, so nothing here " <>
            "counts issues reopened or closed. A stuck tracker, not an absent one — usually a " <>
            "Dolt lock held by another session in this working directory. The " <>
            "run and memory counts are unaffected."
        ]

      :error ->
        [
          "beads: `bd` is not answering, so nothing here counts issues reopened or " <>
            "closed. The run and memory counts are unaffected."
        ]
    end
  end

  # ---- clustering ----------------------------------------------------------

  @doc """
  The weakness clusters in a summary: shapes seen at least `:threshold` times.

  Returns `{:ok, clusters}` or `{:insufficient, message}`. The second is not an
  error and not an empty result — it is the statement that the question cannot
  be answered yet, and it says how many more observations would answer it.

  Options: `:threshold` (default #{@cluster_threshold}, which is the number
  WF-020 names) and `:min_population` (default #{@min_population}).
  """
  @spec clusters(summary(), keyword()) :: {:ok, [cluster()]} | {:insufficient, String.t()}
  def clusters(summary, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @cluster_threshold)
    min_population = Keyword.get(opts, :min_population, @min_population)

    population = summary["population"] || %{}
    runs = population["runs"] || 0

    if runs < min_population do
      {:insufficient,
       "#{runs} run(s) recorded; a cluster needs at least #{min_population} to be a family " <>
         "rather than an anecdote. #{min_population - runs} more, then ask again. " <>
         "The counts in the summary are still true — they are just not yet evidence of a pattern."}
    else
      {:ok,
       (gate_clusters(summary, threshold) ++
          lane_clusters(summary, threshold) ++
          routing_clusters(summary, threshold) ++
          step_clusters(summary, threshold) ++
          run_clusters(summary, threshold) ++
          memory_clusters(summary, threshold))
       |> Enum.sort_by(& &1["count"], :desc)}
    end
  end

  defp gate_clusters(summary, threshold) do
    for {id, outcomes} <- summary["gates"] || %{},
        {outcome, count} <- outcomes,
        outcome in ~w(failed unavailable),
        count >= threshold do
      cluster(
        "gate.#{outcome}",
        id,
        count,
        Enum.sum(Map.values(outcomes)),
        case outcome do
          "unavailable" ->
            "#{id} could not run #{count} times. That is a hole in the lane, not a " <>
              "flaky gate: the work it guarded is unverified."

          "failed" ->
            "#{id} failed #{count} times. Before treating this as a weakness of the work, " <>
              "check whether the gate is asking the wrong question."
        end,
        case outcome do
          "unavailable" ->
            "Install it#{install_hint()} or remove #{id} from the " <>
              "lanes that claim it in `.agents/policies/gates.json`. A gate nobody can run " <>
              "is a claim nobody can check."

          "failed" ->
            "Read three of the failures together. If they share a cause, that is the change; " <>
              "if they do not, the gate's question is wrong and belongs in " <>
              "`.agents/policies/gates.json`."
        end
      )
    end
  end

  defp step_clusters(summary, threshold) do
    for {key, stats} <- summary["steps"] || %{},
        {outcome, count} <- stats["by_outcome"] || %{},
        outcome != "done",
        count >= threshold do
      cluster(
        "step.#{outcome}",
        key,
        count,
        stats["attempts"],
        "#{key} came out #{outcome} #{count} of #{stats["attempts"]} times. A step that is " <>
          "repeatedly #{outcome} is usually missing context or a skill, not effort.",
        "Run `noetic-harness workflows --show #{key |> String.split("/") |> hd()}` and read what " <>
          "that step is given. Add the missing context or skill to the capability in " <>
          "`.agents/registry/capabilities.json`, rather than asking the step to try harder."
      )
    end
  end

  defp run_clusters(summary, threshold) do
    abandoned = get_in(summary, ["runs", "by_status", "abandoned"]) || 0
    total = get_in(summary, ["runs", "total"]) || 0

    if abandoned >= threshold do
      [
        cluster(
          "run.abandoned",
          "any workflow",
          abandoned,
          total,
          "#{abandoned} runs were abandoned. Read their reasons together: repeated abandonment " <>
            "is usually a routing problem — the workflow did not fit the work.",
          "Route three of the abandoned titles again with `noetic-harness route --explain`. If the " <>
            "signals that fired were wrong, the change is a line in " <>
            "`.agents/registry/signals.json`; if they were right and the workflow still did " <>
            "not fit, it is the workflow's `trigger`."
        )
      ]
    else
      []
    end
  end

  # An earlier change names this shape as its own counter-example. "23 lessons
  # share the scope `harness`" says this month's work was about the harness. It
  # names no change, it passed the population floor, and it was one of only two
  # clusters the tool reported — which is what makes it the right first example
  # of the measure this epic must not optimise.
  #
  # So a scope holding the **majority** of all records is reported without a
  # change and marked `actionable: false`. Not deleted: the count is true, and
  # a scope that stops being the majority and still clusters is the signal the
  # shape was reaching for.
  # A lane that reported `partial` is a lane with an unavailable blocking gate,
  # and the work it guarded is unverified. This is a family the
  # ledger already stores and nothing counted.
  defp lane_clusters(summary, threshold) do
    for {lane, outcomes} <- summary["lanes"] || %{},
        {outcome, count} <- outcomes,
        outcome != "passed",
        count >= threshold do
      cluster(
        "lane.#{outcome}",
        lane,
        count,
        Enum.sum(Map.values(outcomes)),
        "the #{lane} lane came out #{outcome} #{count} times. A lane that is not `passed` " <>
          "verified less than it claims, and the work behind it is unverified rather than " <>
          "approved.",
        "`noetic-harness inspect --tools` says which gate could not run, and it probes rather " <>
          "than trusting the policy's `present` flag. Install it, or take the gate out of " <>
          "the lane — those are the only two honest outcomes."
      )
    end
  end

  # An earlier change's first bullet, and the one the bead argues hardest for: four
  # bad routes in one session, each corrected by editing a routing file. The
  # correction is the countable event, not the bad route — nobody records a
  # route they accepted.
  defp routing_clusters(summary, threshold) do
    case get_in(summary, ["routing", "corrections"]) do
      n when is_integer(n) and n >= threshold ->
        [
          cluster(
            "routing.corrected",
            Enum.join(@routing_files, ", "),
            n,
            n,
            "routing was corrected #{n} times in this window. Each of those is a route " <>
              "somebody read, disbelieved, and fixed — so the router is guessing in this " <>
              "repository's vocabulary rather than reading it.",
            "Route the last three corrected titles again with `--explain` and check the " <>
              "signals that fire now. If a word means two things here — `client` did, and " <>
              "an earlier change is what that cost — narrowing it is the change. If corrections " <>
              "keep coming from the same signal, that signal is the candidate WF-020 wants."
          )
        ]

      _below_threshold_or_not_measured ->
        []
    end
  end

  defp memory_clusters(summary, threshold) do
    total = summary["population"]["memory_records"] || 0

    for {scope, count} <- summary["memory"] || %{}, count >= threshold do
      dominant = total > 0 and count * 2 > total

      cluster(
        "memory.scope",
        scope,
        count,
        total,
        if dominant do
          "#{count} of #{total} lessons share the scope #{scope}. That is where the work has " <>
            "been, not a weakness: a scope holding the majority of a corpus clusters by " <>
            "arithmetic. Read it again when it stops being the majority."
        else
          "#{count} lessons share the scope #{scope} out of #{total}, and it is not the " <>
            "majority — so something in #{scope} keeps surprising people."
        end,
        unless dominant do
          "Read those #{count} lessons together with `noetic-harness memory --query #{scope}`. " <>
            "A repeated surprise in one scope is usually a missing skill or a wrong default, " <>
            "both of which are files in `.agents/`."
        end
      )
    end
  end

  # `change` is separate from `reading` since an earlier change, and the separation
  # is the point of that bead. A reading says what the number means; a change
  # says what to do about it, in the imperative, naming a file or a command. A
  # cluster that cannot fill it in is a cluster that passed the population
  # floor and taught nothing, and it is marked `actionable: false` rather than
  # quietly printed beside the ones that did.
  defp cluster(shape, subject, count, of, reading, change) do
    %{
      "shape" => shape,
      "subject" => subject,
      "count" => count,
      "of" => of,
      "reading" => reading,
      "change" => change,
      "actionable" => change != nil
    }
  end

  # ---- metrics -------------------------------------------------------------

  @doc """
  Levels, not deltas: the rates a summary reports right now.

  Each is oriented so that **higher is better**, because `delta/2` feeds
  `Noetic.Harness.Evolution`, whose gates read a positive number as an
  improvement. A rate with no observations behind it is absent rather than
  zero — and the difference matters, since `Evolution.gates/1` treats an
  unmeasured capability metric as a failure.
  """
  @spec metrics(summary()) :: %{String.t() => float()}
  def metrics(summary) do
    gate_outcomes = summary["gates"] |> Map.values() |> Enum.flat_map(&Map.to_list/1)
    gate_total = gate_outcomes |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    gate_passed =
      gate_outcomes
      |> Enum.filter(&(elem(&1, 0) == "passed"))
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    gate_unavailable =
      gate_outcomes
      |> Enum.filter(&(elem(&1, 0) == "unavailable"))
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    steps = Map.values(summary["steps"] || %{})
    step_attempts = steps |> Enum.map(& &1["attempts"]) |> Enum.sum()
    # One attempt per (run, step) is the ideal, so the denominator is attempts
    # and the numerator is how many times a step was reached at all. Using the
    # count of distinct steps instead made every additional run lower the rate.
    step_reached = steps |> Enum.map(&(&1["runs"] || 0)) |> Enum.sum()

    runs = get_in(summary, ["runs", "total"]) || 0
    done = get_in(summary, ["runs", "by_status", "done"]) || 0

    %{}
    |> put_rate("gate_pass_rate", gate_passed, gate_total)
    |> put_rate("gate_availability", gate_total - gate_unavailable, gate_total)
    |> put_rate("run_completion_rate", done, runs)
    |> put_rate("step_first_try_rate", step_reached, step_attempts)
  end

  defp put_rate(map, _name, _numerator, 0), do: map

  defp put_rate(map, name, numerator, denominator),
    do: Map.put(map, name, numerator / denominator)

  @doc """
  The change from one collection to another, as the metric map the evolution
  gates read: positive is better.

  A metric present in only one of the two is **omitted**, not treated as zero.
  A metric that had no observations before an experiment and some after has not
  improved; it has started being measured, and reporting that as a gain is how
  an experiment takes credit for instrumentation.
  """
  @spec delta(summary(), summary()) :: %{String.t() => float()}
  def delta(before, aft) do
    a = metrics(before)
    b = metrics(aft)

    for {name, value} <- b, Map.has_key?(a, name), into: %{} do
      {name, value - a[name]}
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp after?(_timestamp, nil), do: true
  defp after?(nil, _since), do: false
  defp after?(timestamp, since), do: timestamp >= since

  # The command that installs a gate's tool is the project's (`tooling` in
  # `.agents/registry/project.json`).
  defp install_hint do
    case Noetic.Harness.Project.tooling("install_gates") do
      nil -> " —"
      command -> " — `#{command}` —"
    end
  end
end
