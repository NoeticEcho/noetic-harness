defmodule Noetic.Harness.EvolutionTest do
  @moduledoc """
  The promotion gate. Every test here is a way a candidate could look better
  than it is.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Evolution, Fixture}

  defp tree, do: Fixture.minimal()

  defp propose(attrs \\ %{}) do
    Evolution.propose(
      Map.merge(
        %{
          target: %{kind: "prompt", ref: "backend.engineer"},
          hypothesis: %{
            weakness: "three TypeQL regressions in a row",
            change: "load the official skill before writing",
            disconfirming_evidence: "regressions continue at the same rate"
          },
          created_by: "evolution.evolution_director",
          family: "prompt_policy",
          metrics: %{
            capability: [%{name: "task_completion", tolerance: 0.02}],
            efficiency: ["typeql_regressions"]
          }
        },
        attrs
      )
    )
  end

  test "a candidate retains its lineage" do
    Fixture.with_tree(tree(), fn _root ->
      {:ok, _} = propose()
      [candidate] = Evolution.list()

      assert candidate["lineage"]["parents"] == []
      assert candidate["lineage"]["generation"] == 0

      {:ok, _} = propose(%{id: "cand-2026-01-01-child", parents: [candidate["id"]]})
      {:ok, child} = Evolution.fetch("cand-2026-01-01-child")

      assert child["lineage"]["parents"] == [candidate["id"]]
      assert child["lineage"]["generation"] == 1

      assert Enum.map(Evolution.lineage("cand-2026-01-01-child"), & &1["id"])
             |> Enum.member?(candidate["id"])
    end)
  end

  test "a hypothesis with nothing that could disconfirm it is refused" do
    Fixture.with_tree(tree(), fn _root ->
      assert {:error, message} =
               propose(%{hypothesis: %{weakness: "slow", change: "faster"}})

      assert message =~ "disconfirming_evidence"
      assert message =~ "preference"
    end)
  end

  test "evaluations are stored on the candidate" do
    Fixture.with_tree(tree(), fn _root ->
      {:ok, _} = propose()
      [%{"id" => id}] = Evolution.list()

      {:ok, _} =
        Evolution.record_stage(id, "benchmark", %{
          by: "qa.qa_architect",
          outcome: "passed",
          fitness: %{"benchmark" => 0.4}
        })

      {:ok, candidate} = Evolution.fetch(id)

      assert candidate["stages"]["benchmark"]["outcome"] == "passed"
      assert candidate["fitness"]["benchmark"] == 0.4
    end)
  end

  test "a holdout run by the candidate's author is refused, not recorded with a caveat" do
    Fixture.with_tree(tree(), fn _root ->
      {:ok, _} = propose()
      [%{"id" => id}] = Evolution.list()

      assert {:error, message} =
               Evolution.record_stage(id, "holdout", %{
                 by: "evolution.evolution_director",
                 outcome: "passed",
                 independent: true
               })

      assert message =~ "who proposed this candidate"

      assert {:error, other} =
               Evolution.record_stage(id, "holdout", %{
                 by: "qa.qa_architect",
                 outcome: "passed",
                 independent: false
               })

      assert other =~ "must be recorded as independent"
    end)
  end

  test "promotion is refused when a stage was never run, and it names which" do
    Fixture.with_tree(tree(), fn _root ->
      {:ok, _} = propose()
      [%{"id" => id}] = Evolution.list()

      {:ok, _} = Evolution.record_stage(id, "sandbox", %{by: "x", outcome: "passed"})
      {:ok, candidate} = Evolution.fetch(id)

      assert {:error, reasons} = Evolution.promotable?(candidate)
      assert Enum.any?(reasons, &(&1 =~ "holdout has not been run"))
      assert Enum.any?(reasons, &(&1 =~ "transfer has not been run"))
      assert Enum.any?(reasons, &(&1 =~ "anti_goodhart has not been run"))
    end)
  end

  defp pass_every_stage(id) do
    for stage <- ~w(sandbox benchmark archive) do
      {:ok, _} =
        Evolution.record_stage(id, stage, %{
          by: "evolution.evolution_director",
          outcome: "passed"
        })
    end

    # `transfer` is a held-out set, so it is one of the stages that must be
    # recorded independently — a transfer measured by the candidate's own
    # author is a second benchmark over unfamiliar tasks.
    for stage <- ~w(holdout anti_goodhart transfer) do
      {:ok, _} =
        Evolution.record_stage(id, stage, %{
          by: "evolution.anti_goodhart_agent",
          outcome: "passed",
          independent: true,
          # Both declared metrics measured: capability held, efficiency moved.
          fitness: %{"task_completion" => 0.0, "typeql_regressions" => 0.4}
        })
    end
  end

  test "a complete, independently evidenced candidate is eligible" do
    Fixture.with_tree(tree(), fn _root ->
      {:ok, _} = propose()
      [%{"id" => id}] = Evolution.list()
      pass_every_stage(id)

      {:ok, candidate} = Evolution.fetch(id)
      assert :ok = Evolution.promotable?(candidate)
    end)
  end

  describe "a set-keyed number nobody can point at a run for" do
    defp environment(id, set) do
      %{
        "id" => id,
        "title" => id,
        "statement" => "something was observed to be wrong",
        "source" => %{
          "kind" => "fix_commit",
          "repository" => "self",
          "fix" => String.duplicate("a", 40),
          "parent" => String.duplicate("b", 40),
          "subject" => "the answer sheet",
          "bead" => nil
        },
        "verifier" => %{
          "kind" => "reverse_patch",
          "app" => "acme",
          "files" => ["test/acme/#{id}_test.exs"],
          "source_paths" => ["apps/acme/lib/acme/#{id}.ex"]
        },
        "set" => set,
        "verification" => %{
          "state" => "verified",
          "failed_before" => true,
          "passed_after" => true,
          "by" => "test",
          "by_attested" => false,
          "reason" => "because"
        },
        "verification_history" => []
      }
    end

    @scoring_run "run-2026-09-21-wf-010-x"

    defp tree_with_suite(environments) do
      tree()
      |> Map.merge(
        Map.new(environments, fn e -> {"evolution/environments/#{e["id"]}.json", e} end)
      )
      # A run the provenance can point at. It has to be a file in the ledger,
      # not just a non-empty string — see `named/2`.
      |> Map.put("runs/#{@scoring_run}.json", %{
        "id" => @scoring_run,
        "workflow" => "WF-010",
        "status" => "closed",
        "steps" => []
      })
    end

    defp candidate_scoring(fitness, provenance) do
      %{
        "id" => "cand-x",
        "fitness" => fitness,
        "fitness_provenance" => provenance,
        "metrics" => %{},
        "stages" => %{}
      }
    end

    test "the set keys are the environment sets, not two lists that happen to agree" do
      assert Evolution.set_keys() == Noetic.Harness.Environments.sets()
    end

    test "a benchmark number with no provenance was typed, not measured" do
      Fixture.with_tree(tree(), fn _ ->
        reasons = Evolution.unmeasured(candidate_scoring(%{"benchmark" => 0.4}, %{}))

        assert Enum.any?(reasons, &(&1 =~ "typed, not measured"))
        assert Enum.any?(reasons, &(&1 =~ "fitness_provenance.benchmark"))
      end)
    end

    test "provenance that names no run leaves nothing to go and read" do
      Fixture.with_tree(tree(), fn _ ->
        reasons =
          Evolution.unmeasured(
            candidate_scoring(%{"benchmark" => 0.4}, %{"benchmark" => %{"environments" => []}})
          )

        assert Enum.any?(reasons, &(&1 =~ "names no run"))
      end)
    end

    test "provenance over exactly the set's verified members is accepted" do
      seeded = [environment("env-one", "benchmark"), environment("env-two", "benchmark")]

      Fixture.with_tree(tree_with_suite(seeded), fn _ ->
        candidate =
          candidate_scoring(%{"benchmark" => 0.4}, %{
            "benchmark" => %{
              "run" => @scoring_run,
              "environments" => ["env-one", "env-two"]
            }
          })

        assert Evolution.unmeasured(candidate) == []
      end)
    end

    test "a member that has since stopped verifying makes the number about a suite that is gone" do
      seeded = [environment("env-one", "benchmark")]

      Fixture.with_tree(tree_with_suite(seeded), fn _ ->
        candidate =
          candidate_scoring(%{"benchmark" => 0.4}, %{
            "benchmark" => %{
              "run" => @scoring_run,
              "environments" => ["env-one", "env-gone"]
            }
          })

        reasons = Evolution.unmeasured(candidate)
        assert Enum.any?(reasons, &(&1 =~ "env-gone"))
        assert Enum.any?(reasons, &(&1 =~ "no longer exists"))
      end)
    end

    test "a member added since makes the number a rate over part of a suite" do
      seeded = [environment("env-one", "benchmark"), environment("env-new", "benchmark")]

      Fixture.with_tree(tree_with_suite(seeded), fn _ ->
        candidate =
          candidate_scoring(%{"benchmark" => 0.4}, %{
            "benchmark" => %{
              "run" => @scoring_run,
              "environments" => ["env-one"]
            }
          })

        reasons = Evolution.unmeasured(candidate)
        assert Enum.any?(reasons, &(&1 =~ "env-new"))
        assert Enum.any?(reasons, &(&1 =~ "part of a suite"))
      end)
    end

    test "a run id that resolves to nothing is a number nobody can check" do
      seeded = [environment("env-one", "benchmark")]

      Fixture.with_tree(tree_with_suite(seeded), fn _ ->
        candidate =
          candidate_scoring(%{"benchmark" => 0.4}, %{
            "benchmark" => %{
              "run" => "run-0000-00-00-wf-000-does-not-exist",
              "environments" => ["env-one"]
            }
          })

        reasons = Evolution.unmeasured(candidate)
        assert Enum.any?(reasons, &(&1 =~ "no such run in the ledger"))
      end)
    end

    test "a set with no verified members left cannot be measured over" do
      # The guard used to compare two sets and an empty one made both
      # differences empty, so any provenance was accepted — at exactly the
      # moment a number about that set is worth the least. A set empties by its
      # members becoming `unavailable`, and three of thirteen already are.
      Fixture.with_tree(tree_with_suite([]), fn _ ->
        candidate =
          candidate_scoring(%{"transfer" => 0.4}, %{
            "transfer" => %{"run" => @scoring_run, "environments" => []}
          })

        reasons = Evolution.unmeasured(candidate)
        assert Enum.any?(reasons, &(&1 =~ "no currently verified members"))
      end)
    end

    test "a malformed fitness_provenance is reported, not raised" do
      # `noetic-harness validate` calls this. A gate that crashes on one bad file
      # is a gate nobody can read.
      Fixture.with_tree(tree(), fn _ ->
        for bad <- ["a string", ["a", "list"], 42] do
          reasons =
            Evolution.unmeasured(%{
              "id" => "cand-x",
              "fitness" => %{"benchmark" => 0.4},
              "fitness_provenance" => bad
            })

          assert Enum.any?(reasons, &(&1 =~ "not a record of what was run"))
        end

        reasons =
          Evolution.unmeasured(%{"id" => "cand-x", "fitness" => "a string"})

        assert Enum.any?(reasons, &(&1 =~ "not a map of measurements"))
      end)
    end

    test "a set-keyed value that is not a number measures nothing and says so" do
      # A string defeated `gates/1`, `goodhart_signature/1` and the provenance
      # check at once, while `--show` printed it as a benchmark gain.
      Fixture.with_tree(tree(), fn _ ->
        for value <- ["0.4", nil, true] do
          reasons = Evolution.unmeasured(candidate_scoring(%{"benchmark" => value}, %{}))
          assert Enum.any?(reasons, &(&1 =~ "which is not a number and measures nothing"))
        end
      end)
    end

    test "an environments list that is not a list of ids is refused" do
      seeded = [environment("env-one", "benchmark")]

      Fixture.with_tree(tree_with_suite(seeded), fn _ ->
        for bad <- ["env-one", 42, %{"a" => 1}] do
          candidate =
            candidate_scoring(%{"benchmark" => 0.4}, %{
              "benchmark" => %{"run" => @scoring_run, "environments" => bad}
            })

          assert Enum.any?(Evolution.unmeasured(candidate), &(&1 =~ "environments"))
        end
      end)
    end

    test "a typed number cannot eliminate a measured candidate from the shortlist" do
      seeded = [environment("env-one", "benchmark")]

      Fixture.with_tree(tree_with_suite(seeded), fn _ ->
        typed = candidate_scoring(%{"benchmark" => 0.9}, %{}) |> Map.put("id", "cand-typed")

        measured =
          candidate_scoring(%{"benchmark" => 0.4}, %{
            "benchmark" => %{"run" => @scoring_run, "environments" => ["env-one"]}
          })
          |> Map.put("id", "cand-measured")

        # `promotable?/1` was guarded and this was not, so a hand-typed number
        # could delete a real result from the set a human chooses from.
        ids = Evolution.nondominated([typed, measured]) |> Enum.map(& &1["id"])

        assert "cand-measured" in ids
      end)
    end

    test "the refusal names the set that actually fired" do
      candidate = %{"fitness" => %{"benchmark" => 0.5, "holdout" => 0.5, "transfer" => 0.0}}

      assert Evolution.goodhart_signature(candidate) == ["transfer"]

      refused =
        candidate
        |> Map.merge(%{"id" => "c", "stages" => %{}, "metrics" => %{}})
        |> Evolution.promotable?()

      assert {:error, reasons} = refused
      assert Enum.any?(reasons, &(&1 =~ "transfer did not"))
      refute Enum.any?(reasons, &(&1 =~ "holdout did not"))
    end

    test "a metric that is not a set name is not governed this way" do
      Fixture.with_tree(tree(), fn _ ->
        # Capability and efficiency metrics are declared per candidate and
        # measured however that candidate's hypothesis says. Only the three
        # the anti-Goodhart machinery rests on need a run behind them.
        candidate = candidate_scoring(%{"typeql_regressions" => 0.4}, %{})

        assert Evolution.unmeasured(candidate) == []
      end)
    end

    test "a benchmark gain with a flat transfer is the signature too" do
      # `transfer` is a required stage and the Goodhart check could not see it,
      # so a candidate could pass a transfer whose number never entered a gate.
      assert Evolution.goodhart_signature?(%{
               "fitness" => %{"benchmark" => 0.9, "transfer" => 0.0}
             })

      refute Evolution.goodhart_signature?(%{
               "fitness" => %{"benchmark" => 0.9, "transfer" => 0.3}
             })
    end

    test "a promotion is refused for a typed number, naming it" do
      Fixture.with_tree(tree(), fn _ ->
        {:ok, _} = propose()
        [%{"id" => id}] = Evolution.list()

        for stage <- ~w(sandbox benchmark archive) do
          {:ok, _} =
            Evolution.record_stage(id, stage, %{
              by: "evolution.evolution_director",
              outcome: "passed"
            })
        end

        # `transfer` is a held-out set, so it is one of the stages that must be
        # recorded independently — a transfer measured by the candidate's own
        # author is a second benchmark over unfamiliar tasks.
        for stage <- ~w(holdout anti_goodhart transfer) do
          {:ok, _} =
            Evolution.record_stage(id, stage, %{
              by: "evolution.anti_goodhart_agent",
              outcome: "passed",
              independent: true,
              fitness: %{"task_completion" => 0.0, "typeql_regressions" => 0.4}
            })
        end

        # Everything else about this candidate is in order. One hand-typed
        # benchmark number is the whole difference.
        {:ok, _} =
          Evolution.record_stage(id, "benchmark", %{
            by: "evolution.evolution_director",
            outcome: "passed",
            fitness: %{"benchmark" => 0.4}
          })

        {:ok, candidate} = Evolution.fetch(id)

        assert {:error, reasons} = Evolution.promotable?(candidate)
        assert Enum.any?(reasons, &(&1 =~ "typed, not measured"))
      end)
    end

    test "provenance recorded with the number travels through record_stage" do
      Fixture.with_tree(tree(), fn _ ->
        {:ok, _} = propose()
        [%{"id" => id}] = Evolution.list()

        {:ok, _} =
          Evolution.record_stage(id, "benchmark", %{
            by: "evolution.evolution_director",
            outcome: "passed",
            fitness: %{"benchmark" => 0.4},
            fitness_provenance: %{
              "benchmark" => %{"run" => "run-x", "environments" => []}
            }
          })

        {:ok, candidate} = Evolution.fetch(id)
        assert candidate["fitness_provenance"]["benchmark"]["run"] == "run-x"
      end)
    end
  end

  describe "a candidate may not be promoted on evidence it produced" do
    defp run_file(id, parent \\ nil) do
      %{
        "id" => id,
        "workflow" => "WF-010",
        "status" => "open",
        "steps" => [],
        "dispatches" => [],
        "parent_run" => parent
      }
    end

    defp scored(candidate_run, set, scoring_run) do
      %{
        "id" => "cand-x",
        "run" => candidate_run,
        "fitness" => %{set => 0.4},
        "fitness_provenance" => %{
          set => %{"run" => scoring_run, "environments" => ["env-one"]}
        },
        "metrics" => %{},
        "stages" => %{}
      }
    end

    defp with_runs(runs, environments, fun) do
      tree()
      |> Map.merge(Map.new(runs, fn run -> {"runs/#{run["id"]}.json", run} end))
      |> Map.merge(
        Map.new(environments, fn e -> {"evolution/environments/#{e["id"]}.json", e} end)
      )
      |> Fixture.with_tree(fn _ -> fun.() end)
    end

    test "a holdout measured by the candidate's own run is refused" do
      with_runs([run_file("run-a")], [environment("env-one", "holdout")], fn ->
        reasons = Evolution.held_out_by_its_own_run(scored("run-a", "holdout", "run-a"))

        assert Enum.any?(reasons, &(&1 =~ "the candidate's own run"))
        assert Enum.any?(reasons, &(&1 =~ "is not held out"))
      end)
    end

    test "a holdout measured by a run the candidate's run dispatched is refused too" do
      # The laundering path: start a child run and score from there. `depth/1`
      # and `stopped?/1` already walk `parent_run` for exactly this reason.
      runs = [run_file("run-a"), run_file("run-child", "run-a")]

      with_runs(runs, [environment("env-one", "holdout")], fn ->
        reasons = Evolution.held_out_by_its_own_run(scored("run-a", "holdout", "run-child"))
        assert reasons != []
      end)
    end

    test "a holdout measured by an unrelated run is not refused" do
      runs = [run_file("run-a"), run_file("run-b")]

      with_runs(runs, [environment("env-one", "holdout")], fn ->
        assert Evolution.held_out_by_its_own_run(scored("run-a", "holdout", "run-b")) == []
      end)
    end

    test "the benchmark is not held out, so its own run may measure it" do
      # The benchmark is the suite a candidate was allowed to see. Refusing the
      # author's own benchmark run would refuse the ordinary case.
      with_runs([run_file("run-a")], [environment("env-one", "benchmark")], fn ->
        assert Evolution.held_out_by_its_own_run(scored("run-a", "benchmark", "run-a")) == []
      end)
    end

    # A control, and then one field changed.
    #
    # The first version of this test asserted a string in a candidate that was
    # already unpromotable for seven other reasons: `promotable?/1` answered
    # `{:error, _}` with the check and without it, and the assertion passed on
    # a reason list that happened to contain the right sentence. An independent
    # review pointed out that a guard is calibrated by the case it is the *only*
    # thing standing in the way of. So `promotable/1` below builds a candidate
    # that is genuinely eligible — every stage recorded, both declared metrics
    # measured, the holdout number carrying provenance over the whole verified
    # suite — and each test changes exactly one thing about who measured it.
    defp promotable(scoring_run, candidate_run \\ "run-a") do
      {:ok, _} = propose(%{run: candidate_run})
      [%{"id" => id}] = Evolution.list()

      for stage <- ~w(sandbox benchmark archive) do
        {:ok, _} =
          Evolution.record_stage(id, stage, %{by: "evolution.director", outcome: "passed"})
      end

      for stage <- ~w(holdout transfer anti_goodhart) do
        {:ok, _} =
          Evolution.record_stage(id, stage, %{
            by: "evolution.anti_goodhart_agent",
            outcome: "passed",
            independent: true,
            fitness: %{"task_completion" => 0.0, "typeql_regressions" => 0.4}
          })
      end

      {:ok, candidate} = Evolution.fetch(id)

      Map.merge(candidate, %{
        "fitness" => Map.put(candidate["fitness"], "holdout", 0.4),
        "fitness_provenance" => %{
          "holdout" => %{"run" => scoring_run, "environments" => ["env-one"]}
        }
      })
    end

    test "CONTROL: the same candidate, measured by an unrelated run, is promotable" do
      with_runs([run_file("run-a"), run_file("run-b")], [environment("env-one", "holdout")], fn ->
        assert :ok = Evolution.promotable?(promotable("run-b"))
      end)
    end

    test "a promotion is refused for a self-scored holdout, naming it" do
      with_runs([run_file("run-a"), run_file("run-b")], [environment("env-one", "holdout")], fn ->
        assert {:error, reasons} = Evolution.promotable?(promotable("run-a"))
        assert Enum.any?(reasons, &(&1 =~ "the candidate's own run"))
      end)
    end

    test "a promotion is refused when the scoring run is a child of the candidate's" do
      runs = [run_file("run-a"), run_file("run-b"), run_file("run-child", "run-a")]

      with_runs(runs, [environment("env-one", "holdout")], fn ->
        assert {:error, reasons} = Evolution.promotable?(promotable("run-child"))
        assert Enum.any?(reasons, &(&1 =~ "dispatched"))
      end)
    end

    test "a space is not a different run" do
      # `" run-a "` satisfied `Run.exists?/1`, which trimmed, and defeated the
      # ancestor walk, which did not. One space promoted a candidate that had
      # scored its own holdout.
      with_runs([run_file("run-a"), run_file("run-b")], [environment("env-one", "holdout")], fn ->
        assert {:error, reasons} = Evolution.promotable?(promotable(" run-a "))
        assert Enum.any?(reasons, &(&1 =~ "the candidate's own run"))
      end)
    end

    test "a candidate that records no run at all is refused rather than exempted" do
      with_runs([run_file("run-a"), run_file("run-b")], [environment("env-one", "holdout")], fn ->
        candidate = promotable("run-b") |> Map.delete("run")

        assert {:error, reasons} = Evolution.promotable?(candidate)
        assert Enum.any?(reasons, &(&1 =~ "independence cannot be established"))
      end)
    end

    test "a candidate whose own run is not in the ledger is refused" do
      with_runs([run_file("run-a"), run_file("run-b")], [environment("env-one", "holdout")], fn ->
        candidate = promotable("run-b", "run-a") |> Map.put("run", "run-nowhere")

        assert {:error, reasons} = Evolution.promotable?(candidate)
        assert Enum.any?(reasons, &(&1 =~ "no such run in the ledger"))
      end)
    end

    test "a candidate records the run it was proposed in" do
      Fixture.with_tree(
        Map.put(tree(), "runs/run-open.json", %{
          "id" => "run-open",
          "workflow" => "WF-010",
          "status" => "open",
          "steps" => []
        }),
        fn _ ->
          {:ok, _} = propose()
          [candidate] = Evolution.list()

          assert candidate["run"] == "run-open"
        end
      )
    end
  end

  describe "the two acceptance gates" do
    test "an unmeasured capability metric is a failure, not a pass" do
      Fixture.with_tree(tree(), fn _root ->
        candidate = %{
          "metrics" => %{
            "capability" => [%{"name" => "task_completion", "tolerance" => 0.02}],
            "efficiency" => ["typeql_regressions"]
          },
          "fitness" => %{"typeql_regressions" => 0.4}
        }

        assert {:error, reasons} = Evolution.gates(candidate)
        assert Enum.any?(reasons, &(&1 =~ "never measured"))
      end)
    end

    test "a capability regression past its tolerance fails however good the efficiency is" do
      candidate = %{
        "metrics" => %{
          "capability" => [%{"name" => "task_completion", "tolerance" => 0.02}],
          "efficiency" => ["tokens"]
        },
        "fitness" => %{"task_completion" => -0.4, "tokens" => 0.9}
      }

      assert {:error, reasons} = Evolution.gates(candidate)
      assert Enum.any?(reasons, &(&1 =~ "past its tolerance"))
    end

    test "a movement inside the tolerance is not a regression" do
      candidate = %{
        "metrics" => %{
          "capability" => [%{"name" => "task_completion", "tolerance" => 0.05}],
          "efficiency" => ["tokens"]
        },
        "fitness" => %{"task_completion" => -0.01, "tokens" => 0.3}
      }

      assert :ok = Evolution.gates(candidate)
    end

    test "breaking nothing and improving nothing is not a candidate" do
      candidate = %{
        "metrics" => %{
          "capability" => [%{"name" => "task_completion", "tolerance" => 0.05}],
          "efficiency" => ["tokens"]
        },
        "fitness" => %{"task_completion" => 0.0, "tokens" => 0.0}
      }

      assert {:error, reasons} = Evolution.gates(candidate)
      assert Enum.any?(reasons, &(&1 =~ "no declared efficiency metric improved"))
    end
  end

  describe "a failed holdout is one-way" do
    test "it closes the candidate and refuses further stages" do
      Fixture.with_tree(tree(), fn _root ->
        {:ok, _} = propose()
        [%{"id" => id}] = Evolution.list()

        {:ok, _} =
          Evolution.record_stage(id, "holdout", %{
            by: "evolution.anti_goodhart_agent",
            outcome: "failed",
            independent: true
          })

        {:ok, candidate} = Evolution.fetch(id)
        assert candidate["status"] == "rejected"
        assert candidate["rejected_at"] =~ "holdout"

        assert {:error, message} =
                 Evolution.record_stage(id, "sandbox", %{
                   by: "evolution.evolution_director",
                   outcome: "passed"
                 })

        assert message =~ "new candidate",
               "the refusal must name the way forward, or it reads as a bug rather than a rule"
      end)
    end

    test "a rejected candidate is not promotable even with every stage passed later" do
      candidate = %{
        "id" => "cand-x",
        "status" => "rejected",
        "rejected_at" => "holdout: failed",
        "stages" => %{},
        "metrics" => %{"capability" => [], "efficiency" => []},
        "fitness" => %{}
      }

      assert {:error, reasons} = Evolution.promotable?(candidate)
      assert Enum.any?(reasons, &(&1 =~ "closed at holdout"))
    end
  end

  describe "frozen metrics" do
    test "a stage result may not carry metrics" do
      Fixture.with_tree(tree(), fn _root ->
        {:ok, _} = propose()
        [%{"id" => id}] = Evolution.list()

        assert {:error, message} =
                 Evolution.record_stage(id, "sandbox", %{
                   by: "evolution.evolution_director",
                   outcome: "passed",
                   metrics: %{capability: [], efficiency: ["tokens"]}
                 })

        assert message =~ "frozen"
      end)
    end

    test "a proposal with no capability metric is refused" do
      Fixture.with_tree(tree(), fn _root ->
        assert {:error, message} =
                 propose(%{metrics: %{capability: [], efficiency: ["tokens"]}})

        assert message =~ "capability is required"
      end)
    end
  end

  describe "the nondominated set" do
    test "keeps a candidate that is better at one thing and worse at another" do
      a = %{"id" => "a", "fitness" => %{"speed" => 1.0, "accuracy" => 0.0}}
      b = %{"id" => "b", "fitness" => %{"speed" => 0.0, "accuracy" => 1.0}}

      assert Enum.map(Evolution.nondominated([a, b]), & &1["id"]) == ["a", "b"]
    end

    test "drops one that is beaten on everything" do
      good = %{"id" => "good", "fitness" => %{"speed" => 1.0, "accuracy" => 1.0}}
      worse = %{"id" => "worse", "fitness" => %{"speed" => 0.5, "accuracy" => 0.5}}

      assert Enum.map(Evolution.nondominated([good, worse]), & &1["id"]) == ["good"]
    end

    test "candidates sharing no measured metric cannot dominate each other" do
      a = %{"id" => "a", "fitness" => %{"speed" => 1.0}}
      b = %{"id" => "b", "fitness" => %{"accuracy" => 0.1}}

      assert length(Evolution.nondominated([a, b])) == 2
    end

    test "there is still no scalar score" do
      # The whole point of a nondominated set is that it does not rank. If a
      # `score/1` appears here, somebody has decided a candidate better at
      # three things and worse at one can be summarised as a number.
      exports = Evolution.__info__(:functions) |> Keyword.keys() |> Enum.map(&to_string/1)
      refute "score" in exports
      refute "rank" in exports
    end
  end

  test "a benchmark gain with a flat holdout is refused: the Goodhart signature" do
    Fixture.with_tree(tree(), fn _root ->
      {:ok, _} = propose()
      [%{"id" => id}] = Evolution.list()

      for stage <- ~w(sandbox archive) do
        {:ok, _} =
          Evolution.record_stage(id, stage, %{
            by: "evolution.evolution_director",
            outcome: "passed"
          })
      end

      {:ok, _} =
        Evolution.record_stage(id, "benchmark", %{
          by: "evolution.evolution_director",
          outcome: "passed",
          fitness: %{"benchmark" => 0.9}
        })

      {:ok, _} =
        Evolution.record_stage(id, "holdout", %{
          by: "evolution.anti_goodhart_agent",
          outcome: "passed",
          independent: true,
          fitness: %{"holdout" => 0.0}
        })

      for stage <- ~w(anti_goodhart transfer) do
        {:ok, _} =
          Evolution.record_stage(id, stage, %{
            by: "evolution.anti_goodhart_agent",
            outcome: "passed",
            independent: true
          })
      end

      {:ok, candidate} = Evolution.fetch(id)

      assert Evolution.goodhart_signature?(candidate)
      assert {:error, reasons} = Evolution.promotable?(candidate)
      assert Enum.any?(reasons, &(&1 =~ "quarantine"))
    end)
  end

  test "archiving preserves the candidate and its evidence" do
    Fixture.with_tree(tree(), fn _root ->
      {:ok, _} = propose()
      [%{"id" => id}] = Evolution.list()
      {:ok, _} = Evolution.record_stage(id, "benchmark", %{by: "x", outcome: "failed"})

      {:ok, _} = Evolution.archive(id, "quarantined", "holdout did not move")

      assert Evolution.list() == []
      {:ok, archived} = Evolution.fetch(id)
      assert archived["status"] == "quarantined"
      assert archived["quarantine_reason"] == "holdout did not move"
      assert archived["stages"]["benchmark"]["outcome"] == "failed"
    end)
  end

  describe "archiving moves a live candidate, once" do
    # `archive/3` read the candidate from either directory, wrote
    # `archive/<id>.json` and removed the path it had read. For an archived
    # candidate that is the same file: it returned `{:ok, path}` and the
    # candidate was gone. The same call relabelled a rejected candidate
    # `promoted` without asking `promotable?/1`.

    test "a candidate already archived is refused, and is still there" do
      Fixture.with_tree(tree(), fn _root ->
        {:ok, _} = propose()
        [%{"id" => id}] = Evolution.list()
        {:ok, path} = Evolution.archive(id, "quarantined", "holdout did not move")

        assert {:error, message} = Evolution.archive(id, "archived", "tidying up")
        assert message =~ "already archived"

        assert File.exists?(path)
        assert {:ok, archived} = Evolution.fetch(id)
        assert archived["status"] == "quarantined"
        assert archived["quarantine_reason"] == "holdout did not move"
      end)
    end

    test "a live candidate whose archive file exists does not overwrite it" do
      Fixture.with_tree(tree(), fn root ->
        {:ok, live} = propose()
        id = Path.basename(live, ".json")
        archived = Path.join([root, ".agents", "evolution", "archive", "#{id}.json"])
        File.mkdir_p!(Path.dirname(archived))
        File.write!(archived, ~s({"id": "#{id}", "status": "quarantined"}\n))

        assert {:error, message} = Evolution.archive(id, "archived", "tidying up")
        assert message =~ "already archived"

        assert File.read!(archived) == ~s({"id": "#{id}", "status": "quarantined"}\n)
        assert File.exists?(live)
      end)
    end

    test "a rejected candidate is not archived as promoted, and stays as it was" do
      Fixture.with_tree(tree(), fn _root ->
        {:ok, path} = propose()
        id = Path.basename(path, ".json")

        {:ok, _} =
          Evolution.record_stage(id, "holdout", %{
            by: "evolution.anti_goodhart_agent",
            outcome: "failed",
            independent: true
          })

        before = File.read!(path)

        assert {:error, message} = Evolution.archive(id, "promoted", "it scored well")
        assert message =~ "not promotable"
        assert message =~ "closed at holdout"

        assert File.read!(path) == before
        assert [%{"status" => "rejected"}] = Evolution.list()
      end)
    end

    test "CONTROL: a promotable candidate is archived as promoted, and validates" do
      Fixture.with_tree(tree(), fn _root ->
        {:ok, path} = propose()
        id = Path.basename(path, ".json")
        pass_every_stage(id)

        assert {:ok, _} = Evolution.archive(id, "promoted", "landed by a person")
        assert {:ok, %{"status" => "promoted"}} = Evolution.fetch(id)
        refute Enum.any?(Evolution.validate(), &(&1 =~ id))
      end)
    end
  end

  describe "a stage is recorded into a live candidate only" do
    # `record_stage/3` found the candidate in either directory, as `archive/3`
    # did before an earlier change, and refused only a `rejected` one. So a stage
    # could be written into a candidate archived as promoted: its status went
    # back to `running` inside the archive, and how it ended was rewritten.

    test "a candidate archived as promoted is refused, and is still as it ended" do
      Fixture.with_tree(tree(), fn _root ->
        {:ok, path} = propose()
        id = Path.basename(path, ".json")
        pass_every_stage(id)
        {:ok, archived} = Evolution.archive(id, "promoted", "landed by a person")
        before = File.read!(archived)

        assert {:error, message} =
                 Evolution.record_stage(id, "benchmark", %{by: "x", outcome: "failed"})

        assert message =~ "already archived"

        assert File.read!(archived) == before
        assert {:ok, %{"status" => "promoted"}} = Evolution.fetch(id)
        refute Enum.any?(Evolution.validate(), &(&1 =~ id))
      end)
    end

    test "a live candidate whose archive file exists is refused, and neither file changes" do
      Fixture.with_tree(tree(), fn root ->
        {:ok, live} = propose()
        id = Path.basename(live, ".json")
        archived = Path.join([root, ".agents", "evolution", "archive", "#{id}.json"])
        File.mkdir_p!(Path.dirname(archived))
        File.write!(archived, ~s({"id": "#{id}", "status": "quarantined"}\n))
        before = File.read!(live)

        assert {:error, message} =
                 Evolution.record_stage(id, "benchmark", %{by: "x", outcome: "passed"})

        assert message =~ "already archived"

        assert File.read!(archived) == ~s({"id": "#{id}", "status": "quarantined"}\n)
        assert File.read!(live) == before
      end)
    end

    test "CONTROL: a live candidate records its stage" do
      Fixture.with_tree(tree(), fn _root ->
        {:ok, path} = propose()
        id = Path.basename(path, ".json")

        assert {:ok, ^path} =
                 Evolution.record_stage(id, "benchmark", %{by: "x", outcome: "passed"})

        assert {:ok, %{"status" => "running", "stages" => %{"benchmark" => %{}}}} =
                 Evolution.fetch(id)
      end)
    end
  end

  test "a candidate marked promoted without the evidence is a validation failure" do
    Fixture.with_tree(tree(), fn root ->
      {:ok, path} = propose()

      content =
        File.read!(path) |> String.replace(~s("status": "proposed"), ~s("status": "promoted"))

      File.write!(path, content)

      assert root != nil
      problems = Evolution.validate()
      assert Enum.any?(problems, &(&1 =~ "marked promoted"))
    end)
  end

  describe "a cluster becomes a candidate" do
    # A design note said what was missing: "nothing
    # *proposes* candidates". `propose/1` existed, scoring existed, the
    # promotion gate existed. The absent link was the one between a cluster
    # that survived the population floor and a candidate with a hypothesis.

    @baseline %{
      "taken_at" => "2026-09-22T00:00:00Z",
      "metrics" => %{
        "output_tokens_per_bead" => 4_063_126.5,
        "attempts_per_step" => 1.04,
        "tool_calls_per_bead" => 4851.5
      }
    }

    defp with_baseline(fun) do
      tree = Map.put(Fixture.minimal(), "evolution/baseline.json", @baseline)
      Fixture.with_tree(tree, fn _root -> fun.() end)
    end

    defp cluster(overrides) do
      Map.merge(
        %{
          "shape" => "routing.corrected",
          "subject" => ".agents/registry/signals.json",
          "count" => 13,
          "of" => 13,
          "reading" => "routing was corrected 13 times",
          "change" => "Route the last three corrected titles again with `--explain`.",
          "actionable" => true
        },
        overrides
      )
    end

    test "the candidate carries the cluster as its weakness and the change as its change" do
      with_baseline(fn ->
        assert {:ok, path} = Evolution.from_cluster(cluster(%{}))
        {:ok, candidate} = Evolution.fetch(Path.basename(path, ".json"))

        assert candidate["target"] == %{
                 "kind" => "signals",
                 "ref" => ".agents/registry/signals.json"
               }

        assert candidate["family"] == "delegation"
        assert candidate["status"] == "proposed"
        assert candidate["hypothesis"]["weakness"] =~ "13 of 13"
        assert candidate["hypothesis"]["change"] =~ "--explain"

        # The half people forget: what would have to keep happening for the
        # change to be wrong. It carries the cluster not shrinking *and* the
        # efficiency metric's gaming question.
        assert candidate["hypothesis"]["disconfirming_evidence"] =~ "stays at or above 13"
        assert candidate["hypothesis"]["disconfirming_evidence"] =~ "beads get smaller"

        assert candidate["metrics"]["efficiency"] == ["output_tokens_per_bead"]
        assert candidate["metrics"]["capability"] != []
      end)
    end

    test "a cluster that names no change is refused" do
      # What an earlier change's `actionable` flag was for. "A candidate with a
      # vague change is a candidate that will be scored against a vague
      # measure."
      with_baseline(fn ->
        assert {:error, message} =
                 Evolution.from_cluster(
                   cluster(%{"actionable" => false, "change" => nil, "shape" => "memory.scope"})
                 )

        assert message =~ "names no change"
        assert message =~ "taught nothing"
      end)
    end

    test "a shape with no mapping is refused by name, not guessed at" do
      with_baseline(fn ->
        assert {:error, message} = Evolution.from_cluster(cluster(%{"shape" => "wallclock.slow"}))

        assert message =~ "no mapping for the shape wallclock.slow"
        assert message =~ "@from_cluster"
      end)
    end

    test "an efficiency metric with no baseline value is refused" do
      # An earlier change froze the baseline. A candidate whose efficiency metric
      # was not in it cannot show an improvement against it, and `gates/1`
      # would read the absence as "no efficiency gain" rather than as "not
      # measured" — which is the difference between a failed candidate and an
      # unmeasured one.
      tree = Map.put(Fixture.minimal(), "evolution/baseline.json", %{"metrics" => %{}})

      Fixture.with_tree(tree, fn _root ->
        assert {:error, message} = Evolution.from_cluster(cluster(%{}))
        assert message =~ "has no value in"
        assert message =~ "baseline.json"
      end)
    end

    test "no baseline at all is refused, and says how to take one" do
      Fixture.with_tree(Fixture.minimal(), fn _root ->
        assert {:error, message} = Evolution.from_cluster(cluster(%{}))
        assert message =~ "no baseline has been taken"
        assert message =~ "--baseline"
      end)
    end

    test "a gate cluster proposes, and the promotion gate refuses it forever" do
      # Constitution §23: an evolution run may propose a change to the
      # constitution, trust levels, gates or the security policy, and may never
      # land one. That was a sentence in a moduledoc until this bead, which is
      # the one that builds a proposer with no person in the loop.
      with_baseline(fn ->
        gate_cluster =
          cluster(%{
            "shape" => "gate.unavailable",
            "subject" => "typeql.check",
            "change" => "Install it, or take it out of the lanes that claim it.",
            "reading" => "typeql.check could not run 9 times"
          })

        assert {:ok, path} = Evolution.from_cluster(gate_cluster)
        {:ok, candidate} = Evolution.fetch(Path.basename(path, ".json"))

        assert Evolution.protected_target?(candidate),
               "a candidate targeting .agents/policies/gates.json is not recognised as " <>
                 "protected, so nothing stops it being landed by a gate"

        assert {:error, reasons} = Evolution.promotable?(candidate)

        assert Enum.any?(reasons, &(&1 =~ "constitution §23")),
               "the refusal does not cite the rule: #{inspect(reasons)}"
      end)
    end

    test "an ordinary target is not treated as protected" do
      # The other direction, and the one a widened guard breaks: if everything
      # is protected, nothing can ever be promoted and the evolution loop is
      # decorative.
      with_baseline(fn ->
        assert {:ok, path} = Evolution.from_cluster(cluster(%{}))
        {:ok, candidate} = Evolution.fetch(Path.basename(path, ".json"))

        refute Evolution.protected_target?(candidate)

        assert {:error, reasons} = Evolution.promotable?(candidate)

        refute Enum.any?(reasons, &(&1 =~ "constitution §23")),
               "a signals change was refused as though it were a constitutional one"
      end)
    end
  end
end
