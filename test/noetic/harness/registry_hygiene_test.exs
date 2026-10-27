defmodule Noetic.Harness.RegistryHygieneTest do
  # `async: true` since an earlier change: the root override is per process now, so a
  # fixture tree here is invisible to every other test in the VM.
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Artifact, Owner, Run}

  setup do
    root = Noetic.Harness.TestTmp.path("hygiene")
    File.mkdir_p!(Path.join(root, ".agents/runs"))
    File.mkdir_p!(Path.join(root, ".agents/artifacts/ArchitectureMap"))

    # A real repository, because the brooms ask git whether a file is tracked
    # before removing it, and `git ls-files` outside a repository answers 128 —
    # which `tracked?/1` correctly reads as "I could not tell", so nothing
    # would ever be removed here and every assertion below would be vacuous.
    {_, 0} = System.cmd("git", ["init", "--quiet", root], stderr_to_stdout: true)

    previous = Noetic.Harness.put_root(root)

    on_exit(fn ->
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp run_file(root, id, fields) do
    path = Path.join([root, ".agents/runs", id <> ".json"])

    body =
      Map.merge(
        %{
          "id" => id,
          "title" => "a run",
          "workflow" => "WF-002",
          "workflow_name" => "RFC → Implementation",
          "lane" => "focused",
          "agent" => "test",
          "bead" => nil,
          "parent_run" => nil,
          "started_at" => "2026-09-22T06:10:12.288078Z",
          "finished_at" => nil,
          "status" => "open",
          "ephemeral" => true,
          "steps" => [],
          "dispatches" => [],
          "gates" => nil,
          "acknowledged" => nil
        },
        fields
      )

    File.write!(path, JSON.encode!(body))
    path
  end

  defp artifact_file(root, id, created_by, fields \\ %{}) do
    path = Path.join([root, ".agents/artifacts/ArchitectureMap", id <> ".json"])

    File.write!(
      path,
      JSON.encode!(
        Map.merge(
          %{
            "id" => id,
            "kind" => "ArchitectureMap",
            "created_by" => created_by,
            "created_at" => "2026-09-22T06:09:28.991535Z",
            "unverified" => [],
            "inputs" => [],
            "outputs" => [],
            "evidence" => [],
            "parent_ids" => []
          },
          fields
        )
      )
    )

    path
  end

  # Another VM that is still running, as litter records it. A `sleep` stands
  # in for the other suite: what the broom asks is whether the pid is alive,
  # and a BEAM would answer the same way at twenty times the cost.
  defp live_vm do
    sleep = System.find_executable("sleep")
    port = Port.open({:spawn_executable, sleep}, [:binary, args: ["120"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    os_pid = Integer.to_string(os_pid)

    on_exit(fn -> System.cmd("kill", [os_pid], stderr_to_stdout: true) end)

    Map.put(Owner.current(), "os_pid", os_pid)
  end

  # A VM that has exited: the pid of a shell that printed it and returned.
  defp dead_vm do
    {os_pid, 0} = System.cmd("sh", ["-c", "echo $$"])
    Map.put(Owner.current(), "os_pid", String.trim(os_pid))
  end

  describe "the broom for what a suite leaves behind" do
    test "an open ephemeral run is removed and a closed one is kept", %{root: root} do
      open = run_file(root, "run-test-open", %{})
      closed = run_file(root, "run-test-closed", %{"status" => "done"})

      removed = Run.prune_ephemeral()

      assert "run-test-open" in removed
      refute File.exists?(open)

      # A closed ephemeral run is the record of a suite that finished, and
      # deleting records is not this function's job. `.agents/` is
      # append-only by the constitution's sixth section, and a broom that
      # sweeps history is a different and much worse thing than one that
      # sweeps litter.
      assert File.exists?(closed)
      refute "run-test-closed" in removed
    end

    test "a real run is never touched, whatever its status", %{root: root} do
      real = run_file(root, "run-real-open", %{"ephemeral" => false, "agent" => "claude-opus-5"})

      assert Run.prune_ephemeral() == []
      assert File.exists?(real)
    end

    test "an artifact the suite wrote is removed and an authored one is kept", %{root: root} do
      theirs = artifact_file(root, "architecturemap-test", "test")
      ours = artifact_file(root, "architecturemap-real", "claude-opus-5")

      removed = Artifact.prune_test()

      assert removed == ["architecturemap-test"]
      refute File.exists?(theirs)

      # The five artifacts committed in this repository are all
      # `created_by: "claude-opus-5"`. Checked before the bead was written
      # rather than after, because "a test suite has been committing detritus"
      # is a much more alarming sentence than the truth.
      assert File.exists?(ours)
    end

    test "a file that is not readable JSON is left alone rather than guessed at", %{root: root} do
      path = Path.join([root, ".agents/artifacts/ArchitectureMap", "broken.json"])
      File.write!(path, "{ this is not json")

      assert Artifact.prune_test() == []
      assert File.exists?(path), "a file the broom could not read was deleted anyway"
    end

    test "a tracked artifact claiming to be test output survives the broom", %{root: root} do
      # The property the five deleted files needed, and the one the first
      # version of this file did not test: every artifact in the fixture was
      # untracked, so removing the guard entirely left all seven tests green.
      # A guard is only tested by a case that would be swept without it.
      tracked = artifact_file(root, "architecturemap-committed", "test")
      loose = artifact_file(root, "architecturemap-loose", "test")

      {_, 0} = System.cmd("git", ["add", "--", tracked], cd: root, stderr_to_stdout: true)

      removed = Artifact.prune_test()

      assert removed == ["architecturemap-loose"]
      refute File.exists?(loose)

      assert File.exists?(tracked),
             "the broom deleted a file git knows about. That is how five committed artifacts " <>
               "went in one run, and `git checkout` was the only reason it cost nothing."
    end

    test "a tracked ephemeral run survives the broom too", %{root: root} do
      tracked = run_file(root, "run-test-committed", %{})
      loose = run_file(root, "run-test-loose", %{})

      {_, 0} = System.cmd("git", ["add", "--", tracked], cd: root, stderr_to_stdout: true)

      removed = Run.prune_ephemeral()

      assert removed == ["run-test-loose"]
      refute File.exists?(loose)
      assert File.exists?(tracked)
    end

    @tag this_repository: true
    test "a tracked file is never removed, whatever it claims about its author" do
      # This guard was earned rather than designed. `ExUnit.after_suite/1`
      # runs *after* the callbacks that restore the root override, so the
      # broom always resolves to the **real** repository — even for a suite
      # whose every test pointed the harness at a fixture. A calibration
      # mutation that widened the artifact filter by one clause therefore
      # deleted all five committed artifacts in a single run, and `git
      # checkout` was the only reason that cost nothing.
      #
      # Run against the real repository on purpose: a fixture tree is not a
      # git repository, so `tracked?/1` would answer `false` there for reasons
      # that have nothing to do with the property.
      Noetic.Harness.delete_root()

      tracked = Path.join(Noetic.Harness.root(), ".agents/policies/evaluators.json")
      assert File.exists?(tracked)

      assert Artifact.tracked?(tracked),
             "git knows about #{tracked} and tracked?/1 said otherwise, so the broom's only " <>
               "guard against deleting somebody's work is not working"

      refute Artifact.tracked?(Path.join(Noetic.Harness.root(), ".agents/no-such-file.json"))
    end

    test "tracked?/1 fails closed when git cannot answer" do
      # Not a repository, no git, an error — all the same answer: "tracked",
      # so nothing is removed. A broom that deletes when it cannot tell is not
      # a broom.
      outside = Noetic.Harness.TestTmp.dir!("not-a-repo")
      on_exit(fn -> File.rm_rf(outside) end)

      Noetic.Harness.put_root(outside)

      assert Artifact.tracked?(Path.join(outside, "anything.json")),
             "outside a git repository the broom decided a file was untracked, and would have " <>
               "deleted it"
    end

    test "an open ephemeral run of another VM that is still running survives", %{root: root} do
      # Several suites can share one checkout: three agents verifying
      # An earlier change did. The first to finish swept the others' open runs, and
      # `dispatcher_test` failed four times with `no run run-...` in a suite
      # that was fine.
      theirs = run_file(root, "run-test-theirs", %{"owner_vm" => live_vm()})
      gone = run_file(root, "run-test-gone", %{"owner_vm" => dead_vm()})
      mine = run_file(root, "run-test-mine", %{"owner_vm" => Owner.current()})

      removed = Run.prune_ephemeral()

      assert File.exists?(theirs),
             "the broom deleted an open run of a VM that is still running, which fails that " <>
               "suite mid-test with `no run`"

      refute "run-test-theirs" in removed
      assert Enum.sort(removed) == ["run-test-gone", "run-test-mine"]
      refute File.exists?(gone), "a run whose VM has exited is litter and must still go"
      refute File.exists?(mine)
    end

    test "an artifact of another VM that is still running survives", %{root: root} do
      theirs = artifact_file(root, "architecturemap-theirs", "test", %{"owner_vm" => live_vm()})
      gone = artifact_file(root, "architecturemap-gone", "test", %{"owner_vm" => dead_vm()})
      mine = artifact_file(root, "architecturemap-mine", "test", %{"owner_vm" => Owner.current()})

      removed = Artifact.prune_test()

      assert File.exists?(theirs), "the broom deleted a live VM's artifact"
      assert Enum.sort(removed) == ["architecturemap-gone", "architecturemap-mine"]
      refute File.exists?(gone)
      refute File.exists?(mine)
    end

    test "litter whose owner cannot be judged is kept", %{root: root} do
      # A pid means nothing outside its namespace: a suite in a container or
      # under `bwrap --unshare-pid` records a pid that out here names some
      # other process or none. The dead pid below would be swept if the
      # namespace were ignored.
      elsewhere = Map.put(dead_vm(), "pid_ns", "pid:[1]")
      foreign = run_file(root, "run-test-foreign", %{"owner_vm" => elsewhere})
      garbled = run_file(root, "run-test-garbled", %{"owner_vm" => "12345"})
      # In this namespace, so only the pid check itself keeps it: `/proc/../1`
      # is `/1`, which does not exist, and a pid read as a path would be swept.
      nonsense =
        run_file(root, "run-test-nonsense", %{
          "owner_vm" => Map.put(Owner.current(), "os_pid", "../1")
        })

      assert Run.prune_ephemeral() == []
      assert File.exists?(foreign)
      assert File.exists?(garbled)
      assert File.exists?(nonsense)
    end

    test "what the suite writes says which VM wrote it; real work does not", %{root: root} do
      # The brooms can only spare a live VM's litter if the litter says whose
      # it is. Workflows come from the pack (`Noetic.Harness.Pack`), because
      # `start/1` refuses a workflow it cannot find.
      File.ln_s!(
        Path.join(Noetic.Harness.Pack.source(), "workflows"),
        Path.join(root, ".agents/workflows")
      )

      {:ok, litter} = Run.start(workflow: "WF-003", title: "litter", agent: "test")
      {:ok, work} = Run.start(workflow: "WF-003", title: "work", agent: "test", ephemeral: false)

      # What is on disk, because that is all a broom in another VM reads. A
      # stamp returned and not written would pass an assertion on the map.
      {:ok, litter} = Run.fetch(litter["id"])
      {:ok, work} = Run.fetch(work["id"])

      assert litter["owner_vm"] == Owner.current()
      refute Map.has_key?(work, "owner_vm"), "a real run is never swept, so it needs no owner"

      {:ok, test_artifact} =
        Artifact.new(%{kind: "ArchitectureMap", created_by: "test", unverified: []})

      {:ok, authored} =
        Artifact.new(%{kind: "ArchitectureMap", created_by: "claude", unverified: []})

      {:ok, _} = Artifact.write(test_artifact)
      {:ok, _} = Artifact.write(authored)

      assert [{_, %{"owner_vm" => owner}}] = Artifact.test_output()
      assert owner == Owner.current()
      refute Map.has_key?(authored, "owner_vm")
    end

    test "both brooms are wired into the suite itself" do
      # The point of an earlier change is not that a prune exists — one did, for
      # runs, as a manual command nothing called. It is that nobody has to
      # remember it.
      # Relative to this file, not to `Noetic.Harness.root()` — `setup` has
      # pointed that at a fixture tree, and a test that reads the fixture and
      # claims to have read the repository proves nothing.
      helper = File.read!(Path.expand("../../test_helper.exs", __DIR__))

      assert helper =~ "ExUnit.after_suite",
             "the suite does not clean up after itself, so the broom is a command nobody runs"

      assert helper =~ "prune_ephemeral"
      assert helper =~ "prune_test"
    end
  end
end
