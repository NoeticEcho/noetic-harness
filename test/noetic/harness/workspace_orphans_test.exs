defmodule Noetic.Harness.WorkspaceOrphansTest do
  @moduledoc """
  The sweep for branches a killed run left behind.

  A throwaway repository with four `harness/run/*` branches, one per case the
  orphan rule has to get right. Each case is a claim in
  `Noetic.Harness.Workspace.orphans/0`'s doc, and a sweep that deletes a real
  run's diff is the failure that matters — so most of these are about what it
  must *not* remove.
  """

  # async: false: the fixture repository is reached through the process root,
  # and `git worktree` serialises on the admin directory.
  use ExUnit.Case, async: false

  alias Noetic.Harness.Workspace

  describe "leftover run branches" do
    # A throwaway repository with four `harness/run/*` branches, one per case
    # the orphan rule has to get right. Each case is a claim in the moduledoc,
    # and a sweep that deletes a real run's diff is the failure that matters.
    setup do
      root = Path.join(System.tmp_dir!(), "harness-orphans-#{System.os_time(:microsecond)}")
      File.mkdir_p!(Path.join([root, ".agents", "runs"]))
      git!(root, ["init", "-q", "-b", "main"])
      git!(root, ["config", "user.email", "test@example.invalid"])
      git!(root, ["config", "user.name", "test"])
      File.write!(Path.join(root, "README"), "x")
      git!(root, ["add", "README"])
      git!(root, ["commit", "-q", "-m", "start"])

      for id <- ~w(nowhere here elsewhere history) do
        git!(root, ["branch", "harness/run/" <> id])
      end

      # `here`: a ledger file in this worktree, not committed.
      File.write!(Path.join([root, ".agents", "runs", "here.json"]), "{}")

      # `history`: committed once, then removed.
      File.write!(Path.join([root, ".agents", "runs", "history.json"]), "{}")
      git!(root, ["add", ".agents/runs/history.json"])
      git!(root, ["commit", "-q", "-m", "a run"])
      git!(root, ["rm", "-q", ".agents/runs/history.json"])
      git!(root, ["commit", "-q", "-m", "gone"])

      # `elsewhere`: a ledger file in a *different* worktree of the same repo.
      other = root <> "-other"
      git!(root, ["worktree", "add", "-q", "-b", "other", other])
      File.mkdir_p!(Path.join([other, ".agents", "runs"]))
      File.write!(Path.join([other, ".agents", "runs", "elsewhere.json"]), "{}")

      previous = Noetic.Harness.root_override()
      Noetic.Harness.put_root(root)

      # The worktree root is `<fixture>/.git/noetic-harness` only when nothing
      # overrides it, and the exact-list assertions below depend on that.
      override = System.get_env("NOETIC_HARNESS_WORKTREE_ROOT")
      System.delete_env("NOETIC_HARNESS_WORKTREE_ROOT")

      on_exit(fn ->
        if override, do: System.put_env("NOETIC_HARNESS_WORKTREE_ROOT", override)
        if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
        File.rm_rf!(other)
        File.rm_rf!(root)
      end)

      {:ok, root: root}
    end

    test "only the branch with no ledger entry anywhere is an orphan" do
      assert {:ok, ["nowhere"]} == Workspace.orphans()
    end

    test "a run whose file lives in another worktree is not an orphan" do
      # The case that made the naive rule dangerous: branches are shared by
      # every worktree, ledger files are not.
      {:ok, orphans} = Workspace.orphans()
      refute "elsewhere" in orphans
    end

    test "a run that was committed and later removed is not an orphan" do
      {:ok, orphans} = Workspace.orphans()
      refute "history" in orphans
    end

    test "prune removes the orphan and leaves every other branch", %{root: root} do
      assert [{"nowhere", :ok}] == Workspace.prune(["nowhere"])

      remaining =
        git!(root, ["branch", "--list", "--format=%(refname:short)", "harness/run/*"])
        |> String.split("\n", trim: true)
        |> Enum.sort()

      assert remaining == ~w(harness/run/elsewhere harness/run/here harness/run/history)
    end

    test "a failure is reported per id, not summarised away" do
      assert [{"never-existed", {:error, message}}] = Workspace.prune(["never-existed"])
      assert message =~ "never-existed"
    end

    test "a directory a killed run left, with no branch and no worktree, is an orphan", %{
      root: root
    } do
      # Found by running the branch-only sweep on this repository: 250 MB under
      # `.git/noetic-harness/` that no branch and no `git worktree list` named.
      stray = Path.join([root, ".git", "noetic-harness", "stray"])
      File.mkdir_p!(stray)
      File.write!(Path.join(stray, "README"), "left behind")
      File.touch!(stray, System.os_time(:second) - 7200)

      claimed = Path.join([root, ".git", "noetic-harness", "here"])
      File.mkdir_p!(claimed)
      File.touch!(claimed, System.os_time(:second) - 7200)

      assert {:ok, ["nowhere", "stray"]} == Workspace.orphans()
      assert [{"stray", :ok}] == Workspace.prune(["stray"])
      refute File.exists?(stray)

      # `here` has a ledger entry, so its directory is somebody's evidence.
      assert [{"here", {:error, _}}] = Workspace.prune(["here"])
      assert File.dir?(claimed)
    end

    test "open/2 refuses a leftover directory rather than handing it back as a tree", %{
      root: root
    } do
      stray = Path.join([root, ".git", "noetic-harness", "stray"])
      File.mkdir_p!(stray)

      assert {:error, message} = Workspace.open("stray")
      assert message =~ "is not a worktree"
      assert is_binary(message)
    end

    test "a bare directory younger than an hour is not an orphan yet", %{root: root} do
      # It cannot be locked, and it may be a worktree `git worktree add` is
      # still creating.
      File.mkdir_p!(Path.join([root, ".git", "noetic-harness", "fresh"]))
      assert {:ok, ["nowhere"]} == Workspace.orphans()
    end

    test "a worktree locked by a live process is in use, even with no ledger entry", %{
      root: root
    } do
      # What `Environments` and `Scoring` open: a worktree with no run file.
      # Review deleted one from under a run in another session.
      {:ok, ws} = Workspace.open("verify-env-live")
      assert {:ok, ["nowhere"]} == Workspace.orphans()
      assert [{"verify-env-live", {:error, _}}] = Workspace.prune(["verify-env-live"])
      assert File.dir?(ws.path)

      # The same worktree once the VM that locked it is gone.
      git!(root, ["worktree", "unlock", ws.path])
      git!(root, ["worktree", "lock", "--reason", "noetic-harness pid:999999999", ws.path])
      assert {:ok, ["nowhere", "verify-env-live"]} == Workspace.orphans()
      assert [{"verify-env-live", :ok}] == Workspace.prune(["verify-env-live"])
      refute File.exists?(ws.path)
    end

    test "a killed test's worktree, its .git rewritten, does not outlive the next prune", %{
      root: root
    } do
      # An earlier change, as it was found: a test opened a worktree, rewrote its
      # `.git` (`harness_adapter_test.exs` does, on purpose), and its VM was
      # gone before a close could run — or the close failed on that file.
      # `noetic-harness workspace --prune` is what a worker's session start runs.
      {:ok, ws} = Workspace.open("jido-fsmonitor-killed")
      git!(root, ["worktree", "unlock", ws.path])
      git!(root, ["worktree", "lock", "--reason", "noetic-harness pid:999999999", ws.path])
      File.write!(Path.join(ws.path, ".git"), "gitdir: .evil\n")

      assert {:ok, ["jido-fsmonitor-killed", "nowhere"]} == Workspace.orphans()

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      Mix.Tasks.Harness.Workspace.run(["--prune"])

      assert_received {:mix_shell, :info, ["removed jido-fsmonitor-killed"]}
      refute File.exists?(ws.path)
      assert git!(root, ["branch", "--list", "harness/run/jido-fsmonitor-killed"]) == ""
      refute git!(root, ["worktree", "list"]) =~ "jido-fsmonitor-killed"
    end

    test "a lock with a reason that is not ours is in use", %{root: root} do
      {:ok, ws} = Workspace.open("a-person-locked-it")
      git!(root, ["worktree", "unlock", ws.path])
      git!(root, ["worktree", "lock", "--reason", "reviewing on the train", ws.path])
      assert {:ok, ["nowhere"]} == Workspace.orphans()
    end

    test "a history git cannot read is an error, and nothing is removed", %{root: root} do
      # One ref to a missing object makes `git log --all` fail. Counting that
      # as "not in history" made a committed run an orphan in review.
      refs = Path.join([root, ".git", "refs", "harness", "base"])
      File.mkdir_p!(refs)
      File.write!(Path.join(refs, "broken"), String.duplicate("1", 40) <> "\n")

      assert {:error, message} = Workspace.orphans()
      assert message =~ "cannot say no run claims it"
      assert [{"nowhere", {:error, _}}] = Workspace.prune(["nowhere"])
      assert git!(root, ["branch", "--list", "harness/run/nowhere"]) =~ "nowhere"
    end

    test "an id that could nest inside another run's directory is refused" do
      for id <- ["a/b", "../escape", ".hidden", ""] do
        assert {:error, message} = Workspace.open(id)
        assert message =~ "not a usable run id"
      end
    end

    test "prune refuses a run that has a ledger entry, even when a caller names it", %{
      root: root
    } do
      # The rule is enforced in `prune/1`, not in the task that calls it, so no
      # caller can delete a diff by naming it.
      for id <- ~w(here elsewhere history) do
        assert [{^id, {:error, message}}] = Workspace.prune([id])
        assert message =~ "is not an orphan"
      end

      assert git!(root, ["branch", "--list", "harness/run/here"]) =~ "harness/run/here"
    end

    test "the task lists the orphans and prunes only on --prune", %{root: root} do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Tasks.Harness.Workspace.run([])
      assert_received {:mix_shell, :info, ["orphaned runs (1)" <> listed]}
      assert listed =~ "nowhere"
      assert git!(root, ["branch", "--list", "harness/run/nowhere"]) =~ "nowhere"

      Mix.Tasks.Harness.Workspace.run(["--prune"])
      assert_received {:mix_shell, :info, ["removed nowhere"]}
      assert git!(root, ["branch", "--list", "harness/run/nowhere"]) == ""
    end
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end
end
