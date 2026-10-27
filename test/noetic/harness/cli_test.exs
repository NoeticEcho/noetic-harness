defmodule Noetic.Harness.CLITest do
  @moduledoc """
  `Noetic.Harness.CLI`, the single executable's entry point.

  The executable itself is built and run by `CutTest`, in the public tree and
  with no Elixir on the path. This is the dispatch, run in the suite: every
  harness task is a subcommand, a command's status is what its task said,
  and loading the application outside Burrito runs nothing.
  """

  # async: false: moves the harness root, and the Mix shell is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Noetic.Harness.CLI

  setup do
    root =
      Path.join(System.tmp_dir!(), "harness-cli-#{System.os_time(:microsecond)}")
      |> Noetic.Harness.Pack.populate()

    previous = Noetic.Harness.root_override()
    Noetic.Harness.put_root(root)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp said(kind, acc \\ []) do
    receive do
      {:mix_shell, ^kind, [line]} -> said(kind, [line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  test "every harness task is a subcommand, and nothing else is" do
    tasks =
      for module <- Application.spec(:noetic_harness, :modules),
          ["Mix", "Tasks", "Harness", _] <- [Module.split(module)],
          do: module

    assert tasks != []
    assert Enum.sort(Map.values(CLI.commands())) == Enum.sort(tasks)

    for name <- ~w(init validate route gates run sync) do
      assert CLI.commands()[name] == Mix.Task.get("harness." <> name), name
    end
  end

  test "no subcommand is the usage, listing each one, and succeeds" do
    out = capture_io(fn -> assert CLI.main([]) == 0 end)
    assert out =~ "noetic-harness <subcommand> [args...]"

    for name <- Map.keys(CLI.commands()) do
      assert out =~ ~r/^  #{Regex.escape(name)}\b/m, name
    end

    assert capture_io(fn -> assert CLI.main(["--help"]) == 0 end) == out
  end

  test "--version names the application's version" do
    out = capture_io(fn -> assert CLI.main(["--version"]) == 0 end)
    assert out == "noetic-harness #{Application.spec(:noetic_harness, :vsn)}\n"
  end

  test "an unknown subcommand fails, names itself, and prints the usage on standard error" do
    err = capture_io(:stderr, fn -> assert CLI.main(["frob"]) == 1 end)
    assert err =~ ~s(no subcommand "frob")
    assert err =~ "noetic-harness <subcommand>"
  end

  test "a subcommand runs its task with the rest of argv: init, validate, route" do
    fresh = Path.join(System.tmp_dir!(), "harness-cli-init-#{System.os_time(:microsecond)}")
    File.mkdir_p!(fresh)
    on_exit(fn -> File.rm_rf!(fresh) end)

    assert CLI.main(["init", "--path", fresh]) == 0
    assert said(:info) =~ "the starter pack"
    assert File.dir?(Path.join(fresh, ".agents"))

    Noetic.Harness.put_root(fresh)
    status = CLI.main(["validate"])
    assert status == 0, said(:error)
    assert said(:info) =~ "harness definitions are consistent"

    assert CLI.main(["route", "--title", "fix the parser's handling of empty input"]) == 0
    assert said(:info) =~ "workflow"
  end

  test "a task's exit({:shutdown, n}) is status n" do
    empty = Path.join(System.tmp_dir!(), "harness-cli-empty-#{System.os_time(:microsecond)}")
    File.mkdir_p!(Path.join(empty, ".agents"))
    on_exit(fn -> File.rm_rf!(empty) end)
    Noetic.Harness.put_root(empty)

    assert CLI.main(["validate"]) == 1
    assert said(:error) =~ "not found"
  end

  test "Mix.raise/1 is status 1 and mix's own line on standard error" do
    err = capture_io(:stderr, fn -> assert CLI.main(["route"]) == 1 end)
    assert err =~ ~r/^\*\* \(Mix\) give me something to route/
  end

  test "outside Burrito, starting the application runs no command" do
    assert System.get_env("__BURRITO") == nil

    output =
      capture_io(fn ->
        assert {:ok, pid} = CLI.start(:normal, [])
        assert Supervisor.which_children(pid) == []
        Supervisor.stop(pid)
      end)

    assert output == ""
  end
end
