defmodule Mix.Tasks.Harness.Evolution do
  @moduledoc """
  Candidates, lineage and promotion readiness.

      noetic-harness evolution                                live candidates
      noetic-harness evolution --all                          including the archive
      noetic-harness evolution --show <id>                    stages, fitness, lineage
      noetic-harness evolution --check <id>                   may it be promoted, and if not why not
      noetic-harness evolution --propose --target-kind prompt --target-ref backend.typedb_engineer \
        --weakness "..." --change "..." --disconfirming "..." --by <agent-id> \
        --family prompt_policy --capability task_completion=0.02 --efficiency typeql_regressions \
        --application-ref <sha> --application-baseline <sha>
      noetic-harness evolution --record <id> --stage holdout --outcome passed --by <agent-id> --independent
      noetic-harness evolution --archive <id> --status quarantined --reason "..."
      noetic-harness evolution --score <id> --set benchmark [--plan]

  `--check` is the one that matters. It refuses with the specific missing or
  failed stage, because a promotion refused with "not ready" teaches nobody
  anything. And it refuses a holdout or anti-Goodhart stage that was not run
  independently of the candidate's author, because such a stage is a second
  benchmark wearing a holdout's name.
  """
  @shortdoc "Manage evolution candidates and their evidence"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]
  alias Noetic.Harness.{Environments, Evolution, Scoring}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          all: :boolean,
          show: :string,
          check: :string,
          propose: :boolean,
          from_cluster: :string,
          subject: :string,
          record: :string,
          archive: :string,
          target_kind: :string,
          target_ref: :string,
          weakness: :string,
          change: :string,
          disconfirming: :string,
          by: :string,
          parents: :string,
          stage: :string,
          outcome: :string,
          independent: :boolean,
          fitness: :string,
          status: :string,
          reason: :string,
          score: :string,
          set: :string,
          plan: :boolean,
          application_ref: :string,
          application_baseline: :string,
          family: :string,
          capability: :keep,
          efficiency: :string
        ]
      )

    shell = Mix.shell()

    cond do
      id = opts[:score] -> score(shell, id, opts)
      shape = opts[:from_cluster] -> from_cluster(shell, shape, opts)
      opts[:propose] -> propose(shell, opts)
      id = opts[:record] -> record(shell, id, opts)
      id = opts[:archive] -> archive(shell, id, opts)
      id = opts[:check] -> check(shell, id)
      id = opts[:show] -> show(shell, id)
      true -> list(shell, opts)
    end
  end

  # The link a design note said was missing: a
  # cluster that survived the population floor becomes a candidate with a
  # hypothesis, without a person retyping it.
  #
  # It takes the *shape*, not a JSON blob, and looks the cluster up in what
  # telemetry currently reports. A candidate proposed from a cluster somebody
  # pasted in is a candidate whose weakness nobody can re-measure.
  defp from_cluster(shell, shape, opts) do
    summary = Noetic.Harness.Telemetry.collect([])

    case Noetic.Harness.Telemetry.clusters(summary) do
      {:insufficient, message} ->
        shell.info(message)

      {:ok, clusters} ->
        matching =
          Enum.filter(clusters, fn cluster ->
            cluster["shape"] == shape and
              (opts[:subject] == nil or cluster["subject"] == opts[:subject])
          end)

        case matching do
          [] ->
            shell.info("no cluster with shape #{shape}#{subject_suffix(opts)} is reported now.")
            shell.info("`noetic-harness telemetry --clusters` lists what is.")

          [cluster] ->
            propose_cluster(shell, cluster, opts)

          several ->
            shell.info("#{length(several)} clusters share the shape #{shape}. Name one with")
            shell.info("`--subject`:")
            Enum.each(several, &shell.info("  #{&1["subject"]}"))
        end
    end
  end

  defp subject_suffix(opts), do: if(opts[:subject], do: " on #{opts[:subject]}", else: "")

  defp propose_cluster(shell, cluster, opts) do
    case Evolution.from_cluster(cluster, created_by: opts[:by]) do
      {:ok, path} ->
        shell.info("proposed #{Path.relative_to_cwd(path)}")
        shell.info("")
        shell.info("  weakness  #{cluster["shape"]} on #{cluster["subject"]}")
        shell.info("  change    #{cluster["change"]}")

        {:ok, candidate} = Evolution.fetch(Path.basename(path, ".json"))

        if Evolution.protected_target?(candidate) do
          shell.info("")
          shell.info("  This candidate targets #{get_in(candidate, ["target", "ref"])}, which")
          shell.info("  an evolution run may propose and may never land (constitution §23).")
          shell.info("  `--check` will refuse it however well it scores. That is the point:")
          shell.info("  it is for a person to read.")
        end

      {:error, message} ->
        shell.info(message)
    end
  end

  defp list(shell, opts) do
    case Evolution.list(archived: !!opts[:all]) do
      [] ->
        shell.info("(no candidates)")

      candidates ->
        Enum.each(candidates, fn candidate ->
          stages = candidate["stages"] |> Map.keys() |> Enum.sort() |> Enum.join(",")

          shell.info(
            "#{String.pad_trailing(candidate["id"], 46)} #{String.pad_trailing(candidate["status"], 12)} " <>
              "gen #{get_in(candidate, ["lineage", "generation"])}  stages: #{stages}"
          )
        end)
    end
  end

  defp show(shell, id) do
    case Evolution.fetch(id) do
      :error ->
        Mix.raise("no candidate #{id}")

      {:ok, candidate} ->
        shell.info("#{candidate["id"]}  (#{candidate["status"]})")

        shell.info(
          "target     #{get_in(candidate, ["target", "kind"])} #{get_in(candidate, ["target", "ref"])}"
        )

        shell.info("by         #{candidate["created_by"]} at #{candidate["created_at"]}")
        shell.info("")
        shell.info("hypothesis")
        shell.info("  weakness      #{get_in(candidate, ["hypothesis", "weakness"])}")
        shell.info("  change        #{get_in(candidate, ["hypothesis", "change"])}")

        shell.info(
          "  disconfirmed  #{get_in(candidate, ["hypothesis", "disconfirming_evidence"])}"
        )

        shell.info("")
        shell.info("stages")

        Enum.each(~w(sandbox benchmark holdout transfer anti_goodhart archive), fn stage ->
          case candidate["stages"][stage] do
            nil ->
              shell.info("  #{String.pad_trailing(stage, 15)} not run")

            entry ->
              independent = if entry["independent"], do: " independent", else: " NOT independent"

              shell.info(
                "  #{String.pad_trailing(stage, 15)} #{String.pad_trailing(entry["outcome"], 12)} " <>
                  "by #{entry["by"]}#{independent}"
              )
          end
        end)

        shell.info("")
        shell.info("fitness (a vector, deliberately — there is no single score)")

        case candidate["fitness"] do
          empty when empty in [nil, %{}] ->
            shell.info("  (none recorded)")

          fitness ->
            Enum.each(fitness, fn {k, v} -> shell.info("  #{String.pad_trailing(k, 15)} #{v}") end)
        end

        if Evolution.goodhart_signature?(candidate) do
          shell.info("")

          shell.info(
            "GOODHART SIGNATURE: #{Noetic.Harness.Environments.motivating_set()} improved and " <>
              "#{Enum.join(Evolution.goodhart_signature(candidate), " and ")} did not."
          )

          shell.info("Quarantine. Do not promote, and do not retry it harder.")
        end

        shell.info("")
        shell.info("lineage")
        Enum.each(Evolution.lineage(id), &shell.info("  #{&1["id"]} (#{&1["status"]})"))
    end
  end

  defp check(shell, id) do
    case Evolution.fetch(id) do
      :error ->
        Mix.raise("no candidate #{id}")

      {:ok, candidate} ->
        case Evolution.promotable?(candidate) do
          :ok ->
            shell.info(
              "#{id}: every stage present and passed, holdout and anti-Goodhart independent."
            )

            shell.info("")
            shell.info("That makes it *eligible*. Promotion itself is T4: it needs the protected")
            shell.info("gate, a reviewer who did not author it, and a human.")

          {:error, reasons} ->
            shell.error("#{id} may not be promoted:")
            Enum.each(reasons, &shell.error("  - #{&1}"))
            exit({:shutdown, 1})
        end
    end
  end

  # `--family`, `--capability` and `--efficiency` are here because `propose/1`
  # requires metrics and a family and this task passed neither, so the CLI path
  # to a candidate did not work at all. `--application-ref` and
  # `--application-baseline` were declared and read nowhere, which meant the
  # only way to a *scorable* candidate was hand-editing JSON — and hand-editing
  # JSON is the forgery path the previous review walked.
  defp propose(shell, opts) do
    attrs = %{
      target: %{kind: opts[:target_kind], ref: opts[:target_ref]},
      hypothesis: %{
        weakness: opts[:weakness],
        change: opts[:change],
        disconfirming_evidence: opts[:disconfirming]
      },
      created_by: opts[:by],
      family: opts[:family],
      metrics: %{
        capability: Enum.map(Keyword.get_values(opts, :capability), &capability/1),
        efficiency: String.split(opts[:efficiency] || "", [",", " "], trim: true)
      },
      application: application(opts),
      parents: String.split(opts[:parents] || "", [",", " "], trim: true)
    }

    case Evolution.propose(attrs) do
      {:ok, path} -> shell.info("proposed #{Path.relative_to(path, Noetic.Harness.root())}")
      {:error, message} -> Mix.raise(message)
    end
  end

  defp record(shell, id, opts) do
    fitness =
      (opts[:fitness] || "")
      |> String.split([",", " "], trim: true)
      |> Map.new(fn pair ->
        [key, value] = String.split(pair, "=", parts: 2)
        {key, parse_number(value)}
      end)

    result = %{
      by: opts[:by],
      outcome: opts[:outcome] || "failed",
      independent: !!opts[:independent],
      fitness: fitness
    }

    case Evolution.record_stage(id, opts[:stage] || "", result) do
      {:ok, path} ->
        shell.info("recorded #{opts[:stage]} in #{Path.relative_to(path, Noetic.Harness.root())}")
        warn_about_typed_set_keys(shell, fitness)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  # `--capability task_completion=0.02`
  defp capability(pair) do
    case String.split(pair, "=", parts: 2) do
      [name, tolerance] ->
        %{name: name, tolerance: parse_number(tolerance)}

      [name] ->
        Mix.raise(
          "--capability #{name} has no tolerance. A capability metric without one says what " <>
            "must not get worse and not by how much it may move first, which is the half that " <>
            "makes it checkable"
        )
    end
  end

  # Both halves or neither: a candidate with a ref and no baseline has nothing
  # to be measured against.
  defp application(opts) do
    case {opts[:application_ref], opts[:application_baseline]} do
      {nil, nil} ->
        nil

      {ref, baseline} when is_binary(ref) and is_binary(baseline) ->
        %{kind: "git_ref", ref: ref, baseline: baseline}

      _ ->
        Mix.raise(
          "--application-ref and --application-baseline go together: two arms, or no scoring"
        )
    end
  end

  # Said here, where the number is being typed, rather than only at
  # `--check` time. A refusal that arrives a week after the keystroke that
  # caused it is a refusal somebody argues with; one that arrives with the
  # keystroke is a refusal somebody understands. It is a warning and not a
  # refusal because `--record` is how a human records a stage they ran by
  # hand, and the gate that actually depends on the number is `--check`.
  defp warn_about_typed_set_keys(shell, fitness) do
    case Enum.filter(Evolution.set_keys(), &Map.has_key?(fitness, &1)) do
      [] ->
        :ok

      typed ->
        shell.info("")

        shell.info(
          "#{Enum.join(typed, ", ")}: typed, not measured. `--check` will refuse this " <>
            "candidate until `fitness_provenance` names a scoring run that exists and the " <>
            "environments it ran."
        )

        shell.info(
          "There is deliberately no `--fitness-provenance` option: provenance is written by " <>
            "a scoring run, not by a person, and nothing scores a candidate yet. " <>
            "Until it does, no set-keyed number here can legitimately be promoted."
        )

        shell.info("")
    end
  end

  # `--plan` resolves the whole run — the arms, the environments, the dispatch
  # count and the estimated spend — and calls nothing. It is the only honest
  # way to answer "what would this cost" for something that costs money, and
  # every refusal `score/3` can make is computed here too, so a run that would
  # be refused is refused for free.
  defp score(shell, id, opts) do
    set = opts[:set] || Mix.raise("--set is required: #{Enum.join(Environments.sets(), ", ")}")

    case Scoring.plan(id, set, []) do
      {:error, message} ->
        Mix.raise(message)

      {:ok, plan} ->
        print_plan(shell, plan)

        cond do
          plan.refusals != [] ->
            shell.error("")
            shell.error("this scoring run is refused:")
            Enum.each(plan.refusals, &shell.error("  - [#{&1.rule}] #{&1.why}"))
            exit({:shutdown, 1})

          opts[:plan] ->
            shell.info("")
            shell.info("--plan: nothing was run and nothing was spent.")

          true ->
            run_score(shell, id, set)
        end
    end
  end

  defp print_plan(shell, plan) do
    shell.info("#{plan.candidate} against the #{plan.set} set")
    shell.info("")

    Enum.each(plan.arms, fn {arm, ref} ->
      shell.info("  #{String.pad_trailing(to_string(arm), 10)} #{ref}")
    end)

    shell.info("")
    shell.info("  environments   #{Enum.join(plan.environments, ", ")}")
    shell.info("  dispatches     #{plan.dispatches}  (two arms)")

    shell.info(
      "  estimated      $#{plan.estimated_usd} against a $#{plan.ceiling_usd} ceiling, at the " <>
        "one dispatch this repository has measured"
    )
  end

  defp run_score(shell, id, set) do
    case Scoring.score(id, set, []) do
      {:refused, refusals} ->
        shell.error("")
        Enum.each(refusals, &shell.error("  - [#{&1.rule}] #{&1.why}"))
        exit({:shutdown, 1})

      {:error, message} ->
        Mix.raise(message)

      {:ok, %{outcome: "partial"} = result} ->
        shell.info("")
        shell.info("PARTIAL — no number was written.")
        shell.info(result.why)
        exit({:shutdown, 1})

      # `scored` was the only success and this clause did not exist, so a
      # refused recording fell through and printed "recorded with the run that
      # produced it" — a sentence that was then false — and exited 0. A third
      # outcome was added to `Scoring.score/3` and its only caller was not
      # updated. Found by an independent review.
      {:ok, %{outcome: "measured"} = result} ->
        shell.info("")
        shell.info("MEASURED, NOT RECORDED.")

        shell.info(
          "  #{set} = #{result.delta}  (candidate #{result.rates.candidate}, " <>
            "baseline #{result.rates.baseline})"
        )

        shell.info("")
        shell.error(result.why)
        exit({:shutdown, 1})

      {:ok, result} ->
        shell.info("")

        Enum.each(result.attempts, fn attempt ->
          mark = if attempt.solved, do: "solved    ", else: "not solved"
          shell.info("  #{mark}  #{attempt.arm}  #{attempt.environment}")
        end)

        shell.info("")
        shell.info("  candidate #{result.rates.candidate}   baseline #{result.rates.baseline}")
        shell.info("  #{set} = #{result.delta}, recorded with the run that produced it")
    end
  end

  defp archive(shell, id, opts) do
    reason = opts[:reason] || Mix.raise("--reason is required")

    case Evolution.archive(id, opts[:status] || "archived", reason) do
      {:ok, path} -> shell.info("archived to #{Path.relative_to(path, Noetic.Harness.root())}")
      {:error, message} -> Mix.raise(message)
    end
  end

  defp parse_number(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end
end
