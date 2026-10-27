defmodule Noetic.Harness.DispatchExport do
  @moduledoc """
  Keeps a dispatch that a test's timeout killed from failing every test after
  it.

  `Dispatcher` exports the dispatching run's id as `NOETIC_HARNESS_PARENT_RUN`
  for the length of the adapter call, so that a run the agent opens is its
  child, and restores the previous value in a `try … after`. An ExUnit timeout
  kills the test process, and `after` does not run in a killed process. The
  variable then names the killed test's run, whose file its `on_exit` deletes,
  and `Run.start/1` refuses every later run in the VM: "no run … to be
  dispatched by". On the workstation that was one 60 s stall in a
  `DispatcherTest` adapter and 116 failures, 99 of them the same module's
  `setup`. Reproduced here with an adapter that sleeps past its test's
  timeout: every later test failed in `setup` with that message.

  `on_exit` does run after a kill, so `guard/1`, as a `setup`, puts back what
  the variable held before the test. A stalled dispatch is then one failure
  with its own timeout, and the tests after it run.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @var "NOETIC_HARNESS_PARENT_RUN"

  @doc "A `setup` callback: restore the parent-run export when the test ends, however it ends."
  @spec guard(map()) :: :ok
  def guard(_context) do
    previous = System.get_env(@var)

    on_exit(fn ->
      if previous, do: System.put_env(@var, previous), else: System.delete_env(@var)
    end)

    :ok
  end
end
