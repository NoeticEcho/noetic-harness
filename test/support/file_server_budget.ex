defmodule Noetic.Harness.FileServerBudget do
  @moduledoc """
  A test's time budget stated as what the test does, for the tests whose time
  is file-server round trips.

  ## Why a count, not a clock

  `File.read/1`, `File.write/2`, `File.ls/1`, `File.cwd/0` and `Path.wildcard/1`
  are each a `gen_server` call to OTP's one file server, `file_server_2`, unless
  the call says `:raw`. Idle, a call answers in ~0.05 ms and nobody notices.
  Under load it is the wait: a probe in a harness suite run beside `stress-ng`
  on two cores (load 16-21) measured a round trip at 25-60 ms median with three
  or four callers queued. So a test that makes 5,000 of them takes a quarter of
  a second on a quiet machine and three minutes on a busy one, and ExUnit's
  default 60 s was a statement about neither.

  The number of calls does not depend on the machine. So a test that cannot
  shed its calls states them instead:

    * `calls/1` counts the file-server calls a function makes, in the calling
      process and every process it spawns;
    * the test asserts the count is under a ceiling, which fails the same way on
      every machine when the I/O grows, and says so;
    * `timeout/1` turns that ceiling into the test's ExUnit timeout at
      `allowance_ms/0` a call, which is what it was measured to cost under load.

  A test whose calls *can* be shed should shed them instead: this is for the
  ones whose I/O is in code the test does not own.
  """

  # `ValidationTest`'s checks ran at 36 ms a call averaged over their ~5,000
  # calls (182 s at load 15-21 on two cores of this VM, 2026-09-25), and single
  # round trips measured 25-60 ms median and ~140 ms at p95. The workstation's
  # cores are slower than these. A timeout is there to catch a hang, which any
  # finite budget does, so the allowance only has to sit above what a call
  # costs on the slowest machine that runs the suite: 100 ms, near three times
  # the measured average.
  @allowance_ms 100

  @doc "Milliseconds a file-server call is allowed under load. See the moduledoc."
  @spec allowance_ms() :: pos_integer()
  def allowance_ms, do: @allowance_ms

  @doc "An ExUnit timeout for a test that makes at most `calls` file-server calls."
  @spec timeout(pos_integer()) :: pos_integer()
  def timeout(calls), do: max(60_000, calls * @allowance_ms)

  @doc """
  Run `fun` and count the calls it made to the file server. Returns
  `{result, calls}`.

  Counted from the sending side, with `:set_on_spawn`, so an async test counts
  its own calls and not those of the tests running beside it, and a `Task` the
  function starts is counted with it. A process the function only *messages*
  (a server that does I/O on its behalf) is not counted.
  """
  @spec calls((-> result)) :: {result, non_neg_integer()} when result: term()
  def calls(fun) do
    server = Process.whereis(:file_server_2)
    parent = self()

    tracer =
      spawn(fn ->
        receive do
          :go -> count(server, parent, 0)
        end
      end)

    :erlang.trace(self(), true, [:send, :set_on_spawn, {:tracer, tracer}])
    send(tracer, :go)

    result =
      try do
        fun.()
      after
        :erlang.trace(self(), false, [:send, :set_on_spawn])
      end

    # The marker is sent after tracing is off, so every call this process made
    # is ahead of it in the tracer's mailbox. A spawned process's trace
    # messages carry no such ordering, and one still in flight is not counted:
    # the count can be low by the calls of a child that outlived `fun`, never
    # high.
    ref = make_ref()
    send(tracer, {:done, ref})

    receive do
      {^ref, calls} -> {result, calls}
    end
  end

  defp count(server, parent, n) do
    receive do
      {:trace, _pid, :send, {:"$gen_call", _from, _request}, ^server} ->
        count(server, parent, n + 1)

      {:trace, _pid, :send, _message, _to} ->
        count(server, parent, n)

      {:done, ref} ->
        send(parent, {ref, n})
    end
  end
end
