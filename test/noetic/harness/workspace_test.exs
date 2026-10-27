defmodule Noetic.Harness.WorkspaceTest do
  @moduledoc """
  The worktree is what stands between a dispatched agent and everybody else's
  working directory, so it is tested for isolation first and convenience never.


  """

  # async: false: every test here creates a real git worktree, and the
  # worktree root (`TmpfsWorktrees`) is a VM-global variable.
  use ExUnit.Case, async: false

  alias Noetic.Harness.Workspace

  # Not `System.unique_integer/1`, which restarts low in every VM: a branch
  # named after it outlives the VM, and a suite killed before its cleanup left
  # one the next suite collided with.
  defp unique, do: "#{System.os_time(:millisecond)}-#{:rand.uniform(99_999)}"

  # The worktrees go on tmpfs; `TmpfsWorktrees` says why. The
  # test about the default location is tagged `:default_root` and keeps it.
  setup_all {Noetic.Harness.TmpfsWorktrees, :root}
  # A git repository of each test's own, on the pack (`Noetic.Harness.Pack`),
  # rather than this repository: the worktree mechanics are the same, and a
  # checkout of it is a few hundred files instead of five thousand.
  setup {Noetic.Harness.Pack, :git_root}
  setup {Noetic.Harness.TmpfsWorktrees, :use_root}

  setup do
    run = "workspace-test-#{unique()}"
    {:ok, workspace} = Workspace.open(run)
    on_exit(fn -> Workspace.close(workspace, discard: true) end)
    {:ok, run: run, ws: workspace}
  end

  defp write!(ws, path, content) do
    full = Path.join(ws.path, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  describe "isolation" do
    test "it is a real checkout on its own branch", %{run: run, ws: ws} do
      assert File.dir?(ws.path)
      assert File.regular?(Path.join(ws.path, "CHANGELOG.md"))
      assert ws.branch == "harness/run/" <> run
    end

    @tag :default_root
    test "it is not inside the working tree", %{ws: ws} do
      # The whole point. A worktree beside the source is an untracked directory
      # in the parent's `git status`, one `git add` from being committed by
      # somebody who did not write it — which is the failure this repository
      # already forbids `git add -A` over.
      root = Noetic.Harness.root()
      refute String.starts_with?(ws.path, Path.join(root, "apps"))
      refute String.starts_with?(ws.path, Path.join(root, "docs"))
      refute String.starts_with?(ws.path, Path.join(root, ".agents"))
    end

    test "writing in it does not touch the parent's copy", %{ws: ws} do
      parent = Path.join(Noetic.Harness.root(), "CHANGELOG.md")
      original = File.read!(parent)

      write!(ws, "CHANGELOG.md", "not the real one\n")

      assert File.read!(parent) == original
    end

    test "two runs get two trees", %{ws: ws} do
      other = "workspace-test-#{unique()}"
      {:ok, second} = Workspace.open(other)
      on_exit(fn -> Workspace.close(second, discard: true) end)

      refute second.path == ws.path
      refute second.branch == ws.branch
    end
  end

  describe "what it says changed" do
    test "a file the agent edited", %{ws: ws} do
      write!(ws, "CHANGELOG.md", "rewritten\n")
      assert {:ok, paths} = Workspace.changed_paths(ws)
      assert "CHANGELOG.md" in paths
    end

    test "a file the agent created", %{ws: ws} do
      # `git diff` alone does not show an untracked file, so a fence built on
      # one would miss every new file an agent wrote — including a new gate.
      write!(ws, "apps/acme/lib/acme/invented.ex", "defmodule Invented do\nend\n")

      assert {:ok, paths} = Workspace.changed_paths(ws)
      assert "apps/acme/lib/acme/invented.ex" in paths
    end

    test "a file the agent deleted", %{ws: ws} do
      File.rm!(Path.join(ws.path, "CHANGELOG.md"))
      assert {:ok, paths} = Workspace.changed_paths(ws)
      assert "CHANGELOG.md" in paths
    end

    test "nothing, when nothing happened", %{ws: ws} do
      # And it is `{:ok, []}` rather than an error: "nothing to see" and "could
      # not see" are different facts and the fence reads them differently.
      assert {:ok, []} = Workspace.changed_paths(ws)
    end

    test "the diff is the patch, not a summary of it", %{ws: ws} do
      write!(ws, "CHANGELOG.md", "rewritten\n")

      assert {:ok, patch} = Workspace.diff(ws)
      assert patch =~ "diff --git"
      assert patch =~ "+rewritten"
    end
  end

  describe "the base it measures against" do
    test "a re-opened workspace has the base it was created with", %{run: run, ws: ws} do
      # Not today's HEAD, which the parent may have moved, and not the branch
      # tip, which the run may have committed to. Both were tried and both
      # silently change what the diff contains.
      assert {:ok, again} = Workspace.open(run)
      assert again.base == ws.base
      assert again.path == ws.path
    end

    test "the base is a full sha, so it compares equal to what git reads back", %{ws: ws} do
      # A short sha names the same commit and works in every git command, which
      # is exactly why this was wrong for a while and looked fine.
      assert String.length(ws.base) == 40
    end

    test "a re-opened workspace still sees what the first one wrote", %{run: run, ws: ws} do
      write!(ws, "CHANGELOG.md", "rewritten\n")

      {:ok, again} = Workspace.open(run)
      assert {:ok, paths} = Workspace.changed_paths(again)
      assert "CHANGELOG.md" in paths
    end
  end

  describe "closing" do
    test "it keeps the tree by default, because the evidence is not reverted", %{ws: ws} do
      write!(ws, "CHANGELOG.md", "rewritten\n")

      assert :ok = Workspace.close(ws)

      # `.agents/policies/failure.md`: a rejected run is diagnosable or the
      # rejection taught nobody anything.
      assert File.dir?(ws.path)
      assert File.read!(Path.join(ws.path, "CHANGELOG.md")) == "rewritten\n"
    end

    test "discarding takes the tree, the branch and the base ref", %{run: run, ws: ws} do
      assert :ok = Workspace.close(ws, discard: true)

      refute File.dir?(ws.path)
      {:ok, branches} = branches()
      refute ws.branch in branches

      # And a workspace opened again afterwards is a new one rather than a
      # resurrection of the old base.
      {:ok, fresh} = Workspace.open(run)
      on_exit(fn -> Workspace.close(fresh, discard: true) end)
      assert {:ok, []} = Workspace.changed_paths(fresh)
    end
  end

  describe "closing a tree a test broke" do
    # `harness_adapter_test.exs` rewrites a worktree's `.git` to
    # prove the host never believes it, and `git worktree remove` refuses such
    # a tree whatever it is forced with. Its `on_exit` close failed on every
    # run, and one locked `jido-fsmonitor-*` worktree outlived each suite.
    test "discarding takes a tree whose .git no longer points home", %{ws: ws} do
      File.write!(Path.join(ws.path, ".git"), "gitdir: .evil\n")

      assert :ok = Workspace.close(ws, discard: true)

      refute File.exists?(ws.path)
      {:ok, branches} = branches()
      refute ws.branch in branches
    end
  end

  describe "listing" do
    test "it names the runs whose diffs nobody has read yet", %{run: run} do
      assert {:ok, runs} = Workspace.list()
      assert run in runs
    end
  end

  defp branches do
    case System.cmd("git", ["branch", "--list", "harness/run/*", "--format=%(refname:short)"],
           cd: Noetic.Harness.root(),
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.split(output, "\n", trim: true)}
      _ -> :error
    end
  end
end
