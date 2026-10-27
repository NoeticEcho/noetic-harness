defmodule Noetic.Harness.TmpfsWorktrees do
  @moduledoc """
  Run worktrees on tmpfs, for the test modules that open one per test.

  A worktree is a checkout of the whole repository, ~5,000 files and ~300 MB.
  On the worker VM's disk opening one took ~3 s idle and 5.4-9.0 s beside
  `stress-ng --hdd 6 --iomix 4` with 468 MB dirty; on tmpfs, 1.2-1.4 s. On the
  workstation, with other writers, `WorkspaceTest` ran out a 60 s timeout in a
  `File.write!/2` queued behind a checkout's dirty pages. What these modules
  test is git's worktree mechanics and the harness's use of them, not where the
  bytes land.

  `NOETIC_HARNESS_WORKTREE_ROOT` is VM-global, so only an `async: false`
  module may use this. A test tagged `:default_root` keeps the default location,
  for the tests that are about it. Where there is no `/dev/shm` the worktrees go
  where they always did, and the module says so.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @tmpfs "/dev/shm"
  @var "NOETIC_HARNESS_WORKTREE_ROOT"

  @doc "A `setup_all` callback: choose the tmpfs root and remove it after the module."
  @spec root(map()) :: {:ok, keyword()}
  def root(context) do
    root = Path.join(@tmpfs, "noetic-harness-test-#{System.pid()}")

    if File.dir?(@tmpfs) do
      on_exit(fn -> File.rm_rf(root) end)
      {:ok, tmpfs_root: root}
    else
      IO.puts("#{inspect(context.module)}: no #{@tmpfs}, so the worktrees go on disk, under .git")
      {:ok, tmpfs_root: nil}
    end
  end

  @doc "A `setup` callback: point this test's worktrees at the tmpfs root, unless it is tagged `:default_root`."
  @spec use_root(map()) :: :ok
  def use_root(context) do
    previous = System.get_env(@var)

    if context[:tmpfs_root] && !context[:default_root] do
      System.put_env(@var, context.tmpfs_root)
    end

    on_exit(fn ->
      if previous, do: System.put_env(@var, previous), else: System.delete_env(@var)
    end)

    :ok
  end
end
