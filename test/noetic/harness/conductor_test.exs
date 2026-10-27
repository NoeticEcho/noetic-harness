defmodule Noetic.Harness.ConductorTest do
  @moduledoc """
  The conductor advises and refuses, and only the refusals are load-bearing —
  so the refusals are what is tested here, along with the three counting rules
  that produce them.

  The pure tests build run maps by hand. The `next/1` tests go through the
  ledger against WF-002 as the engine's test pack has it (`Noetic.Harness.Pack`): the conductor is tested on a workflow of that shape, and a
  change to this repository's own WF-002 is not a conductor failure.
  """
  # `async: false`: the command tests run `noetic-harness conduct`, and
  # `Mix.shell/1` is VM-global. Runs no longer collide — each test has a pack
  # root of its own, where the real `.agents/runs/` made two
  # open runs answer `{:error, :many}` to each other.
  use ExUnit.Case, async: false

  alias Noetic.Harness.{Conductor, Run}

  # A git root: the ledger fingerprints the tree, which the stall rule reads.
  setup {Noetic.Harness.Pack, :git_root}

  defp entry(step, outcome, opts \\ []) do
    %{
      "step" => step,
      "outcome" => outcome,
      "evidence" => Keyword.get(opts, :evidence, ["ran a thing"]),
      "artifacts" => Keyword.get(opts, :artifacts, []),
      "tree" => Keyword.get(opts, :tree, "aaaa0000"),
      "at" => "2026-09-20T00:00:00Z"
    }
  end

  defp run(entries), do: %{"id" => "r", "workflow" => "WF-002", "steps" => entries}

  # `owed/2` resolves an attachment against the artifact store, so a test that
  # wants a debt settled has to settle it with a real envelope. That is the
  # point of the check: the first version accepted any string containing the
  # kind's name, so `"notes-about-the-codepatch"` discharged a `CodePatch`.
  defp artifact!(kind) do
    {:ok, envelope} =
      Noetic.Harness.Artifact.new(%{
        kind: kind,
        created_by: "test",
        unverified: ["this envelope exists to be attached"]
      })

    {:ok, path} = Noetic.Harness.Artifact.write(envelope)
    on_exit(fn -> File.rm(path) end)
    envelope["id"]
  end

  describe "classifying a failure" do
    test "a failing test routes to regression analysis before the implementing role" do
      assert {:ok, class} = Conductor.classify(["mix test — Failed: 3 tests"])
      assert class["id"] == "test_failed"
      assert class["route"] == "capability:qa.regression"
      assert class["why"] =~ "The test may be right"
    end

    test "a missing tool is reported unavailable rather than worked around" do
      assert {:ok, class} = Conductor.classify("gitleaks: command not found")
      assert class["id"] == "tool_unavailable"
      assert class["why"] =~ "Never downgrade"
    end

    test "a benchmark gain with a flat holdout stops" do
      assert {:ok, class} = Conductor.classify("the benchmark gain came with a flat holdout")
      assert class["id"] == "goodhart"
      assert class["stop"] == true
    end

    test "evidence matching nothing routes nowhere, and says so" do
      assert Conductor.classify(["the colour of the module is wrong"]) == :none
    end

    test "the class detected by counting has no pattern to match on" do
      {:ok, policy} = Conductor.policy()
      repeated = Enum.find(policy["classes"], &(&1["id"] == "repeated_failure"))

      # It is found from the run's shape, not from the text of a failure, so a
      # regex here would only ever produce false positives.
      assert repeated["match"] == nil
      assert repeated["route"] == "workflow:WF-020"
    end
  end

  describe "the retry budget" do
    test "comes from the workflow" do
      {:ok, workflow} = Noetic.Harness.Workflow.fetch("WF-002")
      assert Conductor.budget(workflow) == 3

      {:ok, evolution} = Noetic.Harness.Workflow.fetch("WF-020")
      assert Conductor.budget(evolution) == 2
    end

    test "falls back to the policy default when a workflow declares none" do
      assert Conductor.budget(%{"id" => "WF-x"}) == 3
    end

    test "a done attempt does not spend it" do
      run =
        run([entry("implement", "failed"), entry("implement", "done"), entry("test", "failed")])

      assert Conductor.spent(run, "implement") == 1
      assert Conductor.spent(run, "test") == 1
      assert Conductor.spent(run, "review") == 0
    end
  end

  describe "a stall is not a retry" do
    test "the same tree and the same evidence twice is a stall" do
      run = run([entry("implement", "failed"), entry("implement", "failed")])

      assert {:stalled, reason} = Conductor.stalled(run, "implement")
      assert reason =~ "identical tree"
      assert reason =~ "failure.md"
    end

    test "a changed tree is a retry, however identical the evidence" do
      run =
        run([
          entry("implement", "failed", tree: "aaaa0000"),
          entry("implement", "failed", tree: "bbbb1111")
        ])

      assert Conductor.stalled(run, "implement") == :no
    end

    test "different evidence over the same tree is a retry" do
      run =
        run([
          entry("implement", "failed", evidence: ["one thing"]),
          entry("implement", "failed", evidence: ["a different thing"])
        ])

      assert Conductor.stalled(run, "implement") == :no
    end

    test "a missing fingerprint is unknown, never equal" do
      # Entries written before the ledger recorded a tree, and entries from a
      # directory git cannot read, both have `tree: nil`. Treating that as
      # "unchanged" would declare every one of them a stall.
      run =
        run([
          entry("implement", "failed", tree: nil),
          entry("implement", "failed", tree: nil)
        ])

      assert Conductor.stalled(run, "implement") == :no
    end
  end

  describe "a loop is not a stall" do
    defp cycle(times) do
      for i <- 1..times, step <- ~w(implement test) do
        entry(step, "failed", tree: "tree#{i}", evidence: ["attempt #{i} at #{step}"])
      end
    end

    test "a cycle repeating three times is a loop" do
      assert {:looping, reason} = Conductor.looping(run(cycle(3)))
      assert reason =~ "implement → test"
      assert reason =~ "WF-020"
    end

    test "twice is not, because that is one failed test and one fix" do
      assert Conductor.looping(run(cycle(2))) == :no
    end

    test "the repetition count is not the retry budget" do
      # It was, and at `retry_budget: 1` — WF-015 Release, WF-016 Incident —
      # `budget` repetitions of a cycle is one, so `tail == tail` held
      # vacuously and every pair of distinct consecutive steps was a loop. A
      # healthy release run halted on its second entry and was told to go open
      # WF-020. Both reviewers reproduced it independently.
      linear = for step <- ~w(context plan implement), do: entry(step, "done")

      assert Conductor.looping(run(linear)) == :no
      assert Conductor.looping(run(Enum.take(linear, 2))) == :no

      for id <- ~w(WF-015 WF-016) do
        {:ok, workflow} = Noetic.Harness.Workflow.fetch(id)
        assert Conductor.budget(workflow) == 1
      end
    end

    test "every attempt changed the tree, so no stall and no exhausted step sees it" do
      run = run(cycle(3))

      assert Conductor.stalled(run, "implement") == :no
      assert Conductor.spent(run, "implement") == 3
    end

    test "steady progress through distinct steps is not a loop" do
      entries =
        for step <- ~w(context plan implement test review document), do: entry(step, "done")

      assert Conductor.looping(run(entries)) == :no
    end

    test "one step repeating is the budget's business, not the loop detector's" do
      entries = for i <- 1..3, do: entry("implement", "failed", tree: "t#{i}")
      assert Conductor.looping(run(entries)) == :no
    end

    test "one out-of-band entry hides the cycle, which is the conservative direction" do
      entries = cycle(3) ++ [entry("context", "done", tree: "later")]
      assert Conductor.looping(run(entries)) == :no
    end
  end

  describe "artifacts a step owes" do
    test "an output naming an artifact kind is an envelope somebody owes" do
      step = %{"id" => "implement", "outputs" => ["CodePatch"]}
      assert Conductor.owed(step, entry("implement", "done")) == ["CodePatch"]
    end

    test "attaching a real envelope of that kind settles the debt" do
      step = %{"id" => "implement", "outputs" => ["CodePatch"]}
      attached = entry("implement", "done", artifacts: [artifact!("CodePatch")])

      assert Conductor.owed(step, attached) == []
    end

    test "a string that merely looks like one does not" do
      step = %{"id" => "implement", "outputs" => ["CodePatch"]}
      attached = entry("implement", "done", artifacts: ["notes-about-the-codepatch"])

      assert Conductor.owed(step, attached) == ["CodePatch"]
    end

    test "an envelope of the wrong kind does not" do
      step = %{"id" => "implement", "outputs" => ["CodePatch"]}
      attached = entry("implement", "done", artifacts: [artifact!("ResearchNote")])

      assert Conductor.owed(step, attached) == ["CodePatch"]
    end

    test "prose outputs stay descriptive" do
      # WF-002's `plan` step outputs "TaskGraph" and "beads filed". Only the
      # first is a kind; demanding an envelope for the second would make the
      # rule unbelievable by the end of the week.
      step = %{"id" => "plan", "outputs" => ["TaskGraph", "beads filed"]}
      assert Conductor.owed(step, entry("plan", "done")) == ["TaskGraph"]
    end
  end

  describe "next/1 against the pack's WF-002" do
    setup do
      title = "conductor test #{System.unique_integer([:positive])}"
      {:ok, run} = Run.start(workflow: "WF-002", title: title, agent: "test")

      on_exit(fn ->
        Noetic.Harness.agents_path("runs") |> Path.join("#{run["id"]}.json") |> File.rm()
      end)

      {:ok, id: run["id"]}
    end

    test "an empty run is pointed at the first step", %{id: id} do
      assert {:ok, advice} = Conductor.next(id)

      assert advice.state == "running"
      assert advice.step["id"] == "context"
      assert advice.refusals == []
    end

    test "an optional step is surfaced with its condition, not decided", %{id: id} do
      {:ok, _} = Run.record(id, step: "context", outcome: "done", evidence: ["read it"])

      {:ok, _} =
        Run.record(id,
          step: "plan",
          outcome: "done",
          evidence: ["planned it"],
          artifacts: [artifact!("TaskGraph")]
        )

      assert {:ok, advice} = Conductor.next(id)
      assert advice.step["id"] == "contracts"
      assert advice.reason =~ "optional"
      assert advice.reason =~ "will not decide that for you"
    end

    # WF-002's `context` and `plan` declare artifact kinds too, so a test about
    # `implement`'s debt has to pay theirs or it is a test about all three.
    defp reach_implement(id) do
      {:ok, _} =
        Run.record(id,
          step: "context",
          outcome: "done",
          evidence: ["read it"],
          artifacts: [artifact!("ArchitectureMap")]
        )

      {:ok, _} =
        Run.record(id,
          step: "plan",
          outcome: "done",
          evidence: ["planned it"],
          artifacts: [artifact!("TaskGraph")]
        )

      {:ok, _} = Run.record(id, step: "contracts", outcome: "done", evidence: ["stated them"])
    end

    test "a step that owes an artifact is not advanced past", %{id: id} do
      # WF-002's `implement` step declares `outputs: ["CodePatch"]`.
      reach_implement(id)
      {:ok, _} = Run.record(id, step: "implement", outcome: "done", evidence: ["wrote it"])

      assert {:ok, advice} = Conductor.next(id)
      assert advice.owed == ["CodePatch"]
      assert advice.step["id"] == "implement"
      assert [refusal] = advice.refusals
      assert refusal =~ "attached none"
      assert refusal =~ "constitution.md"
    end

    test "attaching the artifact advances", %{id: id} do
      reach_implement(id)

      {:ok, _} =
        Run.record(id,
          step: "implement",
          outcome: "done",
          evidence: ["wrote it"],
          artifacts: [artifact!("CodePatch")]
        )

      assert {:ok, advice} = Conductor.next(id)
      assert advice.step["id"] == "test"
      assert advice.refusals == []
    end

    test "a failure inside budget is a retry, with its routing named", %{id: id} do
      {:ok, _} = Run.record(id, step: "context", outcome: "failed", evidence: ["Failed: 2 tests"])

      assert {:ok, advice} = Conductor.next(id)
      assert advice.state == "running"
      assert advice.step["id"] == "context"
      assert advice.reason =~ "attempt 2 of 3"
      assert advice.routing["class"] == "test_failed"
      assert advice.routing["route"] == "capability:qa.regression"
    end

    test "an exhausted budget refuses another attempt and names the escalation", %{id: id} do
      for i <- 1..3 do
        {:ok, _} =
          Run.record(id, step: "context", outcome: "failed", evidence: ["attempt #{i} — no luck"])
      end

      assert {:ok, advice} = Conductor.next(id)
      assert advice.state == "exhausted"
      assert advice.reason =~ "spent 3 of 3"
      assert advice.reason =~ "WF-020"
      assert [refusal] = advice.refusals
      assert refusal =~ "FAILED artifact containing every attempt"
      assert refusal =~ "not reverted along with the code"
    end

    test "two identical attempts over an unchanged tree stall the run", %{id: id} do
      # Same evidence, and the tree cannot change between two ledger writes in
      # the same test, which is exactly the condition the policy describes.
      for _ <- 1..2 do
        {:ok, _} =
          Run.record(id, step: "context", outcome: "failed", evidence: ["the same thing"])
      end

      assert {:ok, advice} = Conductor.next(id)
      assert advice.state == "stalled"
      assert advice.reason =~ "identical tree"
      assert hd(advice.refusals) =~ "terminates on a stall"
    end

    test "the ledger records a tree fingerprint, which is what makes that possible", %{id: id} do
      {:ok, run} = Run.record(id, step: "context", outcome: "done", evidence: ["x"])
      entry = List.last(run["steps"])

      assert is_binary(entry["tree"])
      assert String.length(entry["tree"]) == 16
    end

    test "a blocked step is not worked around", %{id: id} do
      {:ok, _} =
        Run.record(id, step: "context", outcome: "blocked", evidence: ["needs a credential"])

      assert {:ok, advice} = Conductor.next(id)
      assert advice.state == "blocked"
      assert advice.routing["routing"] == "escalate"
      assert hd(advice.refusals) =~ "does not get worked around"
      assert hd(advice.refusals) =~ "discovered-from"
    end

    test "uncertain is not a soft done", %{id: id} do
      {:ok, _} = Run.record(id, step: "context", outcome: "uncertain", evidence: ["cannot tell"])

      assert {:ok, advice} = Conductor.next(id)
      assert advice.reason =~ "not a soft `done`"
    end

    defp finish_every_step(id, opts \\ []) do
      owing = Keyword.get(opts, :owing, [])

      for step <- ~w(context plan implement test review document integrate) do
        artifacts =
          if step in owing do
            []
          else
            case step do
              "context" -> [artifact!("ArchitectureMap")]
              "plan" -> [artifact!("TaskGraph")]
              "implement" -> [artifact!("CodePatch")]
              "test" -> [artifact!("EvaluationRun")]
              _ -> []
            end
          end

        {:ok, _} =
          Run.record(id,
            step: step,
            outcome: "done",
            evidence: ["#{step} done"],
            artifacts: artifacts
          )
      end
    end

    test "a run with every required step done is complete, and says what closes it", %{id: id} do
      finish_every_step(id)

      assert {:ok, advice} = Conductor.next(id)
      assert advice.state == "complete"
      assert advice.reason =~ "run --finish"
      assert advice.refusals == []
      # `contracts` is optional and was never recorded. The ledger closes a run
      # over that, so the conductor must not disagree — but it says so.
      assert advice.reason =~ "contracts was never recorded either way"
    end

    test "a debt from three steps ago is still a debt at the end", %{id: id} do
      # The first version checked the owed artifacts of the *last* entry only,
      # which made the refusal "you may not record the next step right now" —
      # satisfied by recording the next step anyway. Two steps of the run that
      # built this feature were in exactly that state.
      finish_every_step(id, owing: ~w(context plan))

      assert {:ok, advice} = Conductor.next(id)
      assert advice.state == "complete"
      assert [refusal] = advice.refusals
      assert refusal =~ "context: ArchitectureMap"
      assert refusal =~ "plan: TaskGraph"
      assert refusal =~ "not an obligation"
      assert Enum.sort(advice.owed) == ["ArchitectureMap", "TaskGraph"]
    end

    test "an optional step recorded non-done is not something to complete over", %{id: id} do
      # `Run.finish/2` refuses on any step that is not done, optional included.
      # Saying "complete" here would put the two into disagreement, and of the
      # two the one that refuses to close runs is the one to agree with.
      {:ok, _} = Run.record(id, step: "contracts", outcome: "failed", evidence: ["no contract"])
      finish_every_step(id)

      assert {:ok, advice} = Conductor.next(id)
      refute advice.state == "complete"
      assert advice.step["id"] == "contracts"
    end

    test "a step the workflow no longer declares does not crash it", %{id: id} do
      # A run ledger outlives the workflow it names, and renaming a step leaves
      # entries pointing at nothing. The first version handed that `nil` to
      # `Map.get/3` and raised out of the one tool whose job is to say no.
      path = Noetic.Harness.agents_path("runs") |> Path.join("#{id}.json")
      {:ok, run} = Run.fetch(id)

      File.write!(
        path,
        Noetic.Harness.Loader.pretty!(
          Map.put(run, "steps", [
            %{"step" => "a_step_that_was_renamed", "outcome" => "done", "evidence" => ["x"]}
          ])
        )
      )

      assert {:ok, advice} = Conductor.next(id)
      assert advice.state == "blocked"
      assert advice.reason =~ "no longer"
    end

    test "a run naming a workflow that does not exist is refused, not raised", %{id: id} do
      path = Noetic.Harness.agents_path("runs") |> Path.join("#{id}.json")
      {:ok, run} = Run.fetch(id)
      File.write!(path, Noetic.Harness.Loader.pretty!(Map.put(run, "workflow", "WF-999")))

      assert {:error, message} = Conductor.next(id)
      assert message =~ "WF-999"
      assert message =~ "harness validate"
    end

    test "it never records anything", %{id: id} do
      {:ok, before} = Run.fetch(id)
      {:ok, _} = Conductor.next(id)
      {:ok, unchanged} = Run.fetch(id)

      assert before == unchanged
    end
  end

  describe "the command a script would drive a run with" do
    setup do
      title = "conductor exit test #{System.unique_integer([:positive])}"
      {:ok, run} = Run.start(workflow: "WF-002", title: title, agent: "test")

      on_exit(fn ->
        Noetic.Harness.agents_path("runs") |> Path.join("#{run["id"]}.json") |> File.rm()
      end)

      {:ok, id: run["id"]}
    end

    test "exits non-zero on a state the workflow does not continue from", %{id: id} do
      for _ <- 1..2 do
        {:ok, _} =
          Run.record(id, step: "context", outcome: "failed", evidence: ["the same thing"])
      end

      # A script that drives a run has to stop for the same reasons a person
      # would. Without this the loop reads the advice, sees a stall, and takes
      # the next iteration anyway.
      assert catch_exit(
               ExUnit.CaptureIO.capture_io(fn ->
                 Mix.Tasks.Harness.Conduct.run(["--run", id])
               end)
             ) == {:shutdown, 1}
    end

    test "exits 2 when there is nothing left to do, so a driving loop stops", %{id: id} do
      for step <- ~w(context plan implement test review document integrate) do
        {:ok, _} = Run.record(id, step: step, outcome: "done", evidence: ["#{step} done"])
      end

      assert catch_exit(
               ExUnit.CaptureIO.capture_io(fn ->
                 Mix.Tasks.Harness.Conduct.run(["--run", id])
               end)
             ) == {:shutdown, 2}
    end

    test "refuses a --run that is a path rather than a run id" do
      assert catch_exit(
               ExUnit.CaptureIO.capture_io(:stderr, fn ->
                 Mix.Tasks.Harness.Conduct.run(["--run", "../../../etc/passwd"])
               end)
             ) == {:shutdown, 1}
    end

    test "exits zero while the run is still running", %{id: id} do
      output =
        ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Harness.Conduct.run(["--run", id]) end)

      assert output =~ "state running"
      assert output =~ "context"
    end

    test "says so rather than exiting quietly when the run does not exist" do
      assert catch_exit(
               ExUnit.CaptureIO.capture_io(:stderr, fn ->
                 Mix.Tasks.Harness.Conduct.run(["--run", "run-nope"])
               end)
             ) == {:shutdown, 1}
    end
  end

  describe "the module the bead warned about" do
    test "has no dispatch function, so the distinction cannot erode quietly" do
      # "executor" names dispatch and control, and this is control.
      # The same test the ledger has, for the same reason.
      exports = Conductor.__info__(:functions) |> Enum.map(&elem(&1, 0))

      for forbidden <- ~w(dispatch execute drive call_agent spawn_agent perform run_step)a do
        refute forbidden in exports,
               "Conductor.#{forbidden}/? exists. A design decision says this module does not dispatch."
      end
    end
  end
end
