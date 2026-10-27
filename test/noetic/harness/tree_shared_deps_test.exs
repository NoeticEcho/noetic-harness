defmodule Noetic.Harness.TreeSharedDepsTest do
  @moduledoc """
  A verification's `mix` reaches the caller's `deps/` through the
  worktree's symlink, and a dependency built by `elixir_make` compiles in its
  own source directory. Through the path a verification actually takes —
  `Tree.run_tests/3` with nothing extra read-only — a write into `deps/` must
  fail rather than land in the shared checkout.

  The existing sandbox test builds its own `bwrap` command, so it proves the
  mechanism and not that `run_tests/3` uses it for a verification.
  """

  # `async: false` because the stub `mix` is found through `PATH`, which is
  # VM-global: a concurrent test running `mix` would run this stub instead.
  use ExUnit.Case, async: false

  alias Noetic.Harness.Tree

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "root") |> Noetic.Harness.Fixture.write_project()
    File.mkdir_p!(Path.join([root, "deps", "lazy"]))
    File.write!(Path.join([root, "deps", "lazy", "Makefile"]), "all:\n")

    tree = Path.join(dir, "tree")
    File.mkdir_p!(Path.join([tree, "apps", "tiny"]))

    # What `elixir_make` does when a dependency needs rebuilding: write an
    # object file next to its source. The cwd is `<tree>/apps/tiny`.
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    stub = Path.join(bin, "mix")
    File.write!(stub, "#!/bin/sh\necho built > ../../deps/lazy/lazy.o || exit 3\nexit 0\n")
    File.chmod!(stub, 0o755)

    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    previous = Noetic.Harness.put_root(root)

    on_exit(fn ->
      System.put_env("PATH", path)

      if previous,
        do: Noetic.Harness.put_root(previous),
        else: Noetic.Harness.delete_root()
    end)

    Noetic.Harness.put_root(root)
    Tree.prepare(tree)
    %{root: root, tree: tree}
  end

  test "a dependency rebuilt during a verification does not write into the shared deps",
       %{root: root, tree: tree} do
    assert {:ok, _} = File.read_link(Path.join(tree, "deps")),
           "prepare/1 did not make the symlink, so this test is about nothing"

    shared = Path.join([root, "deps", "lazy", "lazy.o"])

    if Tree.confined?() do
      {output, status} = Tree.run_tests("tiny", [], tree)

      refute File.exists?(shared),
             "the verification wrote #{shared} through the worktree's deps symlink"

      assert status == 3, "the stub's write was expected to fail with EROFS: #{output}"
    else
      IO.puts("\n  tree: bwrap is absent, so a rebuilt dependency writes into the shared deps")
    end
  end
end
