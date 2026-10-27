defmodule Noetic.Harness.TreeTest do
  # `async: true`: each test builds its own git repository under `tmp_dir` and
  # points the harness root there with `Noetic.Harness.put_root/1`, which is
  # per process since an earlier change. Nothing VM-global is written.
  use ExUnit.Case, async: true

  alias Noetic.Harness.Tree

  # `confine/3` used to run `git clean -qfd` with no `-x`, so
  # anything ignored survived it: a planted `_build/payload`, a stray `.beam`,
  # a write anywhere under `deps/`. An independent review of an earlier change
  # demonstrated exactly that, and it is a scoring-integrity question rather
  # than hygiene — mix trusts a `.beam` with a fresh mtime, so a planted one is
  # a compiled module the verifier then runs.

  defp git(args, dir), do: {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  setup do
    base_dir = Noetic.Harness.TestTmp.path("tree")

    # The "real repository": what `prepare/1` seeds a worktree *from*.
    root = Path.join(base_dir, "root")
    File.mkdir_p!(Path.join([root, "apps", "tiny"]))
    File.mkdir_p!(Path.join([root, "deps", "fakedep"]))
    File.write!(Path.join([root, "deps", "fakedep", "mix.exs"]), "# a dependency\n")
    File.mkdir_p!(Path.join([root, "_build", "test", "lib", "fakedep", "ebin"]))
    File.write!(Path.join([root, "_build", "test", "lib", "fakedep", "ebin", "real.beam"]), "OK")

    # The source the solver's tree is checked out from, committed in the real
    # repository.
    File.mkdir_p!(Path.join([root, "apps", "tiny", "lib"]))
    File.write!(Path.join([root, "apps", "tiny", "lib", "tiny.ex"]), "defmodule Tiny do\nend\n")
    File.write!(Path.join(root, ".gitignore"), "_build/\ndeps/\n*.beam\n")

    git(["init", "--quiet", "-b", "main"], root)
    git(["config", "user.email", "t@t"], root)
    git(["config", "user.name", "t"], root)
    git(["add", "-A"], root)
    git(["commit", "-qm", "base"], root)

    # Where the build directory and the apps are is the project's layout.
    # Untracked, so the worktree below never sees it.
    Noetic.Harness.Fixture.write_project(root)

    # The worktree the solver works in — a real `git worktree`, as
    # `Environments` and `Scoring` make one. It used to be a separate `git
    # init`, which `Workspace.tree_git/1` rightly refuses: a plain repository's
    # `.git` is inside the tree, config and all, so nothing about it can be
    # trusted after the solver has run.
    tree = Path.join(base_dir, "tree")
    git(["worktree", "add", "--quiet", "--detach", tree, "HEAD"], root)
    {base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tree)

    Noetic.Harness.put_root(root)
    on_exit(fn -> File.rm_rf(base_dir) end)

    Tree.prepare(tree)

    {:ok, tree: tree, root: root, base: String.trim(base)}
  end

  describe "a tree the solver has rewritten the .git of" do
    test "confine/3 does not run a command from a config the solver wrote", %{
      tree: tree,
      base: base
    } do
      # An earlier change's review: a solver may write anything in its tree, `.git`
      # included, and `core.fsmonitor` in a config it points `.git` at is a
      # command the host's next `git add` runs.
      marker = Path.join(System.tmp_dir!(), "tree-fsmonitor-#{System.os_time(:nanosecond)}")
      on_exit(fn -> File.rm(marker) end)

      evil = Path.join(tree, ".evil")
      File.mkdir_p!(Path.join(evil, "objects"))
      File.mkdir_p!(Path.join([evil, "refs", "heads"]))
      File.write!(Path.join(evil, "HEAD"), "ref: refs/heads/main\n")
      File.write!(Path.join(evil, "config"), "[core]\n\tfsmonitor = \"touch #{marker}; false\"\n")
      File.write!(Path.join(tree, ".git"), "gitdir: .evil\n")

      _ = Tree.confine(tree, base, [])
      _ = Tree.commit(tree, "after the solver")
      refute File.exists?(marker), "the host ran a command from a config the solver wrote"
    end
  end

  describe "what confinement now removes" do
    test "a planted file under _build", %{tree: tree, base: base} do
      payload = Path.join([tree, "_build", "payload"])
      File.write!(payload, "planted")

      {:ok, reverted} = Tree.confine(tree, base, [])

      refute File.exists?(payload),
             "a file under `_build/` survived confinement, which is how `bd-arc.21` was found"

      assert Enum.any?(reverted, &(&1 =~ "_build")),
             "it was removed but not reported, so the fence still cannot see it: " <>
               inspect(reverted)
    end

    test "a stray .beam anywhere", %{tree: tree, base: base} do
      # The one that matters most. mix trusts a `.beam` with a fresh mtime, so
      # this is a compiled module the verifier would load.
      stray = Path.join([tree, "apps", "tiny", "lib", "Elixir.Tiny.beam"])
      File.write!(stray, "planted")

      {:ok, _reverted} = Tree.confine(tree, base, [])

      refute File.exists?(stray), "a stray .beam survived confinement"
    end

    test "a file planted inside a seeded dependency", %{tree: tree, base: base} do
      # An exclusion protects a *directory*, so this is the case the exclusion
      # cannot handle on its own — and the reason each seeded directory is
      # compared against its source rather than trusted.
      evil = Path.join([tree, "_build", "test", "lib", "fakedep", "ebin", "evil.beam"])
      File.write!(evil, "planted")

      {:ok, _reverted} = Tree.confine(tree, base, [])

      refute File.exists?(evil),
             "a file planted inside a seeded dependency survived, so the exclusion is a hole"

      assert File.read!(
               Path.join([tree, "_build", "test", "lib", "fakedep", "ebin", "real.beam"])
             ) ==
               "OK",
             "the divergent dependency was removed and not re-seeded"
    end

    test "a directory that merely looks like a seeded one", %{tree: tree, base: base} do
      # The exclusions are computed from the SOURCE tree. A solver that creates
      # `_build/test/lib/evil/` must not be able to protect it by naming it
      # like a dependency.
      evil = Path.join([tree, "_build", "test", "lib", "evil", "ebin"])
      File.mkdir_p!(evil)
      File.write!(Path.join(evil, "evil.beam"), "planted")

      {:ok, _reverted} = Tree.confine(tree, base, [])

      refute File.exists?(evil),
             "a directory the solver invented under `_build/test/lib` was protected as though " <>
               "it were seeded — the exclusion list is being read from the worktree"
    end
  end

  describe "what confinement must not remove" do
    test "the seeded dependency and the deps symlink", %{tree: tree, base: base} do
      # The reason a bare `-x` was not available. Re-seeding after every
      # confinement was measured at 32s for 93MB on this machine, against a
      # verification that takes 1m35s with the seed and 7m06s without it.
      {:ok, _reverted} = Tree.confine(tree, base, [])

      assert File.read!(
               Path.join([tree, "_build", "test", "lib", "fakedep", "ebin", "real.beam"])
             ) ==
               "OK"

      assert File.exists?(Path.join([tree, "deps", "fakedep", "mix.exs"])),
             "the deps symlink was removed, which turns a 1m35s verification into 7m06s"
    end

    test "a kept path keeps the solver's content", %{tree: tree, base: base} do
      keep = "apps/tiny/lib/tiny.ex"
      solved = "defmodule Tiny do\n  def value, do: :FIXED\nend\n"
      File.write!(Path.join(tree, keep), solved)

      {:ok, reverted} = Tree.confine(tree, base, [keep])

      assert File.read!(Path.join(tree, keep)) == solved
      refute keep in reverted
    end

    test "a tracked change outside keep still goes back and is reported", %{
      tree: tree,
      base: base
    } do
      File.write!(Path.join(tree, ".gitignore"), "_build/\ndeps/\n*.beam\nnope\n")

      {:ok, reverted} = Tree.confine(tree, base, ["apps/tiny/lib/tiny.ex"])

      assert ".gitignore" in reverted
      refute File.read!(Path.join(tree, ".gitignore")) =~ "nope"
    end
  end

  describe "the exclusion list" do
    test "names the source's dependencies and the deps symlink", %{root: _root} do
      seeded = Tree.seeded()

      assert "/deps" in seeded
      assert "/_build/test/lib/fakedep" in seeded

      refute Enum.any?(seeded, &(&1 =~ "evil")),
             "the list is being built from somewhere other than the source tree"
    end

    test "excludes this repository's own apps, which are rebuilt rather than seeded" do
      # `_build/test/lib/noetic_harness*` is the thing under test; seeding it would
      # carry the previous attempt's compilation into the next one.
      Noetic.Harness.delete_root()

      seeded = Tree.seeded()

      # By name, not by a substring of the product's name: a vendored
      # dependency whose name begins like ours is seeded like any other, and
      # the substring took one for an app of ours the day it was vendored.
      own = ~w(noetic_harness)
      ours = Enum.filter(seeded, &(Path.basename(&1) in own))

      assert ours == [],
             "an app of this umbrella is in the exclusion list, so a solver's own compiled " <>
               "output would survive confinement: #{inspect(ours)}"
    end
  end

  describe "the oracle a solver cannot reach" do
    # `mix test` compiles the solver's file **before** ExUnit
    # loads the verifier, so a module body in a solver's source is code the
    # scoring host executes. An independent review used exactly that to rewrite
    # the verifier `Tree.restore/3` had just put back, and scored
    # `solved: true` on a defect it had not touched.
    #
    # These tests build that attack and run it both ways. Without the read-only
    # bind the oracle is rewritten; with it the write fails with `EROFS` before
    # the verifier is ever loaded. That is the difference between detection and
    # containment.

    @oracle "defmodule TinyTest do\n  use ExUnit.Case\n  test \"the fix\" do\n    assert Tiny.value() == :fixed\n  end\nend\n"

    defp attacking_project(root) do
      app = Path.join([root, "apps", "tiny"])
      File.mkdir_p!(Path.join(app, "lib"))
      File.mkdir_p!(Path.join(app, "test"))

      File.write!(Path.join(app, "mix.exs"), """
      defmodule Tiny.MixProject do
        use Mix.Project
        def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.18"]
        def application, do: []
      end
      """)

      File.write!(Path.join([app, "test", "test_helper.exs"]), "ExUnit.start()\n")
      File.write!(Path.join([app, "test", "tiny_test.exs"]), @oracle)

      # The attack, verbatim in shape: a write in the **module body**, which
      # runs at compile time, before ExUnit has loaded anything.
      oracle = Path.join([app, "test", "tiny_test.exs"])

      File.write!(Path.join([app, "lib", "tiny.ex"]), """
      defmodule Tiny do
        File.write!(#{inspect(oracle)}, "defmodule TinyTest do\\n  use ExUnit.Case\\n  test \\"the fix\\" do\\n    assert true\\n  end\\nend\\n")
        def value, do: :broken
      end
      """)

      oracle
    end

    @tag :tmp_dir
    test "without the boundary the attack works, which is why there is one", %{tmp_dir: dir} do
      # The calibration, and it has to come first: if the attack does not work
      # unconfined, the test below proves nothing.
      oracle = attacking_project(dir)

      Tree.run_tests("tiny", ["test/tiny_test.exs"], dir, [])

      refute File.read!(oracle) == @oracle,
             "the attack did not rewrite the oracle even without a boundary, so this " <>
               "environment cannot demonstrate the property and the test below is vacuous"
    end

    @tag :tmp_dir
    test "with the boundary the write fails and the oracle is intact", %{tmp_dir: dir} do
      if Tree.confined?() do
        oracle = attacking_project(dir)

        {output, status} =
          Tree.run_tests("tiny", ["test/tiny_test.exs"], dir, ["apps/tiny/test/tiny_test.exs"])

        assert File.read!(oracle) == @oracle,
               "the oracle was rewritten despite the read-only bind"

        refute status == 0,
               "the run succeeded although the solver's compilation should have failed on a " <>
                 "read-only write: #{String.slice(output, 0, 300)}"
      else
        IO.puts("\n  tree: bwrap is absent, so the oracle cannot be made read-only here")
      end
    end

    test "confined?/0 probes rather than trusting that bwrap is installed" do
      # Present is not the same as working: user namespaces are disabled on
      # some hosts and `bwrap` then fails at the first bind. The same rule
      # `noetic-harness inspect --tools` applies to every gate tool.
      assert is_boolean(Tree.confined?())

      if System.find_executable("bwrap") == nil do
        refute Tree.confined?()
      end
    end

    test "a readonly list that names nothing present does not wrap the command" do
      # A bind of a path that does not exist makes `bwrap` fail, which would
      # turn every scoring run into an environmental failure on a machine where
      # the verifier moved. Filtered rather than trusted.
      dir = Noetic.Harness.TestTmp.path("tree-nb")
      File.mkdir_p!(Path.join([dir, "apps", "tiny"]))
      on_exit(fn -> File.rm_rf(dir) end)

      {_output, status} = Tree.run_tests("tiny", [], dir, ["apps/tiny/test/nothing_here.exs"])

      refute status == 127,
             "the command could not be executed at all, which is what a bind on a missing " <>
               "path does"
    end
  end

  describe "the shared deps a worktree points at" do
    # An earlier change's residual, found while closing an earlier change. `prepare/1`
    # symlinks `tree/deps` at the **real repository's** `deps/`, so a solver
    # writing `deps/<anything>` modifies the shared checkout — outside the
    # worktree's git, so `changed_paths/1` cannot see it and `confine/3` cannot
    # revert it. Every later verification then uses the modified dependency.

    @tag :tmp_dir
    test "a write through the symlink is refused inside the sandbox", %{tmp_dir: dir} do
      if Tree.confined?() do
        root = Path.join(dir, "root")
        File.mkdir_p!(Path.join([root, "deps", "fakedep"]))
        dep = Path.join([root, "deps", "fakedep", "mix.exs"])
        File.write!(dep, "# the real dependency\n")

        tree = Path.join(dir, "tree")
        File.mkdir_p!(Path.join([tree, "apps", "tiny"]))
        Noetic.Harness.put_root(root)
        Tree.prepare(tree)

        assert {:ok, _target} = File.read_link(Path.join(tree, "deps")),
               "prepare/1 did not make the symlink, so this test is about nothing"

        through = Path.join([tree, "deps", "fakedep", "mix.exs"])

        # Unconfined first, so that the assertion below is not vacuous. This is
        # the hole: a relative write inside the worktree lands in the shared
        # checkout.
        File.write!(through, "TAMPERED\n")
        assert File.read!(dep) == "TAMPERED\n", "the symlink does not write through here"
        File.write!(dep, "# the real dependency\n")

        {_output, status} =
          System.cmd(
            "bwrap",
            [
              "--dev-bind",
              "/",
              "/",
              "--ro-bind",
              Path.join(root, "deps"),
              Path.join(root, "deps"),
              "--",
              "sh",
              "-c",
              "echo TAMPERED > #{through}"
            ],
            stderr_to_stdout: true
          )

        refute status == 0, "the write through the symlink succeeded inside the sandbox"

        assert File.read!(dep) == "# the real dependency\n",
               "the shared repository's dependency was modified from inside a scoring worktree"
      else
        IO.puts("\n  tree: bwrap is absent, so the shared deps cannot be protected here")
      end
    end

    test "a tree with no deps symlink adds no bind" do
      # `File.read_link/1` on a plain directory answers `{:error, :einval}`,
      # and treating that as a path would make `bwrap` fail on every tree that
      # was never prepared.
      dir = Noetic.Harness.TestTmp.path("tree-nd")
      File.mkdir_p!(Path.join([dir, "deps"]))
      File.mkdir_p!(Path.join([dir, "apps", "tiny"]))
      on_exit(fn -> File.rm_rf(dir) end)

      {_output, status} = Tree.run_tests("tiny", [], dir, [])

      refute status == 127,
             "the command could not be executed, which is what a bad bind does"
    end
  end

  describe "a history of the solver's own" do
    # A worktree shares its repository's objects, so `git show <fix>` inside a
    # scoring tree was the answer. `sever/2` points the tree's `.git` at a
    # repository holding one commit and asks three things of it before the
    # solver arrives; each test below is one of them failing, or none.

    # A second worktree at a commit of its own, not prepared: `setup`'s is,
    # and a prepared tree is not its commit any more.
    defp unprepared(root, base_dir) do
      File.write!(
        Path.join([root, "apps", "tiny", "lib", "tiny.ex"]),
        "defmodule Tiny, do: :FIXED\n"
      )

      git(["commit", "-qam", "the fix"], root)
      {fix, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)

      tree = Path.join(base_dir, "unprepared")
      git(["worktree", "add", "--quiet", "--detach", tree, "HEAD"], root)
      {tree, String.trim(fix)}
    end

    defp in_tree(tree, args), do: System.cmd("git", args, cd: tree, stderr_to_stdout: true)

    test "the tree's git holds one commit, its own files, and not the fix", %{root: root} do
      {tree, fix} = unprepared(root, Path.dirname(root))
      {host_tree, 0} = in_tree(tree, ["rev-parse", "HEAD^{tree}"])

      assert {:ok, severed} = Tree.sever(tree, [fix])

      assert {_, status} = in_tree(tree, ["show", fix])
      refute status == 0
      assert {_, status} = in_tree(tree, ["show", "HEAD~1"])
      refute status == 0
      assert {log, 0} = in_tree(tree, ["log", "--all", "--format=%H"])
      assert length(String.split(log, "\n", trim: true)) == 1
      refute log =~ fix
      assert {^host_tree, 0} = in_tree(tree, ["rev-parse", "HEAD^{tree}"])
      assert {"", 0} = in_tree(tree, ["status", "--porcelain"])

      # The host still reads the tree through its own admin directory.
      head = fix <> "\n"
      {:ok, host} = Noetic.Harness.Workspace.tree_git(tree)
      assert {^head, 0} = System.cmd("git", host ++ ["rev-parse", "HEAD"])

      assert :ok = Tree.rejoin(severed)
      assert {^head, 0} = in_tree(tree, ["rev-parse", "HEAD"])
      refute File.exists?(severed.dir)
    end

    test "an object the tree's files hold is refused, and the tree is put back", %{root: root} do
      {tree, fix} = unprepared(root, Path.dirname(root))

      assert {:error, message} = Tree.sever(tree, ["HEAD:apps/tiny/lib/tiny.ex"])
      assert message =~ "holds HEAD:apps/tiny/lib/tiny.ex"

      head = fix <> "\n"
      assert {^head, 0} = in_tree(tree, ["rev-parse", "HEAD"])
    end

    test "a tree with more in it than its commit is refused", %{tree: tree, base: base} do
      # `setup` prepared this one: `deps` and `_build` are in it now.
      assert {:error, message} = Tree.sever(tree, [])
      assert message =~ "is not the prepared commit's tree"

      head = base <> "\n"
      assert {^head, 0} = in_tree(tree, ["rev-parse", "HEAD"])
    end

    test "a revision the host cannot resolve is refused rather than checked against nothing",
         %{root: root} do
      {tree, _fix} = unprepared(root, Path.dirname(root))

      assert {:error, message} = Tree.sever(tree, [String.duplicate("0", 40)])
      assert message =~ "cannot resolve"
      assert File.regular?(Path.join(tree, ".git"))
    end

    # Found in review of the first version. `Workspace.root/0` is the host's
    # `.git/noetic-harness/`, and from a severed tree there `git -C .. show
    # <fix>` read the fix, because git searches upward from `..`.
    test "a tree whose parent is inside a repository is refused, and left joined",
         %{root: root} do
      {_tree, fix} = unprepared(root, Path.dirname(root))
      tree = Path.join([root, ".git", "noetic-harness", "inside"])
      git(["worktree", "add", "--quiet", "--detach", tree, "HEAD"], root)

      assert {_, 0} = in_tree(tree, ["-C", "..", "show", fix])

      assert {:error, message} = Tree.sever(tree, [fix])
      # Not the path itself: git names it physically, and a temporary
      # directory reached through a symlink would spell it differently.
      assert message =~ "is inside the repository at "
      assert message =~ "would read that repository's history"

      head = fix <> "\n"
      assert {^head, 0} = in_tree(tree, ["rev-parse", "HEAD"])
    end

    test "solver_root/0 is private, its own physical path, and in no repository" do
      assert {:ok, dir} = Tree.solver_root()
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, %{type: :directory, mode: mode}} = File.stat(dir)
      assert Bitwise.band(mode, 0o777) == 0o700
      assert {physical, 0} = System.cmd("pwd", ["-P"], cd: dir)
      assert String.trim(physical) == dir

      assert {output, status} =
               System.cmd("git", ["rev-parse", "--git-dir"], cd: dir, stderr_to_stdout: true)

      assert status != 0, output

      assert {:ok, other} = Tree.solver_root()
      on_exit(fn -> File.rm_rf(other) end)
      refute other == dir
    end
  end
end
