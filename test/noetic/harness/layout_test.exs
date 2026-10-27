defmodule Noetic.Harness.LayoutTest do
  @moduledoc """
  The app layout is the project's: where an app's source and
  tests are, how its tests run, and what a worktree is seeded from, read from
  `.agents/registry/project.json`'s `layout` by `Environments`, `Scoring` and
  `Tree`.

  This repository's layout gives the answers the code gave when it was
  hard-coded; an earlier change's snapshot and `environments --verify` runs show
  that. What this file shows is the other half: a repository laid out
  differently is read as it says, and one that says nothing is told so.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Environments, Fixture, Project, Tree}

  # The pack's copy, read when the module compiles: the harness root is not
  # yet any test's, and a standalone checkout of the engine has no `.agents/`.
  @schema Noetic.Harness.Loader.load!(
            Path.join([Noetic.Harness.Pack.source(), "schemas", "project.schema.json"])
          )

  @packages %{
    "apps" => "packages",
    "lib" => "src",
    "test" => "spec",
    "test_suffix" => "_spec.exs",
    "test_command" => ["echo", "ran"],
    "build" => "out"
  }

  defp git(args, dir), do: {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  defp errors(project),
    do: for({:error, m} <- Project.validate(project: project, schema: @schema), do: m)

  @tag this_repository: true
  test "this repository's layout is the one the code used to name" do
    assert Project.layout() == %{
             apps: "apps",
             lib: "lib",
             test: "test",
             test_suffix: "_test.exs",
             test_command: ["mix", "test"],
             build: "_build"
           }
  end

  describe "a repository laid out otherwise" do
    setup do
      root = Noetic.Harness.TestTmp.path("layout")
      File.mkdir_p!(Path.join([root, "packages", "tiny", "src"]))

      File.write!(
        Path.join([root, "packages", "tiny", "src", "tiny.ex"]),
        "defmodule Tiny do\nend\n"
      )

      git(["init", "--quiet", "-b", "main"], root)
      git(["config", "user.email", "t@t"], root)
      git(["config", "user.name", "t"], root)
      git(["add", "-A"], root)
      git(["commit", "-qm", "base"], root)

      File.write!(
        Path.join([root, "packages", "tiny", "src", "tiny.ex"]),
        "defmodule Tiny do\n  # FIXED\nend\n"
      )

      File.mkdir_p!(Path.join([root, "packages", "tiny", "spec"]))

      File.write!(
        Path.join([root, "packages", "tiny", "spec", "tiny_spec.exs"]),
        "# the verifier\n"
      )

      git(["add", "-A"], root)
      git(["commit", "-qm", "the fix, with its spec"], root)

      # Untracked, as a project's own settings may be in a fixture.
      Fixture.write_project(root, %{"version" => 1, "layout" => @packages})
      previous = Noetic.Harness.put_root(root)

      on_exit(fn -> File.rm_rf(root) end)

      on_exit(fn ->
        if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
      end)

      %{root: root}
    end

    test "an environment is derived from its apps, its source and its tests", %{root: root} do
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)

      assert {:ok, environment} = Environments.derive(String.trim(sha))

      assert environment["verifier"]["app"] == "tiny"
      assert environment["verifier"]["files"] == ["spec/tiny_spec.exs"]
      assert environment["verifier"]["source_paths"] == ["packages/tiny/src/tiny.ex"]
    end

    test "its tests run by its own command, in its app's directory", %{root: root} do
      assert {"ran spec/tiny_spec.exs\n", 0} =
               Tree.run_tests("tiny", ["spec/tiny_spec.exs"], root)
    end
  end

  describe "a repository with no layout" do
    test "is told so: nothing derived, nothing run, nothing seeded" do
      Fixture.with_tree(Fixture.minimal(), fn root ->
        assert Project.layout() == nil
        assert Tree.run_tests("tiny", ["test/x_test.exs"], root) == {Project.no_layout(), 1}
        assert Environments.derivable() == []
        assert Tree.seeded() == ["/deps"]
      end)
    end

    test "an incomplete layout is none" do
      Fixture.with_tree(Fixture.minimal(), fn root ->
        Fixture.write_project(root, %{"version" => 1, "layout" => Map.delete(@packages, "build")})
        assert Project.layout() == nil
      end)
    end
  end

  describe "the schema refuses" do
    test "a directory that is a path, a missing field, and an empty test command" do
      nested = %{"version" => 1, "layout" => Map.put(@packages, "apps", "src/packages")}
      assert Enum.any?(errors(nested), &(&1 =~ "layout.apps"))

      missing = %{"version" => 1, "layout" => Map.delete(@packages, "test_suffix")}
      assert Enum.any?(errors(missing), &(&1 =~ "missing required key test_suffix"))

      empty = %{"version" => 1, "layout" => Map.put(@packages, "test_command", [])}
      assert Enum.any?(errors(empty), &(&1 =~ "test_command"))
    end
  end
end
