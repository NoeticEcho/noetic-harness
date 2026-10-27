defmodule Noetic.Harness.TelemetryTest do
  @moduledoc """
  The collector's job is to stop an impression from becoming an experiment, so
  the tests are about what it refuses to say and what it refuses to round.
  """

  # `async: true` since an earlier change. It was sync because the fixture root was
  # `NOETIC_HARNESS_ROOT`, a VM-global, so a fixture tree here was visible to
  # every other test in the VM. `Noetic.Harness.put_root/1` scopes it to this
  # process and the `Task`s it spawns, so the isolation is per test.
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Fixture, Telemetry}

  # On the pack (`Noetic.Harness.Pack`). The frozen baseline is this
  # repository's, and its tests are tagged `this_repository`.
  setup {Noetic.Harness.Pack, :root}

  defp run(attrs) do
    Map.merge(
      %{
        "id" => "run-1",
        "workflow" => "WF-003",
        "title" => "t",
        "status" => "done",
        "started_at" => "2026-09-20T00:00:00Z",
        "steps" => [],
        "gates" => nil,
        "acknowledged" => nil
      },
      attrs
    )
  end

  defp tree_with(runs, records \\ %{}) do
    runs
    |> Enum.with_index()
    |> Enum.reduce(Fixture.minimal(), fn {run, i}, tree ->
      Map.put(tree, "runs/run-#{i}.json", Map.put(run, "id", "run-#{i}"))
    end)
    |> Map.merge(records)
  end

  describe "a cluster needs a population" do
    test "below the floor it refuses, and says how many more it needs" do
      Fixture.with_tree(tree_with([run(%{})]), fn _root ->
        summary = Telemetry.collect()

        assert {:insufficient, message} = Telemetry.clusters(summary)
        assert message =~ "9 more"

        assert message =~ "anecdote",
               "the refusal has to say why, or the next agent lowers the floor"
      end)
    end

    test "the counts are still reported below the floor — only the reading is withheld" do
      Fixture.with_tree(tree_with([run(%{}), run(%{"status" => "abandoned"})]), fn _root ->
        summary = Telemetry.collect()

        assert summary["population"]["runs"] == 2
        assert summary["runs"]["by_status"]["abandoned"] == 1
      end)
    end

    test "above the floor, a repeatedly unavailable gate is a cluster" do
      runs =
        for _ <- 1..10 do
          run(%{
            "gates" => %{
              "lane" => "release",
              "status" => "partial",
              "results" => [
                %{"id" => "gitleaks", "outcome" => "unavailable", "severity" => "blocking"},
                %{"id" => "format", "outcome" => "passed", "severity" => "blocking"}
              ]
            }
          })
        end

      Fixture.with_tree(tree_with(runs), fn _root ->
        assert {:ok, clusters} = Telemetry.clusters(Telemetry.collect())

        assert [%{"shape" => "gate.unavailable", "subject" => "gitleaks", "count" => 10}] =
                 Enum.filter(clusters, &(&1["shape"] == "gate.unavailable"))

        refute Enum.any?(clusters, &(&1["subject"] == "format")),
               "a gate that passed ten times is not a weakness"
      end)
    end
  end

  describe "what it refuses to guess" do
    test "a run with no structured gate results contributes no gate counts" do
      # Runs written before the ledger recorded results have only the prose
      # summary. Parsing it back out would turn a display string into a
      # contract; counting nothing is the honest alternative.
      legacy = run(%{"gates" => %{"lane" => "focused", "status" => "passed", "summary" => "…"}})

      Fixture.with_tree(tree_with([legacy]), fn _root ->
        summary = Telemetry.collect()

        assert summary["gates"] == %{}
        assert summary["population"]["gate_observations"] == 0
        assert summary["lanes"]["focused"] == %{"passed" => 1}
      end)
    end

    test "a rate with no observations behind it is absent, not zero" do
      Fixture.with_tree(tree_with([run(%{})]), fn _root ->
        metrics = Telemetry.metrics(Telemetry.collect())

        refute Map.has_key?(metrics, "gate_pass_rate"),
               "a zero pass rate and no gates at all are different facts, and " <>
                 "Evolution.gates/1 treats an unmeasured capability as a failure"
      end)
    end

    test "a retired memory record does not count towards its scope" do
      records = %{
        "memory/records/live.json" => %{
          "id" => "mem-live",
          "kind" => "lesson",
          "scope" => ["routing"],
          "created_at" => "2026-09-20T00:00:00Z",
          "status" => "current"
        },
        "memory/records/gone.json" => %{
          "id" => "mem-gone",
          "kind" => "lesson",
          "scope" => ["routing"],
          "created_at" => "2026-09-20T00:00:00Z",
          "status" => "retired"
        }
      }

      Fixture.with_tree(tree_with([], records), fn _root ->
        assert Telemetry.collect()["memory"]["routing"] == 1
      end)
    end
  end

  describe "attempts are counted within a run" do
    test "two runs of the same workflow are not one step retried twice" do
      # The first thing this module got wrong, and the first thing reading its
      # own output showed: grouping step entries across runs made every
      # additional run of WF-002 add a phantom attempt to `context`.
      one_each =
        for _ <- 1..2 do
          run(%{"steps" => [%{"step" => "context", "outcome" => "done"}]})
        end

      Fixture.with_tree(tree_with(one_each), fn _root ->
        stats = Telemetry.collect()["steps"]["WF-003/context"]

        assert stats["runs"] == 2
        assert stats["attempts"] == 2
        assert stats["worst_run"] == 1, "neither run retried anything"
      end)
    end

    test "a step retried inside one run is a retry" do
      retried =
        run(%{
          "steps" => [
            %{"step" => "context", "outcome" => "failed"},
            %{"step" => "context", "outcome" => "done"}
          ]
        })

      Fixture.with_tree(tree_with([retried]), fn _root ->
        stats = Telemetry.collect()["steps"]["WF-003/context"]

        assert stats["runs"] == 1
        assert stats["worst_run"] == 2
        assert stats["by_outcome"] == %{"failed" => 1, "done" => 1}
      end)
    end

    test "the first-try rate does not fall just because more runs happened" do
      clean = fn -> run(%{"steps" => [%{"step" => "context", "outcome" => "done"}]}) end

      Fixture.with_tree(tree_with([clean.()]), fn _root ->
        one = Telemetry.metrics(Telemetry.collect())["step_first_try_rate"]

        Fixture.with_tree(tree_with([clean.(), clean.(), clean.()]), fn _root ->
          three = Telemetry.metrics(Telemetry.collect())["step_first_try_rate"]
          assert one == three
          assert three == 1.0
        end)
      end)
    end
  end

  describe "delta" do
    test "omits a metric that only one side measured" do
      # An experiment that started measuring something has not improved it.
      before = %{"gates" => %{}, "steps" => %{}, "runs" => %{"total" => 0, "by_status" => %{}}}

      aft = %{
        "gates" => %{"format" => %{"passed" => 4}},
        "steps" => %{},
        "runs" => %{"total" => 0, "by_status" => %{}}
      }

      assert Telemetry.delta(before, aft) == %{}
    end

    test "reports an improvement as positive" do
      worse = %{
        "gates" => %{"format" => %{"passed" => 1, "failed" => 1}},
        "steps" => %{},
        "runs" => %{"total" => 0, "by_status" => %{}}
      }

      better = %{
        "gates" => %{"format" => %{"passed" => 4}},
        "steps" => %{},
        "runs" => %{"total" => 0, "by_status" => %{}}
      }

      delta = Telemetry.delta(worse, better)
      assert delta["gate_pass_rate"] == 0.5
    end
  end

  describe "sources it could not read" do
    test "an unreadable source is named, not treated as empty" do
      # Beads is the one source that can be absent on a machine. When `bd` is
      # not answering the summary must say so: an absent source and a source
      # with nothing in it are different facts, and only one of them means
      # "no problems here".
      summary = Telemetry.collect()

      assert is_list(summary["unverified"])

      if summary["unverified"] != [] do
        assert Enum.any?(summary["unverified"], &(&1 =~ "beads"))
      end
    end
  end

  describe "a cluster names the change it implies" do
    # The tool reported exactly two clusters before this bead,
    # and both were artifacts of the population: "23 lessons share the scope
    # `harness`" says where the work was. WF-020's whole intent is "when the
    # same work keeps failing the same way, change the development system", and
    # a cluster that cannot be turned into a change does not serve it.

    defp summary(overrides) do
      Map.merge(
        %{
          "population" => %{"runs" => 20, "memory_records" => 40},
          "runs" => %{"total" => 20, "by_status" => %{"done" => 20}},
          "gates" => %{},
          "steps" => %{},
          "lanes" => %{},
          "memory" => %{},
          "routing" => %{"corrections" => 0}
        },
        overrides
      )
    end

    test "every cluster either names a change or is marked as naming none" do
      {:ok, clusters} =
        Telemetry.clusters(
          summary(%{
            "gates" => %{"typeql.check" => %{"unavailable" => 9, "passed" => 1}},
            "lanes" => %{"release" => %{"partial" => 5, "passed" => 2}},
            "routing" => %{"corrections" => 13},
            "memory" => %{"harness" => 30, "routing" => 4}
          })
        )

      assert clusters != []

      for cluster <- clusters do
        assert Map.has_key?(cluster, "change")
        assert Map.has_key?(cluster, "actionable")

        assert cluster["actionable"] == (cluster["change"] != nil),
               "#{cluster["shape"]} says actionable=#{cluster["actionable"]} with " <>
                 "change=#{inspect(cluster["change"])}"

        if cluster["actionable"] do
          assert String.length(cluster["change"]) > 40,
                 "#{cluster["shape"]}'s change is too short to name anything: " <>
                   cluster["change"]
        end
      end
    end

    test "a scope holding the majority of the corpus names no change" do
      # The bead's own counter-example, and the reason it is the right first
      # one: it passed the floor, it was half of everything the tool said, and
      # it means "this is where the work was".
      {:ok, clusters} = Telemetry.clusters(summary(%{"memory" => %{"harness" => 30}}))

      assert [harness] = Enum.filter(clusters, &(&1["subject"] == "harness"))

      refute harness["actionable"],
             "a scope with 30 of 40 records was reported as something to act on"

      assert harness["reading"] =~ "where the work has been"
    end

    test "the same shape on a minority scope does name one" do
      # Not deleted, demoted. A scope that clusters while *not* being the
      # majority is the signal the shape was reaching for.
      {:ok, clusters} =
        Telemetry.clusters(summary(%{"memory" => %{"harness" => 30, "routing" => 4}}))

      assert [routing] = Enum.filter(clusters, &(&1["subject"] == "routing"))

      assert routing["actionable"]
      assert routing["change"] =~ "noetic-harness memory --query routing"
    end

    test "routing corrections cluster, and an unmeasured count does not" do
      # `nil` is "git could not say", which is not zero. The same rule `Usage`
      # applies to an unknown cost: an unknown is not a low number.
      {:ok, with_count} = Telemetry.clusters(summary(%{"routing" => %{"corrections" => 13}}))
      {:ok, below} = Telemetry.clusters(summary(%{"routing" => %{"corrections" => 2}}))
      {:ok, unmeasured} = Telemetry.clusters(summary(%{"routing" => %{"corrections" => nil}}))

      assert Enum.any?(with_count, &(&1["shape"] == "routing.corrected"))
      refute Enum.any?(below, &(&1["shape"] == "routing.corrected"))

      refute Enum.any?(unmeasured, &(&1["shape"] == "routing.corrected")),
             "an unmeasured correction count produced a cluster, so a repository with no git " <>
               "history reads as one with perfect routing"
    end

    test "a lane that did not pass clusters" do
      # A lane reporting `partial` has an unavailable blocking gate, and the
      # work it guarded is unverified rather than approved. The ledger already
      # stored this and nothing counted it.
      {:ok, clusters} =
        Telemetry.clusters(
          summary(%{"lanes" => %{"release" => %{"partial" => 5, "passed" => 9}}})
        )

      assert [lane] = Enum.filter(clusters, &(&1["shape"] == "lane.partial"))
      assert lane["subject"] == "release"
      assert lane["count"] == 5
      assert lane["of"] == 14
      assert lane["change"] =~ "inspect --tools"
    end

    test "a lane that passed does not" do
      {:ok, clusters} =
        Telemetry.clusters(summary(%{"lanes" => %{"focused" => %{"passed" => 22}}}))

      refute Enum.any?(clusters, &(&1["shape"] =~ "lane.")),
             "a lane that passed 22 times was reported as a weakness"
    end

    test "the population floor applies to the new shapes too" do
      # Three of the same kind out of three observations is all the data there
      # is, whatever the shape. `.agents/policies/evolution.md` now says this
      # for shapes as well as for metrics.
      thin = summary(%{"population" => %{"runs" => 9, "memory_records" => 40}})

      assert {:insufficient, message} =
               Telemetry.clusters(Map.put(thin, "routing", %{"corrections" => 99}))

      assert message =~ "9 run(s)"
    end
  end

  describe "the efficiency metrics, and the baseline they are measured against" do
    # `Evolution.gates/1` requires at least one declared
    # efficiency metric to have improved, and nothing here measured one:
    # `metrics.efficiency` was a list of names and the names pointed at
    # nothing, so "the harness got more efficient" had no denominator.

    defp costed(overrides) do
      Map.merge(
        %{
          "population" => %{"runs" => 4},
          "beads" => %{"closed" => 4, "measured" => 2},
          "usage" => %{
            "messages" => 100,
            "thinking_tokens" => 200,
            "tokens" => %{
              "output_tokens" => 1000,
              "cache_creation_input_tokens" => 2000,
              "cache_read_input_tokens" => 3000,
              "input_tokens" => 40
            },
            "tools" => %{"Bash" => 30, "Read" => 10}
          },
          "steps" => %{"WF-002/plan" => %{"attempts" => 5, "runs" => 4}},
          "hooks" => %{"events" => %{}}
        },
        overrides
      )
    end

    test "every metric is per something, and lower is better" do
      costs = Telemetry.efficiency(costed(%{}))

      assert costs["output_tokens_per_bead"] == 500.0
      assert costs["cache_read_tokens_per_bead"] == 1500.0
      assert costs["tool_calls_per_bead"] == 20.0
      assert costs["messages_per_bead"] == 50.0
      assert costs["attempts_per_step"] == 1.25
    end

    test "a metric with no denominator is absent, not zero" do
      # The rule this repository already holds about an unknown cost: a cost
      # that could not be measured is not a low cost. `Telemetry.diff/2` omits
      # a metric present on only one side, so a zero here would report a
      # candidate as infinitely better than a baseline that never measured it.
      costs = Telemetry.efficiency(costed(%{"beads" => %{"closed" => 4, "measured" => 0}}))

      refute Map.has_key?(costs, "output_tokens_per_bead")
      refute Map.has_key?(costs, "tool_calls_per_bead")

      assert Map.has_key?(costs, "attempts_per_step"),
             "a metric with its own denominator went missing with the bead count"
    end

    test "the hook's overhead is absent below the observation floor" do
      # A median of four is not a median, which is the floor `--clusters`
      # refuses under and the one `Hooks` applies to its own budget.
      thin =
        costed(%{
          "hooks" => %{
            "events" => %{
              "user_prompt" => %{"checked" => false, "p50" => 1, "bytes" => 1, "count" => 4}
            }
          }
        })

      thick =
        costed(%{
          "hooks" => %{
            "events" => %{
              "user_prompt" => %{
                "checked" => true,
                "p50" => 1420,
                "bytes" => 14_450,
                "count" => 21
              }
            }
          }
        })

      refute Map.has_key?(Telemetry.efficiency(thin), "hook_ms_per_prompt")

      costs = Telemetry.efficiency(thick)
      assert costs["hook_ms_per_prompt"] == 1420.0
      assert_in_delta costs["hook_bytes_per_prompt"], 688.1, 0.1
    end

    test "every metric says what would catch it being gamed" do
      # An earlier change is explicit: this bead "does not get to add a metric
      # without also saying which held-out measurement would catch it being
      # gamed". The check is a drift check, so a metric added later without
      # one fails here rather than quietly joining the fitness map.
      costs = Telemetry.efficiency(Telemetry.collect([]))
      questions = Telemetry.gaming_questions()

      for {name, _value} <- costs do
        assert Map.has_key?(questions, name),
               "#{name} is measured and nothing says how it could be gamed. Tokens per bead " <>
                 "falls beautifully if the beads get smaller; say what would catch that."

        assert String.length(questions[name]) > 80
      end
    end

    @tag this_repository: true
    test "the frozen baseline exists, covers what is measured, and says it is provisional" do
      assert {:ok, baseline} = Telemetry.baseline()

      assert baseline["bead"] == "bd-arc.22.6"
      assert baseline["taken_at"]

      for {name, _} <- Telemetry.efficiency(Telemetry.collect([])) do
        assert Map.has_key?(baseline["metrics"], name) or baseline["provisional"],
               "#{name} has no baseline value. A metric added after the baseline was taken " <>
                 "cannot show an improvement against it, and `Evolution.gates/1` must not " <>
                 "count it as one."
      end

      if get_in(baseline, ["population", "beads_measured"]) < 10 do
        assert baseline["provisional"],
               "the baseline was taken below the population floor and does not say so"
      end
    end

    @tag this_repository: true
    test "the baseline refuses to be re-taken" do
      # `.agents/policies/evolution.md`: a tolerance moved after a result is in
      # arrives looking like a result. A baseline moved after a result is in is
      # the same thing one level down, so re-taking it means deleting a
      # committed file — a diff a reviewer can see.
      assert {:error, message} = Telemetry.take_baseline(Telemetry.collect([]))

      assert message =~ "frozen"
      assert message =~ ".agents/evolution/baseline.json"
    end
  end
end
