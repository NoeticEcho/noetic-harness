defmodule Noetic.Harness.Evolution do
  @moduledoc """
  Candidates, lineage, and the promotion gate that a number alone cannot open.

  ## What this module is for

  The harness is itself evolvable: prompts, role topology, routing signals,
  skills, workflows, context strategy and evaluators are all artifacts that
  could be better. This module is the ledger for changing them — and, more
  importantly, the place where **a candidate cannot be promoted by the agent
  that proposed it, on the strength of the benchmark that selected it.**

  ## The rules that are enforced here rather than documented

  - `promotable?/1` requires *every* stage — sandbox, benchmark, holdout,
    transfer, anti-Goodhart, archive — to be present and passed. A missing stage
    is a refusal with the stage named, not a warning.
  - `holdout` and `anti_goodhart` must be marked `independent: true`. A holdout
    run by the candidate's author is not a holdout; it is a second benchmark.
  - `goodhart_signature?/1` reports a benchmark gain with a flat or negative
    **holdout or transfer**. That combination quarantines rather than promotes.
  - `unmeasured/1` refuses a set-keyed fitness value that no scoring run can be
    pointed at, and one whose recorded environments are not the set's currently
    verified members. The three set keys are `Environments.sets/0`, read rather
    than repeated: they used to be literal strings here and agreed with the
    environment sets by coincidence.
  - Fitness is a map, not a number. There is no `score/1` in this module and
    that is deliberate: a scalar is something to optimise, and something will
    optimise it.
  - Nothing is deleted. A quarantined or rejected candidate is archived with its
    lineage, because the next working mutation frequently starts from one that
    failed on its own.

  ## What this module will not do

  It will not promote. `promotable?/1` answers a question; landing the change is
  a T4 action behind the `protected` gate with a human in it. An evolution run
  may *propose* a change to the constitution, trust levels, gates or the
  security policy, and may never land one.
  """

  alias Noetic.Harness.{Environments, Loader, Run}

  @required_stages ~w(sandbox benchmark holdout transfer anti_goodhart archive)
  # Held-out *sets* and independent *stages* were two lists that happened to
  # overlap: `transfer` is held out and was not in this one, so a self-scored
  # transfer recorded cleanly, printed success, and was then refused forever by
  # `promotable?/1` on a number the tool said it had taken. Found by an
  # independent review. The stages are now the sets plus `anti_goodhart`,
  # which is a stage and not a suite.
  @independent_stages Environments.held_out_sets() ++ ["anti_goodhart"]

  # A failure here closes the candidate. See `record_stage/3`: a held-out
  # evaluation that can be answered by another iteration on the same candidate
  # is not held out any more, it is a slow benchmark.
  @one_way_stages ~w(holdout anti_goodhart transfer)

  # Where the idea came from, not where the change is allowed to land. The six
  # are SoL-Pi's proposal families (arXiv:2609.20519 §2.2), which classified
  # ~150 directions without constraining any of their implementations.
  @families ~w(context progress tools delegation prompt_policy improvement_evaluation)

  @type candidate :: map()

  @doc "Candidates, newest first. `:archived` includes the archive."
  @spec list(keyword()) :: [candidate()]
  def list(opts \\ []) do
    dirs =
      if Keyword.get(opts, :archived, false),
        do: [candidates_dir(), archive_dir()],
        else: [candidates_dir()]

    dirs
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.json")))
    |> Enum.flat_map(fn path ->
      case Loader.load(path) do
        {:ok, candidate} -> [candidate]
        {:error, _} -> []
      end
    end)
    |> Enum.sort_by(& &1["created_at"], :desc)
  end

  @doc "One candidate by id, from either directory."
  @spec fetch(String.t()) :: {:ok, candidate()} | :error
  def fetch(id) do
    case Enum.find(list(archived: true), &(&1["id"] == id)) do
      nil -> :error
      candidate -> {:ok, candidate}
    end
  end

  @doc "The proposal families an idea may be classified under."
  @spec families() :: [String.t()]
  def families, do: @families

  @doc """
  Propose a candidate.

  Required: `:target` (`%{kind:, ref:}`), `:hypothesis` with `weakness`,
  `change` and `disconfirming_evidence`, `:created_by`, `:family` (one of
  `families/0`) and `:metrics`.

  The disconfirming evidence is required because a hypothesis that nothing
  could refute is a preference.

  `:application` is optional here and required by `Noetic.Harness.Scoring`:
  `%{kind: "git_ref", ref: <sha>, baseline: <sha>}`, the two commits a scoring
  run checks out. A candidate without one can be proposed and reasoned about
  and cannot be measured.

  `:metrics` is `%{capability: [%{name:, tolerance:}], efficiency: [name]}` and
  is **frozen** here: `record_stage/3` will not change it. Capability metrics
  say what must not get worse and by how much it may move first; efficiency
  metrics say what the change is *for*. Declaring them afterwards, or moving a
  tolerance once a result is in, is the failure mode the whole ledger exists to
  prevent — the edit arrives looking like a result.
  """
  @spec propose(map()) :: {:ok, Path.t()} | {:error, String.t()}
  def propose(attrs) do
    with :ok <- check_target(attrs[:target]),
         :ok <- check_hypothesis(attrs[:hypothesis]),
         :ok <- check_author(attrs[:created_by]),
         :ok <- check_family(attrs[:family]),
         {:ok, metrics} <- check_metrics(attrs[:metrics]) do
      now = DateTime.utc_now()
      id = attrs[:id] || build_id(now, attrs[:target])
      path = Path.join(candidates_dir(), "#{id}.json")

      if File.exists?(path) do
        {:error, "#{id} already exists"}
      else
        candidate = %{
          "id" => id,
          "target" => stringify(attrs[:target]),
          "hypothesis" => stringify(attrs[:hypothesis]),
          "created_by" => attrs[:created_by],
          "created_at" => DateTime.to_iso8601(now),
          "family" => to_string(attrs[:family]),
          # The run this candidate was proposed in. `current_run/0` takes it
          # from the ledger; `attrs[:run]` is how a caller supplies one, and
          # saying that field did not exist was this comment's first version.
          # It is what `held_out_by_its_own_run/1` compares a scoring run
          # against, and that check requires the run to *exist*, so a supplied
          # id has to name a file in `.agents/runs/` that a commit records.
          "run" => attrs[:run] || current_run(),
          # How to make this candidate *present* in a working tree, so that it
          # can be run rather than described. `target` is a label and a label
          # cannot be checked out.
          "application" => attrs[:application] && stringify(attrs[:application]),
          # Frozen. Nothing downstream may rewrite this key.
          "metrics" => metrics,
          "lineage" => %{
            "parents" => attrs[:parents] || [],
            "generation" => generation(attrs[:parents] || [])
          },
          "stages" => %{},
          "fitness" => %{},
          # Empty rather than absent, because the shape is the point: a
          # candidate with a benchmark number and an empty provenance map is
          # visibly a candidate whose number nobody measured.
          "fitness_provenance" => %{},
          "status" => "proposed"
        }

        File.mkdir_p!(candidates_dir())
        File.write!(path, Loader.pretty!(candidate))
        {:ok, path}
      end
    end
  end

  @doc """
  Record a stage result.

  `independent` says whether the runner is someone other than the candidate's
  author. For `holdout` and `anti_goodhart` it must be true, and recording one
  of those as non-independent is refused rather than recorded with a caveat —
  a caveat would be read as a pass.

  **A failed `holdout`, `anti_goodhart` or `transfer` closes the candidate.**
  Its status becomes `rejected` and no further stage may be recorded against
  it. To try again, propose a new candidate naming this one as a parent: the
  failure then stays in the lineage rather than being iterated out of it. A
  held-out evaluation that a candidate can answer with another round is not
  held out — it has entered the search loop and become a slow benchmark, which
  is the mechanism by which an evolved harness ends up excellent at exactly the
  tasks used to evolve it.

  The frozen `metrics` are not writable here. A `:metrics` key in `result` is
  refused rather than ignored, because silently dropping it would let the
  caller believe the tolerance had moved.

  **Only a live candidate.** A candidate in the archive is refused, and so is
  a live one whose archive file exists, as `archive/3` refuses them. This
  used to find the candidate in either directory, so a stage could be written
  into a candidate archived as `promoted`, setting it back to `running`
  inside the archive. How a candidate ended is its record.
  """
  @spec record_stage(String.t(), String.t(), map()) :: {:ok, Path.t()} | {:error, String.t()}
  def record_stage(id, stage, result) do
    with {:ok, path} <- live_path(id),
         :ok <- refuse_archived(id, Path.join(archive_dir(), Path.basename(path))),
         {:ok, candidate} <- Loader.load(path),
         :ok <- check_stage(stage),
         :ok <- check_open(candidate),
         :ok <- check_metrics_untouched(result),
         :ok <- check_independence(stage, result, candidate) do
      outcome = to_string(result[:outcome] || result["outcome"] || "failed")

      entry = %{
        "run_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "by" => result[:by] || result["by"],
        "outcome" => outcome,
        "evidence" => result[:evidence] || result["evidence"] || [],
        "independent" => !!(result[:independent] || result["independent"])
      }

      status =
        if stage in @one_way_stages and outcome != "passed",
          do: "rejected",
          else: "running"

      updated =
        candidate
        |> update_in(["stages"], &Map.put(&1, stage, entry))
        |> Map.put("status", status)
        |> merge_fitness(result)

      updated =
        if status == "rejected",
          do: Map.put(updated, "rejected_at", "#{stage}: #{outcome}"),
          else: updated

      File.write!(path, Loader.pretty!(updated))
      {:ok, path}
    end
  end

  @doc """
  The two acceptance gates, in order.

  1. every declared capability metric is within its declared tolerance;
  2. at least one declared efficiency metric improved.

  Returns `:ok` or `{:error, [reason]}`. A candidate that broke nothing and
  improved nothing fails the second gate: it is not a candidate, it is a diff.

  Metric values are read from `fitness`, keyed by metric name, as **deltas** —
  positive is better for efficiency, and for capability a delta below
  `-tolerance` is a regression. A metric with no recorded value is a failure of
  the first gate, not a pass: an unmeasured capability is not an unharmed one.
  """
  @spec gates(candidate()) :: :ok | {:error, [String.t()]}
  def gates(candidate) do
    fitness = candidate["fitness"] || %{}
    metrics = candidate["metrics"] || %{}
    capability = metrics["capability"] || []
    efficiency = metrics["efficiency"] || []

    capability_failures =
      Enum.flat_map(capability, fn metric ->
        name = metric["name"]
        tolerance = metric["tolerance"] || 0

        case fitness[name] do
          nil ->
            ["capability metric #{name} was declared and never measured"]

          value when is_number(value) ->
            if value < -abs(tolerance),
              do: ["capability metric #{name} moved #{value}, past its tolerance of #{tolerance}"],
              else: []

          other ->
            ["capability metric #{name} is #{inspect(other)}, which is not a number"]
        end
      end)

    efficiency_gain =
      Enum.any?(efficiency, fn name ->
        is_number(fitness[name]) and fitness[name] > 0
      end)

    efficiency_failure =
      cond do
        efficiency == [] ->
          ["no efficiency metric was declared, so nothing says what this is for"]

        efficiency_gain ->
          []

        true ->
          ["no declared efficiency metric improved: #{Enum.join(efficiency, ", ")}"]
      end

    case capability_failures ++ efficiency_failure do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  end

  @doc """
  The nondominated candidates: those no other candidate beats on every metric.

  Deliberately not a ranking. There is no scalar score anywhere in this module,
  because a candidate better at three things and worse at one has produced
  information, and collapsing it into a number discards that information to
  make the decision feel easier. This returns the set a human chooses from.

  Candidates are compared only on metric names they both recorded; one that
  shares no measured metric with another cannot dominate it or be dominated.

  **A set-keyed value that `unmeasured/1` refuses does not count here either.**
  An independent review found this hole: `promotable?/1` was guarded and this
  was not, so a candidate with a hand-typed `benchmark` could *eliminate* a
  candidate whose benchmark had been measured — deleting a real result from
  the shortlist a human reads, one layer above the gate, with no `--check` in
  that path to refuse it.
  """
  @spec nondominated([candidate()]) :: [candidate()]
  def nondominated(candidates) do
    comparable = Map.new(candidates, &{&1["id"], comparable_fitness(&1)})

    Enum.reject(candidates, fn candidate ->
      Enum.any?(candidates, &dominates?(&1, candidate, comparable))
    end)
  end

  # Everything measured, minus every set-keyed value this candidate cannot
  # account for. Computed once per candidate rather than per pair, because
  # `unmeasured/1` reads the environment suite off disk.
  defp comparable_fitness(candidate) do
    refused =
      candidate
      |> unmeasured()
      |> then(fn reasons ->
        Enum.filter(set_keys(), fn key ->
          Enum.any?(reasons, &String.contains?(&1, key))
        end)
      end)

    (candidate["fitness"] || %{})
    |> Enum.filter(fn {name, value} -> is_number(value) and name not in refused end)
    |> Map.new()
  end

  defp dominates?(a, b, comparable) do
    a["id"] != b["id"] and
      (fn ->
         fa = Map.get(comparable, a["id"], %{})
         fb = Map.get(comparable, b["id"], %{})

         shared = for {name, va} <- fa, is_number(fb[name]), do: {va, fb[name]}

         shared != [] and
           Enum.all?(shared, fn {va, vb} -> va >= vb end) and
           Enum.any?(shared, fn {va, vb} -> va > vb end)
       end).()
  end

  @doc """
  Whether a candidate may be promoted, and why not when it may not.

  Returns `:ok` or `{:error, [reason]}`. The reasons are the specific missing
  or failed stages — a promotion refused with "not ready" teaches nobody
  anything.
  """
  @spec promotable?(candidate()) :: :ok | {:error, [String.t()]}
  def promotable?(candidate) do
    stages = candidate["stages"] || %{}

    missing =
      for stage <- @required_stages, not Map.has_key?(stages, stage) do
        "#{stage} has not been run"
      end

    failed =
      for {stage, entry} <- stages, entry["outcome"] != "passed" do
        "#{stage} outcome is #{entry["outcome"]}, not passed"
      end

    dependent =
      for stage <- @independent_stages,
          entry = stages[stage],
          entry && entry["independent"] != true do
        "#{stage} was not run independently of the candidate's author, so it does not count as one"
      end

    laundered = held_out_by_its_own_run(candidate)

    goodhart =
      case goodhart_signature(candidate) do
        [] ->
          []

        flat ->
          [
            "#{Environments.motivating_set()} improved while #{Enum.join(flat, " and ")} did " <>
              "not — quarantine, do not promote"
          ]
      end

    rejected =
      case candidate["status"] do
        "rejected" ->
          [
            "this candidate was closed at #{candidate["rejected_at"]}; a new attempt is a new candidate"
          ]

        _ ->
          []
      end

    gated =
      case gates(candidate) do
        :ok -> []
        {:error, reasons} -> reasons
      end

    case rejected ++
           protected_refusal(candidate) ++
           missing ++
           failed ++
           dependent ++
           laundered ++
           goodhart ++
           gated ++
           unmeasured(candidate) do
      [] -> :ok
      reasons -> {:error, Enum.sort(reasons)}
    end
  end

  @doc """
  The three fitness keys the anti-Goodhart machinery rests on.

  They are `Environments.sets/0`, read rather than repeated. `goodhart_
  signature?/1` used the literal strings `"benchmark"` and `"holdout"` and they
  agreed with the environment sets by coincidence; nothing said they were the
  same vocabulary, and a set renamed on one side would have silently stopped
  feeding the gate on the other.
  """
  @spec set_keys() :: [String.t()]
  def set_keys, do: Environments.sets()

  @doc """
  Held-out measurements that the candidate's own run produced.

  `holdout` and `anti_goodhart` must be independent of the candidate's author,
  and until now that was `by != created_by` — two strings the same process
  wrote, and answerable by typing a different name. After dispatch both are
  written by the same loop, so the check was about to stop meaning anything at
  exactly the moment it started mattering a thousand times a day.

  What is harder to rename is the ledger. A candidate records the run it was
  proposed in; a scoring run records its own id in `fitness_provenance`; and
  `Run.ancestor?/2` walks `parent_run`. So a held-out number produced **by the
  candidate's own run, or by anything that run dispatched**, is refused.

  Both ids are still fields in a file somebody can edit, and saying otherwise
  is the thing this docstring did until an independent review read it: `run`
  is written from the ledger by `propose/1` and is a *claim* afterwards. What
  the check buys is the same thing `unmeasured/1`'s `Run.exists?/1` buys — both
  ids must resolve to files in `.agents/runs/`, so a candidate that says it was
  proposed elsewhere has to name a run that exists and that
  `noetic-harness run --status` will print. Forgery becomes a trace in the ledger
  instead of an unfalsifiable claim.

  Two residuals, stated rather than closed. A human who starts two unrelated
  runs by hand is the author of both and nothing here detects it; and an author
  who edits `run` to point at somebody else's real run defeats the walk. `by`
  is self-asserted and an attested identity is an earlier change. What this
  closes is the *automatic* path — one loop proposing and scoring — which is
  the one that will actually be taken a thousand times a day.
  """
  @spec held_out_by_its_own_run(candidate()) :: [String.t()]
  def held_out_by_its_own_run(candidate) do
    provenance = candidate["fitness_provenance"]
    measured = is_map(provenance) and Enum.any?(Environments.held_out_sets(), &provenance[&1])

    case candidate["run"] do
      own when is_binary(own) and own != "" ->
        own = String.trim(own)

        cond do
          own == "" and measured -> [no_run()]
          own == "" -> []
          measured and not Run.exists?(own) -> [no_such_run(own)]
          true -> scored_by(own, provenance)
        end

      # **Fail closed.** A candidate with no run is not a candidate nobody can
      # suspect; it is a candidate nobody can check. `current_run/0` answers
      # `nil` whenever `Run.current/0` does not resolve — including when two
      # sessions have runs open, which this repository says is normal — so "no
      # run" was a permanent exemption reachable by accident, and `attrs[:run]`
      # made it reachable on purpose. Found by an independent review, which
      # promoted a self-scored candidate by deleting one field.
      _ when measured ->
        [no_run()]

      _ ->
        []
    end
  end

  defp scored_by(own, provenance) do
    for key <- Environments.held_out_sets(),
        record = provenance[key],
        is_map(record),
        is_binary(record["run"]),
        Run.ancestor?(own, record["run"]) do
      "fitness.#{key} was measured by #{record["run"]}, which is #{own} or was dispatched " <>
        "by it — the candidate's own run. A held-out set measured by the thing being " <>
        "promoted is not held out (constitution §23)"
    end
  end

  defp no_run do
    "this candidate carries held-out measurements and does not record the run it was " <>
      "proposed in, so independence cannot be established. A candidate proposed while " <>
      "another session had a run open gets `run: nil`; propose it again from a run of " <>
      "its own"
  end

  defp no_such_run(own) do
    "this candidate says it was proposed in run #{inspect(own)}, and there is no such run " <>
      "in the ledger. Independence is established by walking that run's parents, so a run " <>
      "nobody can open establishes nothing"
  end

  @doc """
  The Goodhart signature: the benchmark moved and a held-out set did not.

  Reads the set-keyed deltas. **Both** `holdout` and `transfer` count: the
  pipeline requires a transfer stage and this function could not see it, so a
  candidate could pass a transfer whose number never entered a gate. When a
  pair is absent the answer is `false` for that pair — this function reports a
  signature it can see, and the missing-stage check in `promotable?/1` covers
  the rest.
  """
  @spec goodhart_signature?(candidate()) :: boolean()
  def goodhart_signature?(candidate), do: goodhart_signature(candidate) != []

  @doc """
  Which held-out sets are flat beside a benchmark gain.

  The boolean was not enough to write an honest refusal with: `promotable?/1`
  said "the benchmark improved while the holdout did not" whatever had actually
  fired, so a candidate whose holdout gained `+0.5` and whose transfer sat at
  `0.0` was refused with a sentence a human could check and find false — and
  would then conclude the gate was broken. Found by an independent review.
  """
  @spec goodhart_signature(candidate()) :: [String.t()]
  def goodhart_signature(candidate) do
    fitness = candidate["fitness"] || %{}
    benchmark = fitness[Environments.motivating_set()]

    if is_number(benchmark) and benchmark > 0 do
      Enum.filter(Environments.held_out_sets(), fn held ->
        is_number(fitness[held]) and fitness[held] <= 0
      end)
    else
      []
    end
  end

  @doc """
  Set-keyed fitness values that nothing can point at a run for.

  `benchmark`, `holdout` and `transfer` are the three numbers the promotion
  gate rests on, and a number typed on a command line is indistinguishable in
  the file from a number produced by running a candidate against
  `Environments.suite/1`. So the file has to carry where it came from:

      "fitness_provenance": {
        "benchmark": {"run": "<run id>", "at": "...", "environments": [...]}
      }

  Two things are refused, and the second is the one that matters later. A value
  with no provenance at all was typed, not measured. A value whose recorded
  environments are not **exactly** the currently verified members of that set
  was measured over a different suite — either a member has since stopped
  verifying, which `validate/0` already treats as a suite silently shrinking,
  or one was added and the number is a rate over a prefix. A rate over a prefix
  of the suite is a different quantity wearing the same name.

  Only set-keyed values are governed this way. Capability and efficiency
  metrics are declared per candidate and measured however that candidate's
  hypothesis says; these three are what the anti-Goodhart machinery rests on.

  This check lands before anything writes such a number, on
  purpose: a gate added after the thing it gates is a gate that has already
  been passed around once.
  """
  @spec unmeasured(candidate()) :: [String.t()]
  def unmeasured(candidate) do
    fitness = candidate["fitness"]
    provenance = candidate["fitness_provenance"]

    cond do
      not is_map(fitness) and not is_nil(fitness) ->
        ["fitness is #{inspect(fitness)}, which is not a map of measurements"]

      not is_map(provenance) and not is_nil(provenance) ->
        # A non-map here used to raise out of `Access.get/3` — and
        # `Evolution.validate/0` is a `noetic-harness validate` check, so one
        # malformed candidate file took the whole validation gate down with a
        # `FunctionClauseError` instead of reporting it. It fails closed rather
        # than open, which is why this is robustness and not a bypass, but a
        # gate that crashes is a gate nobody can read. Found by an independent
        # review.
        ["fitness_provenance is #{inspect(provenance)}, which is not a record of what was run"]

      true ->
        set_keys()
        |> Enum.filter(&Map.has_key?(fitness || %{}, &1))
        |> Enum.flat_map(&reasons_for(&1, (fitness || %{})[&1], (provenance || %{})[&1]))
    end
  end

  # A set key that is present and is not a number is not governed by the
  # provenance check and is not measured either: `gates/1` skips it,
  # `goodhart_signature/1` skips it, and `--show` prints it. The string "0.4"
  # displayed a benchmark gain while both anti-Goodhart mechanisms looked away.
  defp reasons_for(key, value, _provenance) when not is_number(value) do
    ["fitness.#{key} is #{inspect(value)}, which is not a number and measures nothing"]
  end

  defp reasons_for(key, _value, nil) do
    [
      "fitness.#{key} is #{key} and nothing says where it came from: it was typed, not " <>
        "measured. `fitness_provenance.#{key}` is what a scoring run writes."
    ]
  end

  defp reasons_for(key, _value, record) when is_map(record) do
    named(key, record["run"]) ++
      listed(key, record["environments"]) ++ suite_reasons(key, record)
  end

  defp reasons_for(key, _value, other) do
    ["fitness_provenance.#{key} is #{inspect(other)}, which is not a record of a run"]
  end

  # The run has to *exist*. An independent review of the first version forged a
  # promotable candidate in which every number and every provenance field was
  # typed by hand — `"run": "run-0000-00-00-wf-000-does-not-exist"` — and
  # `--check` exited 0, because the check asked only that the string was not
  # empty. The environment list it also has to match is public and sorted and
  # readable with `ls`, so the whole gate raised the cost of forgery from
  # typing one number to typing one number and copying three filenames.
  #
  # What this buys, stated precisely so that nobody reads more into it: a run
  # id that resolves is a file in `.agents/runs/` that a commit records and
  # that `noetic-harness run --status` will print. It is not proof that the run
  # scored anything; a person can still write that file. It makes the forgery
  # *leave a trace in the ledger*, which is the difference between a lie and an
  # unfalsifiable claim. The thing that would make it proof is an attested
  # identity.
  defp named(key, run) when is_binary(run) do
    trimmed = String.trim(run)

    cond do
      trimmed == "" ->
        ["fitness_provenance.#{key} names no run, so there is nothing to go and read"]

      not Run.exists?(trimmed) ->
        [
          "fitness_provenance.#{key} names run #{inspect(trimmed)}, and there is no such run " <>
            "in the ledger. A number whose run cannot be opened is a number nobody can check."
        ]

      true ->
        []
    end
  end

  defp named(key, _run) do
    ["fitness_provenance.#{key} names no run, so there is nothing to go and read"]
  end

  # `List.wrap/1` turned a bare string into a one-element list and an integer
  # into a reason that read "measured over 42". The schema says array-of-string
  # and `harness.validate` now checks committed candidates against it;
  # this stays because it judges a candidate in memory, before
  # anything has validated the file it came from.
  defp listed(key, environments) when is_list(environments) do
    case Enum.reject(environments, &is_binary/1) do
      [] -> []
      bad -> ["fitness_provenance.#{key}.environments contains #{inspect(bad)}, not ids"]
    end
  end

  defp listed(key, environments) do
    [
      "fitness_provenance.#{key}.environments is #{inspect(environments)}, which is not a list " <>
        "of environment ids"
    ]
  end

  defp suite_reasons(key, record) do
    scored = record["environments"] |> List.wrap() |> Enum.filter(&is_binary/1) |> MapSet.new()
    current = key |> Environments.suite() |> MapSet.new(& &1["id"])

    cond do
      # An empty suite made both differences empty and the guard a no-op — and
      # a set empties by its members becoming `unavailable`, which is exactly
      # when a number about it is worth the least. The transfer set has two
      # members. Found by an independent review.
      MapSet.size(current) == 0 ->
        [
          "the #{key} set has no currently verified members, so there was nothing to measure " <>
            "over and fitness.#{key} is about an empty suite"
        ]

      true ->
        gone = scored |> MapSet.difference(current) |> Enum.sort()
        added = current |> MapSet.difference(scored) |> Enum.sort()

        Enum.reject(
          [
            gone != [] &&
              "fitness.#{key} was measured over #{Enum.join(gone, ", ")}, which #{verb(gone)} " <>
                "no longer a verified member of the #{key} set — the number is about a suite " <>
                "that no longer exists",
            added != [] &&
              "fitness.#{key} was measured without #{Enum.join(added, ", ")}, which " <>
                "#{verb(added)} in the #{key} set now — a rate over part of a suite is not " <>
                "that suite's rate"
          ],
          &(&1 == false)
        )
    end
  end

  defp verb([_]), do: "is"
  defp verb(_), do: "are"

  @doc """
  Move a candidate to the archive with a reason.

  Archiving is how a candidate stops being live. It is not how it stops having
  existed: the file keeps its stages, its fitness vector and its lineage, so a
  later mutation can start from it.

  **It moves a live candidate, once.** A candidate already in the archive is
  refused, and so is a live one whose archive file exists. This used to look
  the candidate up in either directory, write `archive/<id>.json` and remove
  the path it had read — for an archived candidate the same file, so the
  candidate was gone and the call returned `{:ok, path}` to where it had been.
  How a candidate ended is the record; a second archiving
  would rewrite it, and a new attempt is a new candidate naming this one as
  a parent.

  **`"promoted"` is asked of `promotable?/1` first.** The status is the
  ledger's statement that the candidate earned its promotion, and this was
  the one call that could make it of any candidate, a rejected one included,
  leaving `validate/0` to report it afterwards if it ran. A refusal names
  every reason, as `--check` does.
  """
  @spec archive(String.t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def archive(id, status, reason) do
    with {:ok, path} <- live_path(id),
         destination = Path.join(archive_dir(), Path.basename(path)),
         :ok <- refuse_archived(id, destination),
         {:ok, candidate} <- Loader.load(path),
         :ok <- check_relabel(id, status, candidate) do
      updated =
        candidate
        |> Map.put("status", status)
        |> Map.put("quarantine_reason", reason)

      File.mkdir_p!(archive_dir())
      File.write!(destination, Loader.pretty!(updated))

      case File.rm(path) do
        :ok ->
          {:ok, destination}

        {:error, why} ->
          {:error,
           "#{id} was written to #{destination} and its live file could not be removed " <>
             "(#{inspect(why)}), so it is in both directories"}
      end
    end
  end

  @doc "Ancestors of a candidate, oldest first."
  @spec lineage(String.t()) :: [candidate()]
  def lineage(id) do
    case fetch(id) do
      :error ->
        []

      {:ok, candidate} ->
        parents = get_in(candidate, ["lineage", "parents"]) || []
        Enum.flat_map(parents, &(lineage(&1) ++ [candidate_or_stub(&1)])) ++ [candidate]
    end
  end

  @doc "Structural problems across the ledger."
  @spec validate() :: [String.t()]
  def validate do
    candidates = list(archived: true)
    ids = MapSet.new(candidates, & &1["id"])

    dangling =
      for candidate <- candidates,
          parent <- get_in(candidate, ["lineage", "parents"]) || [],
          not MapSet.member?(ids, parent) do
        "evolution: #{candidate["id"]} names parent #{parent}, which is not in the ledger — lineage is broken"
      end

    promoted_without_evidence =
      for candidate <- candidates,
          candidate["status"] == "promoted",
          {:error, reasons} <- [promotable?(candidate)] do
        "evolution: #{candidate["id"]} is marked promoted but #{Enum.join(reasons, "; ")}"
      end

    dangling ++ promoted_without_evidence
  end

  # ---- internals -----------------------------------------------------------

  defp candidate_or_stub(id) do
    case fetch(id) do
      {:ok, candidate} -> candidate
      :error -> %{"id" => id, "status" => "missing"}
    end
  end

  # Only `candidates/`. The two calls that write a candidate, `archive/3` and
  # `record_stage/3`, resolved it from either directory, and each was a
  # defect: one rewrote and deleted an archived candidate, the
  # other wrote a stage into one. `fetch/1` still reads both,
  # because reading the archive is what the archive is for.
  defp live_path(id) do
    live = Path.join(candidates_dir(), "#{id}.json")

    cond do
      File.exists?(live) -> {:ok, live}
      File.exists?(Path.join(archive_dir(), "#{id}.json")) -> {:error, already_archived(id)}
      true -> {:error, "no candidate #{id}"}
    end
  end

  defp refuse_archived(id, destination) do
    if File.exists?(destination), do: {:error, already_archived(id)}, else: :ok
  end

  defp already_archived(id) do
    "#{id} is already archived, and the archive is not rewritten: how a candidate ended is " <>
      "its record. A new attempt is a new candidate naming #{id} as a parent"
  end

  defp check_relabel(id, "promoted", candidate) do
    case promotable?(candidate) do
      :ok ->
        :ok

      {:error, reasons} ->
        {:error,
         "#{id} is not archived as promoted, because it is not promotable: " <>
           Enum.join(reasons, "; ")}
    end
  end

  defp check_relabel(_id, _status, _candidate), do: :ok

  # What a cluster shape implies about where the change belongs, what family of
  # change it is, and which cost it is supposed to reduce. 
  #
  # A table rather than inference, and deliberately: the bead's own line is
  # that this "must not invent a hypothesis for a cluster it cannot name a
  # change for", and a mapping that guesses is a mapping that invents. A shape
  # missing from here is refused by name, which is a one-line addition with a
  # reason rather than a candidate nobody can evaluate.
  @from_cluster %{
    "routing.corrected" => %{
      kind: "signals",
      ref: ".agents/registry/signals.json",
      family: "delegation",
      efficiency: "output_tokens_per_bead",
      capability: [{"run_completion_rate", 0.0}, {"step_first_try_rate", 0.05}]
    },
    "gate.unavailable" => %{
      kind: "gates_policy",
      ref: ".agents/policies/gates.json",
      family: "tools",
      efficiency: "tool_calls_per_bead",
      capability: [{"gate_availability", 0.0}, {"gate_pass_rate", 0.05}]
    },
    "gate.failed" => %{
      kind: "gates_policy",
      ref: ".agents/policies/gates.json",
      family: "tools",
      efficiency: "tool_calls_per_bead",
      capability: [{"gate_pass_rate", 0.0}]
    },
    "lane.partial" => %{
      kind: "gates_policy",
      ref: ".agents/policies/gates.json",
      family: "tools",
      efficiency: "tool_calls_per_bead",
      capability: [{"gate_availability", 0.0}]
    },
    "step.uncertain" => %{
      kind: "capability",
      ref: ".agents/registry/capabilities.json",
      family: "context",
      efficiency: "attempts_per_step",
      capability: [{"run_completion_rate", 0.0}, {"gate_pass_rate", 0.05}]
    },
    "step.needs_review" => %{
      kind: "capability",
      ref: ".agents/registry/capabilities.json",
      family: "context",
      efficiency: "attempts_per_step",
      capability: [{"run_completion_rate", 0.0}]
    },
    "step.failed" => %{
      kind: "capability",
      ref: ".agents/registry/capabilities.json",
      family: "context",
      efficiency: "attempts_per_step",
      capability: [{"run_completion_rate", 0.0}]
    },
    "step.blocked" => %{
      kind: "capability",
      ref: ".agents/registry/capabilities.json",
      family: "context",
      efficiency: "attempts_per_step",
      capability: [{"run_completion_rate", 0.0}]
    },
    "run.abandoned" => %{
      kind: "signals",
      ref: ".agents/registry/signals.json",
      family: "delegation",
      efficiency: "output_tokens_per_bead",
      capability: [{"run_completion_rate", 0.0}]
    },
    "memory.scope" => %{
      kind: "skill",
      ref: ".agents/skills/",
      family: "context",
      efficiency: "output_tokens_per_bead",
      capability: [{"step_first_try_rate", 0.0}]
    }
  }

  @doc """
  Turn a weakness cluster into a candidate with a hypothesis.

  Earlier changes and design notes said what was missing: "nothing
  *proposes* candidates". `propose/1` existed, scoring existed, the promotion
  gate existed. The absent link was the one between a cluster that survived the
  population floor and a candidate with a hypothesis.

  Three refusals, each of which is the bead holding a line:

    * **A cluster that names no change is refused.** An earlier change gave every
      cluster a `change` field and marked the ones that could not fill it in;
      this is what that was for. A candidate with a vague change is a candidate
      that will be scored against a vague measure.
    * **A shape with no mapping is refused by name.** Inferring a target from a
      shape nobody wrote down is how a candidate gets a hypothesis its author
      never held.
    * **An efficiency metric with no baseline is refused.** An earlier change froze
      the baseline; a candidate whose efficiency metric was not in it cannot
      show an improvement against it, and `gates/1` would read the absence as
      "no efficiency gain" rather than as "not measured".

  What it does *not* refuse is a target under constitution §23 — proposing a
  change to the trust model is allowed and useful. `promotable?/1` is what
  refuses to land it.
  """
  @spec from_cluster(map(), keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  def from_cluster(cluster, opts \\ []) do
    with :ok <- check_change(cluster),
         {:ok, mapping} <- check_shape(cluster),
         {:ok, efficiency} <- check_baseline(mapping.efficiency) do
      propose(
        target: %{kind: mapping.kind, ref: mapping.ref},
        family: mapping.family,
        created_by: opts[:created_by] || "harness evolution --from-cluster",
        run: opts[:run],
        hypothesis: %{
          weakness:
            "#{cluster["shape"]} on #{cluster["subject"]}: #{cluster["count"]} of " <>
              "#{cluster["of"]}. #{cluster["reading"]}",
          change: cluster["change"],
          disconfirming_evidence: disconfirming(cluster, efficiency)
        },
        metrics: %{
          capability:
            Enum.map(mapping.capability, fn {name, tolerance} ->
              %{name: name, tolerance: tolerance}
            end),
          efficiency: [efficiency]
        }
      )
    end
  end

  defp check_change(%{"actionable" => true, "change" => change})
       when is_binary(change) and change != "",
       do: :ok

  defp check_change(cluster) do
    {:error,
     "#{cluster["shape"]} on #{cluster["subject"]} names no change, so there is nothing to " <>
       "propose. It passed the population floor and taught nothing — see " <>
       "`.agents/policies/evolution.md`, \"a cluster shape must name the change it implies\"."}
  end

  defp check_shape(cluster) do
    case Map.fetch(@from_cluster, cluster["shape"]) do
      {:ok, mapping} ->
        {:ok, mapping}

      :error ->
        {:error,
         "no mapping for the shape #{cluster["shape"]}. Add one to " <>
           "`Noetic.Harness.Evolution`'s `@from_cluster` saying which artifact such a cluster " <>
           "implies a change to, which family of change it is, and which cost it reduces. " <>
           "Guessing that from the shape is how a candidate gets a hypothesis nobody held."}
    end
  end

  defp check_baseline(name) do
    case Noetic.Harness.Telemetry.baseline() do
      {:ok, %{"metrics" => metrics}} when is_map_key(metrics, name) ->
        {:ok, name}

      {:ok, _no_such_metric} ->
        {:error,
         "#{name} has no value in `.agents/evolution/baseline.json`, so a candidate cannot " <>
           "show an improvement against it. Either the baseline predates the metric, or the " <>
           "metric had no denominator when it was taken."}

      :none ->
        {:error,
         "no baseline has been taken. `noetic-harness telemetry --baseline` takes it, once, and " <>
           "it has to exist before the first candidate or the first candidate's delta is " <>
           "measured against a number chosen after seeing it."}
    end
  end

  # What would have to keep happening for the change to be wrong. The cluster
  # not shrinking is the direct form; the efficiency metric's gaming question
  # is the indirect one, and it is the half people forget.
  defp disconfirming(cluster, efficiency) do
    gaming = Noetic.Harness.Telemetry.gaming_questions()[efficiency]

    "#{cluster["shape"]} on #{cluster["subject"]} stays at or above " <>
      "#{cluster["count"]} of a comparable population after the change lands. " <>
      "Separately, #{efficiency} improving while the capability metrics above move outside " <>
      "their tolerance means the cost fell for the wrong reason. " <> (gaming || "")
  end

  @protected_kinds ~w(constitution trust gate security policy)
  @protected_refs ~w(constitution.md trust_levels.json gates.json security.md)

  @doc """
  Artifacts an evolution run may **propose** a change to and may never land.

  Constitution §23 and `.agents/policies/evolution.md`: an evolution run may
  propose a change to the constitution, trust levels, gates or the security
  policy, and may never land one. This module's moduledoc has said so since it
  was written; an earlier change is where it became a check rather than a sentence,
  because that bead builds the thing that proposes candidates without a person
  in the loop.

  Proposing is deliberately still allowed. A harness that cannot say "the trust
  model is what is wrong here" is a harness that will keep proposing a
  workaround for it.
  """
  @spec protected_target?(map()) :: boolean()
  def protected_target?(candidate) do
    kind = get_in(candidate, ["target", "kind"]) || ""
    ref = get_in(candidate, ["target", "ref"]) || ""

    kind in @protected_kinds or Enum.any?(@protected_refs, &String.contains?(ref, &1))
  end

  defp protected_refusal(candidate) do
    if protected_target?(candidate) do
      [
        "target #{get_in(candidate, ["target", "ref"])} is the constitution, the trust " <>
          "levels, a gate or the security policy. An evolution run may propose a change to " <>
          "these and may never land one (constitution §23). This candidate is for a person " <>
          "to read, not for a gate to pass."
      ]
    else
      []
    end
  end

  defp check_target(%{kind: kind, ref: ref}) when is_binary(kind) and is_binary(ref), do: :ok

  defp check_target(%{"kind" => kind, "ref" => ref}) when is_binary(kind) and is_binary(ref),
    do: :ok

  defp check_target(_), do: {:error, "target must be %{kind: ..., ref: ...}"}

  defp check_hypothesis(hypothesis) when is_map(hypothesis) do
    required = ["weakness", "change", "disconfirming_evidence"]
    present = Map.new(hypothesis, fn {k, v} -> {to_string(k), v} end)

    case Enum.reject(required, &(present[&1] not in [nil, ""])) do
      [] ->
        :ok

      missing ->
        {:error,
         "hypothesis is missing #{Enum.join(missing, ", ")}. " <>
           "A hypothesis with no disconfirming evidence is a preference."}
    end
  end

  defp check_hypothesis(_), do: {:error, "hypothesis is required"}

  defp check_author(author) when is_binary(author) and author != "", do: :ok
  defp check_author(_), do: {:error, "created_by is required"}

  defp check_family(family) when is_binary(family) or is_atom(family) do
    if to_string(family) in @families do
      :ok
    else
      {:error, "family must be one of: #{Enum.join(@families, ", ")}"}
    end
  end

  defp check_family(_), do: {:error, "family is required, one of: #{Enum.join(@families, ", ")}"}

  # The metrics are the acceptance criteria, so they are validated hard and
  # frozen immediately. A candidate that declares no capability metric is
  # claiming nothing can get worse, which is the claim that most needs writing
  # down before the result is known.
  defp check_metrics(metrics) when is_map(metrics) do
    capability = metrics[:capability] || metrics["capability"] || []
    efficiency = metrics[:efficiency] || metrics["efficiency"] || []

    cond do
      capability == [] ->
        {:error,
         "metrics.capability is required: name what must not get worse, and the tolerance " <>
           "it may move within first. Declaring it afterwards is how a tolerance becomes a result."}

      efficiency == [] ->
        {:error, "metrics.efficiency is required: name what this change is for"}

      not Enum.all?(capability, &valid_capability_metric?/1) ->
        {:error, "each capability metric must be %{name: <string>, tolerance: <number>}"}

      true ->
        {:ok,
         %{
           "capability" =>
             Enum.map(capability, fn metric ->
               %{
                 "name" => to_string(metric[:name] || metric["name"]),
                 "tolerance" => metric[:tolerance] || metric["tolerance"]
               }
             end),
           "efficiency" => Enum.map(efficiency, &to_string/1)
         }}
    end
  end

  defp check_metrics(_),
    do:
      {:error,
       "metrics is required: %{capability: [%{name: ..., tolerance: ...}], efficiency: [...]}"}

  defp valid_capability_metric?(metric) when is_map(metric) do
    name = metric[:name] || metric["name"]
    tolerance = metric[:tolerance] || metric["tolerance"]
    is_binary(name) and name != "" and is_number(tolerance)
  end

  defp valid_capability_metric?(_), do: false

  defp check_open(%{"status" => "rejected"} = candidate) do
    {:error,
     "#{candidate["id"]} was closed at #{candidate["rejected_at"]}. Nothing more may be " <>
       "recorded against it: propose a new candidate naming this one as a parent, so the " <>
       "failure stays in the lineage instead of being iterated out of it."}
  end

  defp check_open(_), do: :ok

  defp check_metrics_untouched(result) do
    if result[:metrics] || result["metrics"] do
      {:error,
       "metrics are frozen at proposal and cannot be recorded with a stage result. " <>
         "If they were wrong, that is a new candidate, not a new tolerance."}
    else
      :ok
    end
  end

  defp check_stage(stage) when stage in @required_stages, do: :ok

  defp check_stage(stage),
    do: {:error, "unknown stage #{stage}; expected one of #{Enum.join(@required_stages, ", ")}"}

  defp check_independence(stage, result, candidate) when stage in @independent_stages do
    independent = !!(result[:independent] || result["independent"])
    by = result[:by] || result["by"]

    cond do
      not independent ->
        {:error,
         "#{stage} must be recorded as independent. A #{stage} run by the candidate's author " <>
           "is not a #{stage}."}

      by != nil and by == candidate["created_by"] ->
        {:error, "#{stage} was run by #{by}, who proposed this candidate"}

      true ->
        :ok
    end
  end

  defp check_independence(_stage, _result, _candidate), do: :ok

  defp merge_fitness(candidate, result) do
    candidate
    |> merge_map("fitness", result[:fitness] || result["fitness"])
    |> merge_map(
      "fitness_provenance",
      result[:fitness_provenance] || result["fitness_provenance"]
    )
  end

  # Provenance travels with the number it is about, through the same call, so
  # that there is no ordering in which a number is recorded and its provenance
  # is recorded later. A scoring run writes both or neither.
  defp merge_map(candidate, _key, nil), do: candidate

  defp merge_map(candidate, key, value) do
    Map.put(candidate, key, Map.merge(Map.get(candidate, key) || %{}, stringify(value)))
  end

  defp generation([]), do: 0

  defp generation(parents) do
    parents
    |> Enum.map(fn id ->
      case fetch(id) do
        {:ok, parent} -> get_in(parent, ["lineage", "generation"]) || 0
        :error -> 0
      end
    end)
    |> Enum.max()
    |> Kernel.+(1)
  end

  defp build_id(now, target) do
    date = now |> DateTime.to_date() |> Date.to_iso8601()
    kind = target[:kind] || target["kind"]
    ref = target[:ref] || target["ref"]

    slug =
      "#{kind}-#{ref}"
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 48)

    "cand-#{date}-#{slug}"
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(other), do: other

  defp current_run do
    case Run.current() do
      {:ok, run} -> run["id"]
      _ -> nil
    end
  end

  defp candidates_dir, do: Path.join(Noetic.Harness.agents_path("evolution"), "candidates")
  defp archive_dir, do: Path.join(Noetic.Harness.agents_path("evolution"), "archive")
end
