defmodule Noetic.Harness.WorkspaceSymlinkTest do
  @moduledoc """
  A repository reached through a symlink, which is every temporary directory
  on macOS (`/var` → `/private/var`) and any linked checkout on Linux.
  Git records a worktree by its physical path, so the harness
  has to compare physical paths too — without ever resolving the `.git` the
  agent writes.
  """

  # async: false: `NOETIC_HARNESS_WORKTREE_ROOT` is VM-global, and these
  # tests need it unset so the worktrees go under the linked `.git`.
  use ExUnit.Case, async: false

  alias Noetic.Harness.{Realpath, TestTmp, Workspace}

  @var "NOETIC_HARNESS_WORKTREE_ROOT"

  setup do
    previous = System.get_env(@var)
    System.delete_env(@var)
    on_exit(fn -> if previous, do: System.put_env(@var, previous) end)

    # The repository lives in a real directory, and the harness is pointed at
    # it through a link to its parent — the macOS `$TMPDIR` in miniature.
    real = Noetic.Harness.Pack.make(git: true)
    link = TestTmp.path("linked")
    File.ln_s!(Path.dirname(real), link)
    on_exit(fn -> File.rm(link) end)

    root = Path.join(link, Path.basename(real))
    Noetic.Harness.put_root(root)
    {:ok, root: root, real: real}
  end

  defp open! do
    {:ok, ws} = Workspace.open("symlink-test-#{System.unique_integer([:positive])}")
    ws
  end

  defp admin(ws) do
    {:ok, git} = Workspace.tree_git(ws.path)
    Enum.find_value(git, &(String.starts_with?(&1, "--git-dir=") && &1))
  end

  test "a worktree under a linked parent is found, and its changes are read", %{root: root} do
    ws = open!()
    # The precondition: the harness spells the tree through the link, and
    # git's record of it does not.
    assert String.starts_with?(ws.path, root)

    assert {:ok, gitdir} =
             File.read(Path.join(String.replace_prefix(admin(ws), "--git-dir=", ""), "gitdir"))

    refute String.starts_with?(gitdir, root)

    File.write!(Path.join(ws.path, "NEW.md"), "agent wrote this\n")
    assert {:ok, paths} = Workspace.changed_paths(ws)
    assert "NEW.md" in paths
  end

  # The guarantee the fix must not weaken. The agent replaces its `.git` with
  # a link to another run's: resolving `path/.git` whole would follow it and
  # match the other run's admin directory. The leaf is compared by name, so
  # the tree is still found by the directory it is in, through its *own*
  # admin directory — not refused, and never the other run's.
  test "an agent's .git symlink to another worktree is not followed" do
    mine = open!()
    other = open!()
    own = admin(mine)
    refute own == admin(other)

    File.rm!(Path.join(mine.path, ".git"))
    File.ln_s!(Path.join(other.path, ".git"), Path.join(mine.path, ".git"))

    assert admin(mine) == own

    File.write!(Path.join(mine.path, "MINE.md"), "x\n")
    assert {:ok, mine_paths} = Workspace.changed_paths(mine)
    assert "MINE.md" in mine_paths
    assert {:ok, other_paths} = Workspace.changed_paths(other)
    refute "MINE.md" in other_paths
  end

  describe "Realpath.resolve/1" do
    test "resolves a link, and `..` after it from where the link points", %{
      real: real,
      root: root
    } do
      assert Realpath.resolve(root) == Realpath.resolve(real)
      {:ok, physical} = Realpath.resolve(real)
      assert Realpath.resolve(Path.join([root, ".git", ".."])) == {:ok, physical}
    end

    test "a missing component and a cycle are errors, not guesses" do
      dir = TestTmp.dir!("realpath")
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:error, _} = Realpath.resolve(Path.join(dir, "absent/x"))

      File.ln_s!(Path.join(dir, "b"), Path.join(dir, "a"))
      File.ln_s!(Path.join(dir, "a"), Path.join(dir, "b"))
      assert {:error, message} = Realpath.resolve(Path.join(dir, "a"))
      assert message =~ "symbolic links"
    end
  end
end
