defmodule Noetic.Harness.EnvironmentsDecisionTest do
  @moduledoc """
  Decision environments are environments — derived, verified,
  assigned one way and validated by `Environments` — and the evaluator fails a
  model that is confidently wrong however accurate it is elsewhere.
  """

  use ExUnit.Case, async: true

  alias Noetic.Harness.{Artifact, Environments, Fixture, Questions}
  alias Noetic.Harness.Environments.Decision

  @options ~w(test_failed compile_error_unfamiliar unclassified)

  defp question(overrides \\ %{}) do
    q =
      Map.merge(
        %{
          "id" => "toy.class",
          "domain" => "test",
          "type" => "choice",
          "instructions" => "Which class does `evidence` describe?",
          "options" => @options,
          "criteria" => Map.new(@options, &{&1, &1}),
          "calibration_profile" => nil,
          "version" => "1"
        },
        overrides
      )

    Map.put(q, "versions", [
      %{
        "version" => "1",
        "fingerprint" => Questions.fingerprint(q),
        "at" => "2026-09-23",
        "why" => "t"
      }
    ])
  end

  # 40 rows: 30 unclassified, 8 test_failed, 2 compile errors; the first half
  # from runs, the second from environment verifications.
  defp rows(label_of \\ &default_label/1) do
    for i <- 1..40 do
      %{
        "id" => "r-#{String.pad_leading(to_string(i), 3, "0")}",
        "label" => label_of.(i),
        "evidence" => "evidence #{i}",
        "source" => if(i <= 20, do: "run:x", else: "env:y"),
        "human_confirmed" => false
      }
    end
  end

  defp default_label(i) when i <= 30, do: "unclassified"
  defp default_label(i) when i <= 38, do: "test_failed"
  defp default_label(_), do: "compile_error_unfamiliar"

  defp jsonl(rows), do: Enum.map_join(rows, "\n", &JSON.encode!/1) <> "\n"

  defp tree(rows \\ rows(), q \\ question()) do
    %{
      "decisions/questions/toy.class.json" => q,
      "decisions/corpus/toy.jsonl" => jsonl(rows)
    }
  end

  defp derived(opts \\ []) do
    {:ok, env} = Decision.derive("toy.class", Keyword.merge([corpus: "toy.jsonl"], opts))
    {:ok, env} = Environments.put(env)
    env
  end

  defp labels(rows), do: Map.new(rows, &{&1["id"], &1["label"]})

  test "a derived environment verifies: its labels pass and each answerer built to fail it fails" do
    Fixture.with_tree(tree(), fn _ ->
      env = derived()
      assert length(env["verifier"]["rows"]) == 40
      assert env["verifier"]["populations"] == ["env", "run"]

      {:ok, env} = Environments.verify(env["id"], by: "test")
      assert env["verification"]["state"] == "verified", env["verification"]["reason"]
      assert env["verification"]["discrimination"] == "decision"

      verdicts =
        env["verifier"]
        |> then(&Decision.adversaries(rows(), &1))
        |> Map.new(fn {name, _must, report} -> {name, report} end)

      assert verdicts["the labels"]["passed"]
      refute verdicts["the majority label"]["passed"]
      refute verdicts["right at 0.5"]["passed"]

      # Built so that only the confident-wrong ceiling can stop it.
      [{_, overconfident}] =
        Enum.filter(verdicts, fn {name, _} -> name =~ "confidently wrong" end)

      refute overconfident["passed"]
      assert [only] = overconfident["failures"]
      assert only =~ "wrong at confidence"
    end)
  end

  test "an environment whose confident-wrong ceiling is disabled is rejected, naming the answerer it let through" do
    Fixture.with_tree(tree(), fn root ->
      env = derived()
      path = Path.join([root, ".agents", "evolution", "environments", "#{env["id"]}.json"])

      File.write!(
        path,
        env
        |> put_in(["verifier", "thresholds"], %{
          Decision.thresholds()
          | "max_confident_wrong" => 1.0
        })
        |> JSON.encode!()
      )

      {:ok, env} = Environments.verify(env["id"], by: "test")
      assert env["verification"]["state"] == "rejected"
      assert env["verification"]["reason"] =~ "confidently wrong on"
    end)
  end

  test "one label everywhere, or too few rows, is rejected: nothing can be measured" do
    Fixture.with_tree(tree(rows(fn _ -> "unclassified" end)), fn _ ->
      {:ok, env} = Environments.verify(derived()["id"], by: "test")
      assert env["verification"]["state"] == "rejected"
      assert env["verification"]["reason"] =~ "the labels should pass"
    end)

    Fixture.with_tree(tree(Enum.take(rows(), 19) ++ Enum.drop(rows(), 30)), fn _ ->
      {:ok, env} = Environments.verify(derived()["id"], by: "test")
      assert env["verification"]["state"] == "rejected"
      assert env["verification"]["reason"] =~ "fewer than #{Decision.min_rows()}"
    end)
  end

  test "a relabelled row or a changed question makes it unavailable, never re-verified" do
    Fixture.with_tree(tree(), fn root ->
      env = derived()
      corpus = Path.join([root, ".agents", "decisions", "corpus", "toy.jsonl"])
      relabelled = rows(fn i -> if i == 1, do: "test_failed", else: default_label(i) end)
      File.write!(corpus, jsonl(relabelled))

      {:ok, env} = Environments.verify(env["id"], by: "test")
      assert env["verification"]["state"] == "unavailable"
      assert env["verification"]["reason"] =~ "labels or evidence changed"
    end)

    Fixture.with_tree(tree(), fn root ->
      env = derived()
      qfile = Path.join([root, ".agents", "decisions", "questions", "toy.class.json"])
      changed = question() |> Map.put("instructions", "Something else?")
      # Recorded fingerprint still says version 1's; the content moved.
      File.write!(qfile, JSON.encode!(Map.put(changed, "versions", question()["versions"])))

      {:ok, env} = Environments.verify(env["id"], by: "test")
      assert env["verification"]["state"] == "unavailable"
      assert env["verification"]["reason"] =~ "no longer the question on disk"
    end)
  end

  test "a model confidently wrong out of distribution fails however accurate it is elsewhere" do
    Fixture.with_tree(tree(), fn _ ->
      env = derived()
      truth = labels(rows())

      # Right everywhere except five env rows, which it answers `unclassified`
      # with near-certainty whatever the truth — the OOD failure the bead
      # names. Accurate enough to beat the baseline and calibrated enough to
      # pass ECE: the confident-wrong ceiling is what fails it.
      answers =
        Map.new(truth, fn {id, label} ->
          ood? = id in ~w(r-031 r-032 r-033 r-034 r-035)
          choice = if ood?, do: "unclassified", else: label
          {id, %{"choice" => choice, "probabilities" => %{choice => 0.97}}}
        end)

      {:ok, report} = Decision.score(env, answers)
      assert report["accuracy"] > report["baseline"]["accuracy"]
      refute report["passed"]
      assert report["failed_rules"] == ["confident_wrong"]
    end)
  end

  test "a calibrated model that beats the baseline and the reference passes; one that ties the reference does not" do
    Fixture.with_tree(tree(), fn _ ->
      env = derived()
      truth = labels(rows())

      # Wrong on two rows, and unsure exactly there.
      answers =
        Map.new(truth, fn {id, label} ->
          if id in ["r-031", "r-039"],
            do: {id, %{"choice" => "unclassified", "probabilities" => %{"unclassified" => 0.4}}},
            else: {id, %{"choice" => label, "probabilities" => %{label => 0.95}}}
        end)

      reference = Map.new(truth, fn {id, _} -> {id, %{"choice" => "unclassified"}} end)

      {:ok, report} = Decision.score(env, answers, reference: reference)
      assert report["passed"], inspect(report["failures"])
      assert report["reference"]["accuracy"] == 0.75
      assert "r-032" in report["reference"]["right_where_reference_wrong"]
      assert report["reference"]["wrong_where_reference_right"] == []

      {:ok, tie} = Decision.score(env, answers, reference: answers)
      refute tie["passed"]
      assert Enum.any?(tie["failures"], &(&1 =~ "does not beat the reference"))
    end)
  end

  test "an unanswered row counts wrong rather than disappearing from the denominator" do
    Fixture.with_tree(tree(), fn _ ->
      env = derived()
      answers = rows() |> Enum.take(10) |> Map.new(&{&1["id"], %{"choice" => &1["label"]}})

      {:ok, report} = Decision.score(env, answers)
      assert report["rows"] == 40
      assert report["answered"] == 10
      assert report["accuracy"] == 0.25
    end)
  end

  test "sets: decision environments stay out of the harness candidates' suite, and a shared row across sets is an error" do
    Fixture.with_tree(tree(), fn _ ->
      a = derived(id: "env-decision-a")
      b = derived(id: "env-decision-b")
      for id <- [a["id"], b["id"]], do: {:ok, _} = Environments.verify(id, by: "test")

      {:ok, _} = Environments.assign(a["id"], "benchmark")
      {:ok, _} = Environments.assign(b["id"], "holdout")

      assert Environments.suite("benchmark") == []
      assert [%{"id" => "env-decision-a"}] = Environments.suite("benchmark", "decision")
      assert {:error, _} = Environments.assign(a["id"], "holdout")

      %{errors: errors} = Environments.validate()
      assert Enum.any?(errors, &(&1 =~ "decision row r-001 is in benchmark and holdout"))
    end)
  end

  test "a k/n split partitions the rows, and does not move when rows are appended" do
    Fixture.with_tree(tree(), fn root ->
      {:ok, zero} = Decision.derive("toy.class", corpus: "toy.jsonl", part: "0/2")
      {:ok, one} = Decision.derive("toy.class", corpus: "toy.jsonl", part: "1/2")
      all = zero["verifier"]["rows"] ++ one["verifier"]["rows"]
      assert Enum.sort(all) == Enum.map(rows(), & &1["id"])

      extra = %{
        "id" => "r-999",
        "label" => "unclassified",
        "evidence" => "e",
        "source" => "run:x"
      }

      File.write!(
        Path.join([root, ".agents", "decisions", "corpus", "toy.jsonl"]),
        jsonl(rows() ++ [extra])
      )

      {:ok, again} = Decision.derive("toy.class", corpus: "toy.jsonl", part: "0/2")
      assert zero["verifier"]["rows"] -- again["verifier"]["rows"] == []

      assert {:error, _} = Decision.derive("toy.class", corpus: "toy.jsonl", part: "2/2")
      assert {:error, _} = Decision.derive("toy.class", corpus: "../etc/passwd")
    end)
  end

  test "a solver's brief carries the evidence and never the label" do
    Fixture.with_tree(tree(), fn _ ->
      brief = Environments.brief(derived())
      assert brief["question"] == "toy.class"
      assert length(brief["rows"]) == 40
      assert Enum.all?(brief["rows"], &(Map.keys(&1) |> Enum.sort() == ["evidence", "id"]))
    end)
  end

  test "a report is recorded as a CalibrationReport artifact carrying the measurement" do
    Fixture.with_tree(tree(), fn root ->
      env = derived()
      answers_file = Path.join(root, "answers.jsonl")

      File.write!(
        answers_file,
        rows() |> Enum.map(&%{"id" => &1["id"], "choice" => &1["label"]}) |> jsonl()
      )

      {:ok, answers} = Decision.read_answers(answers_file)
      {:ok, report} = Decision.score(env, answers)
      {:ok, path} = Decision.record(report, answers_file: answers_file, by: [by: "test"])

      artifact = path |> File.read!() |> JSON.decode!()
      assert artifact["kind"] == "CalibrationReport"
      assert "CalibrationReport" in Artifact.kinds()
      assert artifact["evaluation"]["accuracy"] == 1.0

      assert [%{"sha256" => <<_::binary-size(64)>>, "answers" => "answers.jsonl"}] =
               artifact["inputs"]
    end)
  end
end
