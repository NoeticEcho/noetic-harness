defmodule Noetic.Harness.CorpusTest do
  @moduledoc """
  The measurement is arithmetic over routes, and the baseline is
  the majority class. Checked on rows whose routes are known.
  """

  use ExUnit.Case, async: true

  alias Noetic.Harness.Corpus

  # The arithmetic runs on the pack (`Noetic.Harness.Pack`). The committed
  # corpora are this repository's, and their tests are tagged
  # `this_repository`.
  setup {Noetic.Harness.Pack, :root}

  defp row(title, label, human \\ false),
    do: %{
      "title" => title,
      "body" => nil,
      "type" => nil,
      "label" => label,
      "human_confirmed" => human
    }

  test "accuracy, baseline and recall are counted over the routes the router actually gives" do
    rows = [
      row("cut a release", "WF-015", true),
      row("the product channel crashes mid-ritual", "WF-003"),
      row("the product channel crashes mid-ritual", "WF-015"),
      row("cut a release", "WF-015")
    ]

    report = Corpus.measure(rows, :title)

    assert report.rows == 4
    assert report.human_confirmed == 1
    assert report.baseline == %{workflow: "WF-015", accuracy: 0.75}
    # "cut a release" reaches WF-015 twice; the crash reaches WF-003 once and
    # is wrong once, against the WF-015 label.
    assert report.accuracy == 0.75
    assert {{"WF-015", "WF-003"}, 1} in report.confusions
  end

  @tag this_repository: true
  test "the committed corpus has a label, three raters and a confirmation flag on every row" do
    rows = Corpus.rows()
    assert length(rows) >= 200

    for r <- rows do
      assert r["label"] =~ ~r/^WF-\d{3}$/
      assert r["rater_a"]["workflow"] && r["rater_b"]["workflow"]
      assert is_boolean(r["human_confirmed"])
      assert r["adjudicated"] == (r["rater_a"]["workflow"] != r["rater_b"]["workflow"])
      # The third rater is a different model family from the first
      # two, and `contested` is derived from it, never set by hand.
      assert r["rater_c"]["workflow"] =~ ~r/^WF-\d{3}$/, r["id"]
      assert r["rater_c"]["model"] =~ "fable"
      assert r["contested"] == (r["rater_c"]["workflow"] != r["label"]), r["id"]
    end
  end

  @tag this_repository: true
  test "the tune and held-out halves partition the corpus, by id, and do not move" do
    rows = Corpus.rows()
    tune = Corpus.split(rows, :tune)
    heldout = Corpus.split(rows, :heldout)

    assert Enum.sort(Enum.map(tune ++ heldout, & &1["id"])) ==
             Enum.sort(Enum.map(rows, & &1["id"]))

    assert MapSet.disjoint?(MapSet.new(tune, & &1["id"]), MapSet.new(heldout, & &1["id"]))
    # By hash of the id, not by position: reversing the file changes nothing.
    assert Corpus.split(Enum.reverse(rows), :tune) |> Enum.map(& &1["id"]) |> Enum.sort() ==
             tune |> Enum.map(& &1["id"]) |> Enum.sort()
  end

  describe "failure evidence" do
    defp fe(id, evidence, label, also \\ nil),
      do: %{"id" => id, "evidence" => evidence, "label" => label, "also" => also}

    test "false alarms, misses and wrong classes are counted apart, and `also` is a lenient hit" do
      rows = [
        # fires, right
        fe("a", "2 tests, 1 failure", "test_failed"),
        # fires on narrative: a false alarm
        fe("b", "the security.license_auditor reviewed it", "unclassified"),
        # nothing fires on a real failure: a miss
        fe("c", "the step crashed with an exit status of 137", "test_failed"),
        # fires the secondary reading the raters named in `also`
        fe(
          "d",
          "3 failures, then CompileError on reload",
          "compile_error_unfamiliar",
          "test_failed"
        ),
        # nothing fires, nothing failed
        fe("e", "read the ADR", "unclassified"),
        fe("f", "wrote the moduledoc", "unclassified")
      ]

      r = Corpus.measure_failures(rows)

      assert r.rows == 6
      assert r.fired == 3
      assert r.false_alarms == 1
      assert r.misses == 1
      assert r.wrong_class == 0
      assert r.accuracy == 0.5
      assert r.lenient == 0.667
      assert r.precision == 0.667
      assert r.ambiguous == 1
      assert r.baseline == %{label: "unclassified", accuracy: 0.5}
      assert Enum.sort(r.errors) == ["b", "c"]
    end

    @tag this_repository: true
    test "the committed corpus: a known label, three raters and a confirmation flag on every row" do
      {:ok, policy} = Noetic.Harness.Conductor.policy()
      known = ["unclassified" | Enum.map(policy["classes"], & &1["id"])]
      rows = Corpus.rows(Corpus.failures_path())
      assert length(rows) >= 300

      for r <- rows do
        assert r["label"] in known, "#{r["id"]}: #{r["label"]}"
        assert r["also"] in [nil | known] and r["also"] != r["label"]
        assert r["rater_a"] in known and r["rater_b"] in known
        assert r["adjudicated"] == (r["rater_a"] != r["rater_b"])
        assert r["human_confirmed"] == false
        # Contested means the third rater's answer is neither of the
        # row's recorded readings.
        assert r["rater_c"] in known, r["id"]
        assert r["contested"] == r["rater_c"] not in [r["label"], r["also"]], r["id"]
        refute r["evidence"] =~ ~r{/h[o]me/[a-z]}
      end
    end
  end
end
