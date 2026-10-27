defmodule Noetic.Harness.RunTaskTest do
  @moduledoc """
  What `noetic-harness run --start` says.

  A worker read its output through `| head -1` and later `| tail -3`, and
  neither showed which run it had opened, so a start that opened nothing
  looked the same as one that did. The last line names the run; a start
  that opens none exits non-zero.
  """

  # async: false: moves the harness root, and the Mix shell is global.
  use ExUnit.Case, async: false

  # An `.agents/` on the pack whose `runs/` is empty, as `RunTest` does it:
  # `start` needs workflows, and the pack's are enough (`Noetic.Harness.Pack`).
  setup do
    root =
      Path.join(System.tmp_dir!(), "harness-run-task-#{System.os_time(:microsecond)}")
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

  defp infos(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> infos([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "the last line names the run it opened, and that run is on disk", %{root: root} do
    Mix.Tasks.Harness.Run.run(~w(--start WF-003 --title run-task-test --agent test))

    last = List.last(infos())
    assert "opened " <> id = last
    assert File.exists?(Path.join([root, ".agents", "runs", id <> ".json"]))
  end

  test "a start that opens no run exits non-zero and names no run", %{root: root} do
    assert catch_exit(Mix.Tasks.Harness.Run.run(~w(--start WF-999 --title nothing))) ==
             {:shutdown, 1}

    refute Enum.any?(infos(), &String.starts_with?(&1, "opened "))
    assert File.ls!(Path.join([root, ".agents", "runs"])) == []
  end
end
