defmodule Noetic.Harness.RootTest do
  # `async: true`, and that is the whole claim: this file repoints the harness
  # root in every test and no other test in the VM can tell.
  use ExUnit.Case, async: true

  describe "the root override" do
    test "is scoped to the process that set it" do
      # The property an earlier change exists for. With `NOETIC_HARNESS_ROOT` this
      # was impossible: a test that pointed the harness at a fixture pointed
      # *every concurrently running test* at it, and when it finished and
      # deleted the tree, whatever they were reading went with it. An
      # independent review measured the cost — three of five full suite runs
      # failed, one of them reporting `SecurityTest`'s "an untrusted role
      # cannot escalate by naming a higher trust" as "could not read file
      # /tmp/usage-runs-611/.agents/skills/elixir-idioms/SKILL.md".
      real = Noetic.Harness.root()
      mine = Noetic.Harness.TestTmp.path("root")

      Noetic.Harness.put_root(mine)

      assert Noetic.Harness.root() == Path.expand(mine)

      # A process that is not this one, and is not a task of this one, still
      # sees the repository. That is the isolation, stated as a test rather
      # than as a comment.
      parent = self()

      spawn(fn -> send(parent, {:root_over_there, Noetic.Harness.root()}) end)

      assert_receive {:root_over_there, ^real}, 5_000

      Noetic.Harness.delete_root()
      assert Noetic.Harness.root() == real
    end

    test "reaches the tasks the setter spawns" do
      # Without the `$callers` walk this would fail, and the override would be
      # useless for any code that does its work in a `Task` — which is most of
      # what a test drives. It is the same mechanism Ecto's SQL sandbox uses,
      # for the same reason.
      mine = Noetic.Harness.TestTmp.path("root")
      Noetic.Harness.put_root(mine)

      inner = Task.async(fn -> Noetic.Harness.root() end)
      assert Task.await(inner) == Path.expand(mine)

      nested = Task.async(fn -> Task.await(Task.async(fn -> Noetic.Harness.root() end)) end)
      assert Task.await(nested) == Path.expand(mine)
    end

    test "put_root returns what it displaced, so a caller can restore it" do
      first = Noetic.Harness.TestTmp.path("root-a")
      second = Noetic.Harness.TestTmp.path("root-b")

      assert Noetic.Harness.put_root(first) == nil
      assert Noetic.Harness.put_root(second) == Path.expand(first)
      assert Noetic.Harness.root_override() == Path.expand(second)

      assert Noetic.Harness.delete_root() == Path.expand(second)
      assert Noetic.Harness.root_override() == nil
    end

    test "the process wins over the environment variable" do
      # Precedence is load-bearing and is not testable inside this VM without
      # doing the thing this change removes: a developer who has exported
      # `NOETIC_HARNESS_ROOT` would, if the order were the other way round,
      # silently lose every per-test override and get the flakiness back with
      # no symptom. A calibration that swapped the two left the whole suite
      # green, which is how this test came to exist.
      #
      # So it is asserted in a subprocess that has both.
      from_env = Path.expand(Path.join(System.tmp_dir!(), "env-root"))
      from_process = Path.expand(Path.join(System.tmp_dir!(), "process-root"))

      {output, 0} =
        System.cmd(
          System.find_executable("elixir"),
          [
            "-pa",
            ebin(),
            "-e",
            ~s|Noetic.Harness.put_root("#{from_process}"); IO.write(Noetic.Harness.root())|
          ],
          env: [{"NOETIC_HARNESS_ROOT", from_env}],
          stderr_to_stdout: true
        )

      assert output == from_process,
             "with both set, the root resolved #{inspect(output)} — the environment variable " <>
               "is winning, so a machine that exports it has no per-test isolation at all"
    end

    test "the environment variable still works, and has to" do
      # The variable is not deprecated and must not be: a *subprocess* cannot
      # read this process's dictionary, so `noetic-harness hook` and every
      # `System.cmd/3` in the suite still need it. Passing it per-command
      # through `:env` is already per-subprocess and was never the problem.
      #
      # Asserted through `System.cmd/3` rather than `System.put_env/2`,
      # because setting it here would be exactly the VM-global write this
      # whole change exists to remove — and this file is `async: true`.
      root = Path.expand(Path.join(System.tmp_dir!(), "env-root"))

      {output, 0} =
        System.cmd(
          System.find_executable("elixir"),
          [
            "-pa",
            ebin(),
            "-e",
            "IO.write(Noetic.Harness.root())"
          ],
          env: [{"NOETIC_HARNESS_ROOT", root}],
          stderr_to_stdout: true
        )

      assert output == root,
             "a subprocess given NOETIC_HARNESS_ROOT resolved #{inspect(output)} instead"
    end
  end

  # The engine's own beams, wherever this build put them: not a path under the
  # harness root, which a test may have moved.
  defp ebin, do: Noetic.Harness |> :code.which() |> List.to_string() |> Path.dirname()
end
