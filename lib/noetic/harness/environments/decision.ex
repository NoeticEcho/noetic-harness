defmodule Noetic.Harness.Environments.Decision do
  @moduledoc """
  Decision environments: a versioned question asked of labelled rows, scored
  by the environments evaluator rather than by a second one.

  The System One addendum proposed a benchmark of its own, with calibration,
  holdout and transfer partitions. Those already exist here: `Environments`
  holds tasks, assigns them to `benchmark`, `holdout` and `transfer` one way,
  retires them with a reason, and refuses to count one that has not been
  shown to discriminate. A second benchmark would have had to re-earn every
  one of those properties, and it would have been written by whoever was
  proposing the model. So a decision task is an environment with
  `verifier.kind: "decision"`, and this module is the part that differs.

  ## What "verified" means for a question

  A code environment is kept only if its test fails without the fix. The
  question's equivalent is **fails the answerers that should fail**. `verify/1`
  poses the environment to four answerers it builds from the labels, and keeps
  it only if each is judged correctly:

  | answerer | must | the rule it exercises |
  |---|---|---|
  | the labels, certain | pass | the environment can be passed at all |
  | the majority label, certain | fail | beat the majority baseline |
  | right except on a few rows, certain everywhere | fail | the confident-wrong ceiling |
  | right everywhere, at 0.5 | fail | the calibration ceiling |

  The third is the acceptance criterion the bead states — *a model that is
  confidently wrong fails rather than scoring well* — made into a check that
  runs: it is built to beat the baseline and stay under the ECE ceiling, so
  the confident-wrong rule is the only thing that can stop it. Remove that
  rule and every decision environment comes back `rejected`, which is the
  test.

  An environment whose rows all carry one label is `rejected` by the first
  line: nothing can beat a majority that is the whole population.

  ## What a score is

  `score/3` reads an answer per row — a `choice` and, optionally, the
  `probabilities` it came with — and passes when **all** of these hold:

    * accuracy above the majority label's, on these rows;
    * accuracy above the reference's, when one is given — the mechanism the
      model would replace, on the same rows (the epic's title is "if it can
      be shown to beat what is already here");
    * expected calibration error at or under `max_ece`;
    * at most `max_confident_wrong` of the rows answered wrongly with
      probability at or above `confident_at`.

  **An answer without probabilities is read as certain.** That is how a
  deterministic mechanism is scored: a regex that fires claims the class, and
  holding it to the same confident-wrong ceiling as a model is the point. A
  row with no answer counts as wrong; abstaining is the policy's to decide
  (the decision policy's), not the evaluator's to forgive.

  ## Replay

  The environment records the question's version and fingerprint and a hash of
  its rows' ids, labels and evidence. If any of them has changed, `verify/1`
  answers `unavailable` — the environment asks a question that is no longer
  the one on disk — and the remedy is a new environment, not a relabelled
  one: a holdout whose labels moved after a model was scored on it is no
  longer a holdout.
  """

  alias Noetic.Harness.{Canonical, Corpus, Questions}

  @thresholds %{"max_ece" => 0.1, "confident_at" => 0.8, "max_confident_wrong" => 0.05}

  # Below this, ten confidence bins hold three rows each and an ECE is noise.
  @min_rows 30

  @bins 10

  @doc "The thresholds a derived environment is given."
  @spec thresholds() :: map()
  def thresholds, do: @thresholds

  @doc "The fewest rows a decision environment may have."
  @spec min_rows() :: pos_integer()
  def min_rows, do: @min_rows

  # ---- derivation ----------------------------------------------------------

  @doc """
  Build an unverified decision environment.

  `question` is a question id under `.agents/decisions/questions/`. Options:

    * `:corpus` — a file under `.agents/decisions/corpus/` (required)
    * `:from` — keep rows whose `source` starts with this population prefix
      (`run`, `env`); this is how a transfer environment gets rows from a
      different population than the benchmark
    * `:part` — `{k, n}`: keep the rows whose id hashes to `k` modulo `n`, a
      split that does not move when rows are appended
    * `:id`, `:bead`
  """
  @spec derive(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def derive(question_id, opts) do
    with {:ok, question} <- question(question_id),
         %{"fingerprint" => fingerprint} <- Questions.current(question) || :no_version,
         {:ok, corpus} <- corpus_name(opts[:corpus]),
         {:ok, rows} <- corpus_rows(corpus),
         {:ok, {k, n}} <- part(opts[:part]) do
      rows =
        rows
        |> Enum.filter(&in_population?(&1, opts[:from]))
        |> Enum.filter(&(bucket(&1["id"], n) == k))

      selector = %{"from" => opts[:from], "part" => "#{k}/#{n}"}

      {:ok,
       %{
         "id" => opts[:id] || default_id(question_id, opts[:from], k, n),
         "title" =>
           "#{question_id}@#{question["version"]} over #{length(rows)} rows of #{corpus}" <>
             if(opts[:from],
               do: " (#{opts[:from]} rows, part #{k}/#{n})",
               else: " (part #{k}/#{n})"
             ),
         "statement" => question["instructions"],
         "source" => %{
           "kind" => "decision_corpus",
           "corpus" => corpus,
           "selector" => selector,
           "bead" => opts[:bead]
         },
         "verifier" => %{
           "kind" => "decision",
           "question" => question_id,
           "version" => question["version"],
           "fingerprint" => fingerprint,
           "corpus" => corpus,
           "rows" => Enum.map(rows, & &1["id"]),
           "rows_hash" => rows_hash(rows),
           "populations" => rows |> Enum.map(&population/1) |> Enum.uniq() |> Enum.sort(),
           "thresholds" => @thresholds
         },
         "set" => nil,
         "verification" => %{
           "state" => "unverified",
           "by" => "derive",
           "by_attested" => false,
           "reason" => "never run"
         }
       }}
    else
      :no_version -> {:error, "#{question_id} has no recorded current version; bump it first"}
      {:error, _} = error -> error
    end
  end

  defp default_id(question_id, from, k, n) do
    slug = question_id |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
    "env-decision-#{slug}-#{from || "all"}-#{k}of#{n}"
  end

  defp part(nil), do: {:ok, {0, 1}}

  defp part({k, n}) when is_integer(k) and is_integer(n) and n > 0 and k in 0..(n - 1)//1,
    do: {:ok, {k, n}}

  defp part(text) when is_binary(text) do
    case Regex.run(~r{\A(\d+)/(\d+)\z}, text) do
      [_, k, n] -> part({String.to_integer(k), String.to_integer(n)})
      _ -> {:error, "part must be k/n with 0 <= k < n, got #{inspect(text)}"}
    end
  end

  defp part(other), do: {:error, "part must be k/n with 0 <= k < n, got #{inspect(other)}"}

  # sha256 rather than :erlang.phash2, because a split that moves between OTP
  # releases is a holdout that leaks on an upgrade.
  defp bucket(id, n) do
    <<value::unsigned-32, _::binary>> = :crypto.hash(:sha256, id)
    rem(value, n)
  end

  defp population(row), do: row["source"] |> to_string() |> String.split(":", parts: 2) |> hd()

  defp in_population?(_row, nil), do: true
  defp in_population?(row, from), do: population(row) == from

  @doc """
  The rows as a solver may see them: id and evidence, never the label. Empty
  when the environment no longer matches its corpus, since a brief of rows
  that changed would pose a different task under the same id.
  """
  @spec brief_rows(map()) :: [map()]
  def brief_rows(environment) do
    case current_rows(environment["verifier"]) do
      {:ok, rows} -> Enum.map(rows, &Map.take(&1, ["id", "evidence"]))
      {:unavailable, _} -> []
    end
  end

  # ---- verification --------------------------------------------------------

  @doc """
  Verify a decision environment: the question and rows are the ones it was
  derived from, and it judges the four built-in answerers correctly.

  Returns a verification result in the shape `Environments.record_verification/2`
  takes.
  """
  @spec verify(map()) :: map()
  def verify(environment) do
    verifier = environment["verifier"]

    with {:ok, rows} <- current_rows(verifier) do
      judged = adversaries(rows, verifier)

      # Each answerer built to fail must fail *by the rule it exercises*. One
      # that fails for some other reason proves nothing about its rule: with
      # the confident-wrong ceiling set to 1.0, the overconfident answerer
      # still failed — on the baseline — and the environment verified with a
      # ceiling that could never fire. Found by this module's own test.
      wrong =
        Enum.flat_map(judged, fn
          {_name, :pass, %{"passed" => true}} ->
            []

          {name, :pass, report} ->
            ["#{name} should pass and failed (#{Enum.join(report["failures"], "; ")})"]

          {name, {:fail, rule}, report} ->
            if rule in report["failed_rules"],
              do: [],
              else: [
                "#{name} should fail by the #{rule} rule and " <>
                  if(report["passed"],
                    do: "passed",
                    else: "failed only by: #{Enum.join(report["failures"], "; ")}"
                  )
              ]
        end)

      evidence =
        Enum.map_join(judged, "; ", fn {name, _must, report} ->
          "#{name}: #{if report["passed"], do: "pass", else: "fail"} " <>
            "(accuracy #{report["accuracy"]}, ece #{report["ece"]}, " <>
            "confident-wrong #{report["confident_wrong"]["rate"]})"
        end)

      cond do
        length(rows) < @min_rows ->
          result(
            "rejected",
            "#{length(rows)} rows; a calibration error over fewer than " <>
              "#{@min_rows} is noise",
            evidence
          )

        wrong == [] ->
          result(
            "verified",
            "the environment passes its labels and fails each answerer " <>
              "built to fail it",
            evidence
          )

        true ->
          result("rejected", Enum.join(wrong, "; "), evidence)
      end
    else
      {:unavailable, reason} -> result("unavailable", reason, nil)
    end
  end

  defp result(state, reason, evidence) do
    %{
      state: state,
      failed_before: nil,
      passed_after: nil,
      discrimination: if(state == "verified", do: "decision"),
      reason: reason
    }
    |> then(&if(evidence, do: Map.put(&1, :evidence, evidence), else: &1))
  end

  defp current_rows(verifier) do
    with {:ok, question} <- question(verifier["question"]) |> unavailable(),
         :ok <- same_question(question, verifier),
         {:ok, all} <- corpus_rows(verifier["corpus"]) |> unavailable() do
      by_id = Map.new(all, &{&1["id"], &1})
      missing = Enum.reject(verifier["rows"], &Map.has_key?(by_id, &1))
      rows = Enum.map(verifier["rows"] -- missing, &by_id[&1])

      cond do
        missing != [] ->
          {:unavailable,
           "#{length(missing)} row(s) are no longer in #{verifier["corpus"]} " <>
             "(#{Enum.take(missing, 3) |> Enum.join(", ")}…)"}

        rows_hash(rows) != verifier["rows_hash"] ->
          {:unavailable,
           "the rows' labels or evidence changed since this environment was derived; " <>
             "derive a new one rather than re-verifying this one against different labels"}

        true ->
          {:ok, rows}
      end
    end
  end

  defp same_question(question, verifier) do
    # The fingerprint of the content on disk, not the one its version entry
    # records: a question edited without a bump still records the old
    # fingerprint, and trusting the record let exactly that through.
    if question["version"] == verifier["version"] and
         Questions.fingerprint(question) == verifier["fingerprint"],
       do: :ok,
       else:
         {:unavailable,
          "#{verifier["question"]} is at version #{question["version"]}; this environment asks " <>
            "version #{verifier["version"]}, which is no longer the question on disk"}
  end

  defp unavailable({:error, reason}), do: {:unavailable, reason}
  defp unavailable(ok), do: ok

  @doc false
  # The four answerers `verify/1` poses, with what each must do. Public so the
  # test can assert on each one's report rather than only on the verdict.
  def adversaries(rows, verifier) do
    thresholds = verifier["thresholds"] || @thresholds
    labels = Map.new(rows, &{&1["id"], &1["label"]})
    {majority, _} = rows |> Enum.frequencies_by(& &1["label"]) |> Enum.max_by(&elem(&1, 1))
    options = options_for(verifier, rows)

    # Wrong on just over the confident-wrong ceiling's worth of rows, chosen
    # among those that are not the majority label so that the answerer still
    # beats the majority baseline — the ceiling must be what stops it.
    wrong_count = floor(thresholds["max_confident_wrong"] * length(rows)) + 1

    wrong_ids =
      rows
      |> Enum.reject(&(&1["label"] == majority))
      |> Enum.take(wrong_count)
      |> MapSet.new(& &1["id"])

    certain = fn choice -> %{"choice" => choice, "probabilities" => %{choice => 1.0}} end

    oracle = Map.new(labels, fn {id, label} -> {id, certain.(label)} end)
    constant = Map.new(labels, fn {id, _} -> {id, certain.(majority)} end)

    overconfident =
      Map.new(labels, fn {id, label} ->
        if MapSet.member?(wrong_ids, id),
          do: {id, %{"choice" => other(options, label), "probabilities" => nil}},
          else: {id, certain.(label)}
      end)

    underconfident =
      Map.new(labels, fn {id, label} ->
        {id, %{"choice" => label, "probabilities" => %{label => 0.5}}}
      end)

    env = %{"verifier" => Map.put(verifier, "thresholds", thresholds)}

    [
      {"the labels", :pass, score_rows(env, rows, oracle, [])},
      {"the majority label", {:fail, "baseline"}, score_rows(env, rows, constant, [])},
      {"right but confidently wrong on #{wrong_count}", {:fail, "confident_wrong"},
       score_rows(env, rows, overconfident, [])},
      {"right at 0.5", {:fail, "ece"}, score_rows(env, rows, underconfident, [])}
    ]
  end

  defp options_for(verifier, rows) do
    case question(verifier["question"]) do
      {:ok, %{"options" => [_ | _] = options}} -> options
      _ -> rows |> Enum.map(& &1["label"]) |> Enum.uniq()
    end
  end

  defp other(options, label), do: Enum.find(options, &(&1 != label)) || "#{label}-not"

  # ---- scoring -------------------------------------------------------------

  @doc """
  Score answers against a decision environment.

  `answers` maps a row id to `%{"choice" => ..., "probabilities" => ...}`.
  `:reference` is the same shape for the mechanism the answers would replace.
  Returns a string-keyed report, the body of a `CalibrationReport` artifact.
  """
  @spec score(map(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def score(environment, answers, opts \\ []) do
    case current_rows(environment["verifier"]) do
      {:ok, rows} -> {:ok, score_rows(environment, rows, answers, opts)}
      {:unavailable, reason} -> {:error, reason}
    end
  end

  defp score_rows(environment, rows, answers, opts) do
    t = environment["verifier"]["thresholds"] || @thresholds
    n = length(rows)

    judged =
      Enum.map(rows, fn row ->
        answer = Map.get(answers, row["id"])
        choice = answer && answer["choice"]

        %{
          id: row["id"],
          label: row["label"],
          choice: choice,
          confidence: confidence(answer),
          right: choice != nil and choice == row["label"]
        }
      end)

    answered = Enum.filter(judged, & &1.choice)
    accuracy = rate(Enum.count(judged, & &1.right), n)

    {majority, majority_n} =
      rows |> Enum.frequencies_by(& &1["label"]) |> Enum.max_by(&elem(&1, 1))

    baseline = rate(majority_n, n)

    confident_wrong =
      Enum.count(answered, &(not &1.right and &1.confidence >= t["confident_at"]))

    ece = ece(answered)
    reference = reference(rows, judged, opts[:reference])

    failed =
      [
        {"baseline", accuracy <= baseline,
         "accuracy #{accuracy} does not beat always answering #{majority} (#{baseline})"},
        {"reference", reference != nil and accuracy <= reference["accuracy"],
         "accuracy #{accuracy} does not beat the reference (#{reference && reference["accuracy"]})"},
        {"ece", ece > t["max_ece"], "ECE #{ece} exceeds #{t["max_ece"]}"},
        {"confident_wrong", rate(confident_wrong, n) > t["max_confident_wrong"],
         "#{confident_wrong} of #{n} rows wrong at confidence >= #{t["confident_at"]}, " <>
           "over the #{t["max_confident_wrong"]} ceiling"}
      ]
      |> Enum.filter(&elem(&1, 1))

    failures = Enum.map(failed, &elem(&1, 2))

    %{
      "environment" => environment["id"],
      "question" =>
        "#{environment["verifier"]["question"]}@#{environment["verifier"]["version"]}",
      "rows" => n,
      "answered" => length(answered),
      "accuracy" => accuracy,
      "baseline" => %{"label" => majority, "accuracy" => baseline},
      "ece" => ece,
      "confident_wrong" => %{
        "at" => t["confident_at"],
        "count" => confident_wrong,
        "rate" => rate(confident_wrong, n)
      },
      "selective" => selective(answered, n),
      "confusion" => confusion(judged),
      "reference" => reference,
      "thresholds" => t,
      "passed" => failures == [],
      "failures" => failures,
      "failed_rules" => Enum.map(failed, &elem(&1, 0))
    }
  end

  # A bare choice is a claim of certainty; see the moduledoc.
  defp confidence(nil), do: 0.0

  defp confidence(%{"choice" => choice} = answer) do
    case answer["probabilities"] do
      %{} = p when map_size(p) > 0 -> p |> Map.get(choice, 0.0) |> Kernel.*(1.0)
      _ -> 1.0
    end
  end

  # Expected calibration error, ten equal-width bins over the probability the
  # answer gave its own choice. Over the answered rows: an unanswered row has
  # no confidence to be calibrated, and it is already counted wrong.
  defp ece([]), do: 0.0

  defp ece(answered) do
    n = length(answered)

    answered
    |> Enum.group_by(&min(floor(&1.confidence * @bins), @bins - 1))
    |> Enum.map(fn {_bin, group} ->
      acc = Enum.count(group, & &1.right) / length(group)
      conf = Enum.sum_by(group, & &1.confidence) / length(group)
      length(group) / n * abs(acc - conf)
    end)
    |> Enum.sum()
    |> Float.round(3)
  end

  # How the error rate falls as the answerer is allowed to abstain below a
  # confidence: the curve a policy's `accept_at` is chosen from.
  defp selective(answered, n) do
    for at <- [0.0, 0.5, 0.6, 0.7, 0.8, 0.9] do
      kept = Enum.filter(answered, &(&1.confidence >= at))

      %{
        "at" => at,
        "coverage" => rate(length(kept), n),
        "risk" =>
          if(kept == [], do: nil, else: rate(Enum.count(kept, &(not &1.right)), length(kept)))
      }
    end
  end

  defp confusion(judged) do
    judged
    |> Enum.group_by(& &1.label)
    |> Map.new(fn {label, group} ->
      {label, Enum.frequencies_by(group, &(&1.choice || "no answer"))}
    end)
  end

  # The comparison the bead says matters: not the aggregate, but the rows the
  # reference gets wrong. A model that agrees with the regex everywhere has
  # bought nothing.
  defp reference(_rows, _judged, nil), do: nil

  defp reference(rows, judged, answers) do
    theirs =
      Map.new(rows, fn row ->
        {row["id"], get_in(answers, [row["id"], "choice"]) == row["label"]}
      end)

    %{
      "accuracy" => rate(Enum.count(theirs, &elem(&1, 1)), length(rows)),
      "right_where_reference_wrong" =>
        judged |> Enum.filter(&(&1.right and not theirs[&1.id])) |> Enum.map(& &1.id),
      "wrong_where_reference_right" =>
        judged |> Enum.filter(&(not &1.right and theirs[&1.id])) |> Enum.map(& &1.id)
    }
  end

  defp rate(_count, 0), do: 0.0
  defp rate(count, n), do: Float.round(count / n, 3)

  @doc """
  Read an answers file: one JSON object per line, `{"id", "choice",
  "probabilities"}`. Other fields are ignored; a line without an id or a
  choice is refused rather than skipped, because a row silently dropped is a
  row silently counted wrong.
  """
  @spec read_answers(String.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def read_answers(nil), do: {:error, "--answers <file.jsonl> is required"}

  def read_answers(path) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
        case JSON.decode(line) do
          {:ok, %{"id" => id, "choice" => choice} = a} when is_binary(id) and is_binary(choice) ->
            {:cont, {:ok, Map.put(acc, id, Map.take(a, ["choice", "probabilities"]))}}

          _ ->
            {:halt,
             {:error,
              "#{path}: every line needs a string id and choice: #{String.slice(line, 0, 80)}"}}
        end
      end)
    else
      {:error, "no answers file #{path}"}
    end
  end

  @doc """
  `Conductor.classify/1`'s answers to `failure.class` for the environment's
  rows, as a reference: the mechanism a model would replace. A regex gives no
  probability, so it is read as certain — see the moduledoc.
  """
  @spec conductor_answers(map()) :: map()
  def conductor_answers(environment) do
    case current_rows(environment["verifier"]) do
      {:ok, rows} ->
        Map.new(rows, fn row ->
          choice =
            case Noetic.Harness.Conductor.classify(row["evidence"]) do
              {:ok, class} -> class["id"]
              :none -> "unclassified"
            end

          {row["id"], %{"choice" => choice}}
        end)

      {:unavailable, _} ->
        %{}
    end
  end

  @doc """
  Write a report as a `CalibrationReport` artifact. The answers file is named
  and hashed, not copied: it is the provider's output, it may be large, and
  the hash is what lets a later reader check they are looking at the same one.
  """
  @spec record(map(), keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  def record(report, opts) do
    by = opts[:by] || []
    file = opts[:answers_file]

    answers =
      if file && File.regular?(file),
        do: %{
          "answers" => Path.basename(file),
          "sha256" => :crypto.hash(:sha256, File.read!(file)) |> Base.encode16(case: :lower)
        },
        else: %{}

    with {:ok, artifact} <-
           Noetic.Harness.Artifact.new(%{
             kind: "CalibrationReport",
             created_by: by[:by] || "unattributed",
             task: report["environment"],
             inputs: [Map.put(answers, "environment", report["environment"])],
             evaluation: report,
             evidence: [
               %{
                 what: "#{report["question"]} over #{report["rows"]} rows",
                 command: "noetic-harness environments --score #{report["environment"]}",
                 result:
                   "accuracy #{report["accuracy"]}, ECE #{report["ece"]}, " <>
                     "#{if report["passed"], do: "passed", else: "failed"}",
                 outcome: if(report["passed"], do: "passed", else: "failed")
               }
             ],
             unverified: [
               "the labels are model-rated (human_confirmed: false) until a person confirms them",
               "the answers were produced outside the harness and were not re-run here"
             ]
           }) do
      Noetic.Harness.Artifact.write(artifact)
    end
  end

  # ---- validation ----------------------------------------------------------

  @doc """
  What `Environments.validate/0` adds for decision environments.

  An error when a row is in environments of two different sets: the holdout's
  answers would be on screen while tuning against the benchmark, the same leak
  as a shared verifier file. A warning when the transfer set draws only on
  populations the benchmark already covers — the decision form of "a transfer
  environment must come from a different app".
  """
  @spec validate([map()]) :: %{errors: [String.t()], warnings: [String.t()]}
  def validate(environments) do
    assigned = Enum.filter(environments, &(&1["set"] != nil))

    errors =
      assigned
      |> Enum.flat_map(fn e -> Enum.map(e["verifier"]["rows"] || [], &{&1, e}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {row, sharing} ->
        case sharing |> Enum.map(& &1["set"]) |> Enum.uniq() do
          [_] ->
            []

          sets ->
            [
              "decision row #{row} is in #{Enum.join(Enum.sort(sets), " and ")} " <>
                "(#{Enum.map_join(sharing, ", ", & &1["id"])}); a row's label is its answer, " <>
                "so the held-out set is on screen while the benchmark is tuned against"
            ]
        end
      end)
      # Sorted and capped: a whole shared split is hundreds of rows, and five
      # named in order say what the rest would.
      |> Enum.sort()
      |> Enum.take(5)

    populations = fn set ->
      assigned
      |> Enum.filter(&(&1["set"] == set))
      |> Enum.flat_map(&(&1["verifier"]["populations"] || []))
      |> MapSet.new()
    end

    transfer = populations.("transfer")

    warnings =
      if MapSet.size(transfer) > 0 and MapSet.subset?(transfer, populations.("benchmark")),
        do: [
          "every transfer decision environment draws on a population the benchmark already " <>
            "covers (#{Enum.join(Enum.sort(transfer), ", ")}) — it measures the same " <>
            "distribution twice"
        ],
        else: []

    %{errors: errors, warnings: warnings}
  end

  @doc "Shape errors for a decision verifier, or `:ok`."
  @spec validate_verifier(map()) :: :ok | {:error, String.t()}
  def validate_verifier(verifier) do
    missing =
      Enum.filter(
        ~w(question version fingerprint corpus rows rows_hash),
        &(verifier[&1] in [nil, ""])
      )

    cond do
      missing != [] ->
        {:error, "a decision verifier needs #{Enum.join(missing, ", ")}"}

      not is_list(verifier["rows"]) or verifier["rows"] == [] ->
        {:error, "verifier.rows is empty"}

      true ->
        :ok
    end
  end

  # ---- helpers -------------------------------------------------------------

  defp question(id) do
    case Enum.find(Questions.list(), &(&1["id"] == id)) do
      nil -> {:error, "no question #{inspect(id)} under .agents/decisions/questions/"}
      q -> {:ok, q}
    end
  end

  # A corpus is named by its file, never by a path: the name goes into a
  # committed environment and is joined under the corpus directory.
  defp corpus_name(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-z0-9_.-]+\.jsonl\z/, name),
      do: {:ok, name},
      else:
        {:error,
         "corpus must be a file name under .agents/decisions/corpus/, got #{inspect(name)}"}
  end

  defp corpus_name(_), do: {:error, "--corpus <file.jsonl> is required"}

  defp corpus_rows(name) do
    path = Noetic.Harness.agents_path(["decisions", "corpus", name])

    if File.exists?(path),
      do: {:ok, Corpus.rows(path)},
      else: {:error, "no corpus #{name} under .agents/decisions/corpus/"}
  end

  defp rows_hash(rows),
    do: rows |> Enum.map(&[&1["id"], &1["label"], &1["evidence"]]) |> Canonical.hash()
end
