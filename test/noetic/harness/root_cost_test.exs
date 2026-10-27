defmodule Noetic.Harness.RootCostTest do
  @moduledoc """
  What `Noetic.Harness.root/0` costs. Composing the 271 prompts calls it 9,324
  times, so its price per call is paid thousands of times a suite.

  Two costs made `PromptTest` and `ValidationTest` time out at 60 s inside a
  full suite on the 2-core workstation. Alone, they passed in a few seconds.

  1. The `$callers` walk read each caller's *whole* process dictionary. The
     loader and prompt caches keep parsed files there, so a process that has
     loaded the registry holds megabytes. Measured in a `Task` started by
     such a process, each `root/0` cost 2.8 ms instead of 0.19 ms. A compose
     of every prompt then took 26 s, where it takes 4.5 s in the test process
     itself.
  2. Rediscovering the root on every call cost four file-server round trips:
     `File.cwd!/0`, then one `File.dir?/1` per level walked up. Every async
     test's file I/O queues behind the same server.
  3. After the memo, one round trip was left: the `File.cwd!/0` that keys it.
     Under load that single call still queued long enough to time
     `ValidationTest` out twice on 2026-09-24, so the cwd is now read
     from `:prim_file` and a warm call makes no file-server request.

  """
  # async: false: both tests trace, one a BIF (erlang:process_info/2) and one
  # the file server and a private function, and trace settings are global to the VM. A concurrent test
  # would add its own calls to the counts.
  use ExUnit.Case, async: false

  @spec_mfa {:erlang, :process_info, 2}

  test "a task reads one key of its callers' dictionaries, never the whole of them" do
    task = Task.async(fn -> receive(do: (:go -> Noetic.Harness.root())) end)

    :erlang.trace_pattern(@spec_mfa, true, [:global])
    :erlang.trace(task.pid, true, [:call])

    try do
      send(task.pid, :go)
      assert Task.await(task) == Noetic.Harness.root()
      delivered(task.pid)
    after
      :erlang.trace_pattern(@spec_mfa, false, [:global])
    end

    specs = for {:trace, _, :call, {:erlang, :process_info, [_, spec]}} <- drain(), do: spec

    refute :dictionary in specs,
           "root/0 copied a caller's whole process dictionary. The loader and prompt " <>
             "caches live there, so that is megabytes per call"

    assert Enum.any?(specs, &match?({:dictionary, _}, &1)),
           "the task never looked at its caller's dictionary, so this test proved nothing: " <>
             inspect(specs)
  end

  test "once warm, root/0 makes no file-server request at all" do
    fs = Process.whereis(:file_server_2)
    discovery = {Noetic.Harness, :discover_root, 0}

    # A task of its own, warmed first, so the trace sees only its ten calls:
    # a process is not reliably its own tracer.
    task =
      Task.async(fn ->
        _warm = Noetic.Harness.root()
        receive(do: (:go -> for(_ <- 1..10, do: Noetic.Harness.root())))
      end)

    :erlang.trace_pattern(discovery, true, [:local])
    :erlang.trace(fs, true, [:receive])
    :erlang.trace(task.pid, true, [:call])

    try do
      send(task.pid, :go)
      Task.await(task)
      delivered(fs)
    after
      :erlang.trace(fs, false, [:receive])
      :erlang.trace_pattern(discovery, false, [:local])
    end

    messages = drain()
    pid = task.pid

    mine =
      for {:trace, ^fs, :receive, {:"$gen_call", {^pid, _}, request}} <- messages,
          do: elem(request, 0)

    discoveries =
      for {:trace, ^pid, :call, {Noetic.Harness, :discover_root, []}} <- messages, do: 1

    # Discovery runs only when neither a process override nor
    # NOETIC_HARNESS_ROOT is set. With either, discovery never runs and an
    # empty request list would pass having proved nothing.
    assert length(discoveries) >= 10,
           "root/0 reached discovery #{length(discoveries)} times in ten calls " <>
             "(is NOETIC_HARNESS_ROOT set?), so this test proved nothing"

    # The cwd used to be read with File.cwd!/0, a file-server call, and under a
    # full suite's file IO that queue is what timed ValidationTest out.
    assert mine == [],
           "ten warm root/0 calls made #{length(mine)} file-server requests: " <>
             inspect(Enum.frequencies(mine))
  end

  defp delivered(pid) do
    ref = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^ref}, 5_000
  end

  defp drain(acc \\ []) do
    receive do
      {:trace, _, _, _} = message -> drain([message | acc])
      {:trace, _, _, _, _} = message -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
