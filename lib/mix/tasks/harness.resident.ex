defmodule Mix.Tasks.Harness.Resident do
  @shortdoc "The already-running harness the hook talks to instead of booting one"

  @moduledoc """
  Start, stop and inspect the resident harness server.

      noetic-harness resident --status
      noetic-harness resident --start          # detached; returns immediately
      noetic-harness resident --serve          # in the foreground, for a terminal
      noetic-harness resident --stop
      noetic-harness resident --ask user_prompt --prompt "fix the qdrant client"

  `noetic-harness hook` talks to it in nine lines of bash and spawns nothing; this
  task is for a person. `SessionStart` starts a server through the hook, by
  the same rule as `--start`: one answering a ping is left alone, and an
  address nothing answers is removed before a new one starts.

  **It is an optimisation over the cold path, never a replacement for it.**
  Every failure here — no server, a stale one, a slow one — leaves the hook
  doing exactly what it did before. `Noetic.Harness.Resident` is where the
  staleness, lifecycle and fallback arguments are written down.

  ## `--start` is not the same as `--serve`

  `--serve` runs the accept loop in this process and does not return, which is
  what you want in a terminal where you can see it. `--start` spawns a detached
  BEAM that survives this shell and returns as soon as the server answers a
  ping — it waits for the ping rather than sleeping a fixed time, because a
  `SessionStart` hook that returns before the port is open has started nothing
  from the next prompt's point of view.

  A `--start` that finds a live server on the recorded address exits quietly
  and starts nothing: more than one session shares this working directory, and
  every one of them fires `SessionStart`.
  """

  use Mix.Task

  alias Noetic.Harness.Resident

  @requirements ["app.config"]

  # How long `--start` waits for the child to answer a ping before giving up on
  # it. Generous against the boot it is waiting for (~900 ms here) and bounded,
  # because `SessionStart` is on the session's critical path.
  @start_timeout_ms 10_000
  @poll_ms 100

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          start: :boolean,
          serve: :boolean,
          stop: :boolean,
          status: :boolean,
          json: :boolean,
          ask: :string,
          prompt: :string,
          idle_ms: :integer
        ]
      )

    shell = Mix.shell()

    cond do
      opts[:serve] -> serve(shell, opts)
      opts[:start] -> start(shell, opts)
      opts[:stop] -> stop(shell)
      opts[:ask] -> ask(shell, opts)
      true -> status(shell, opts)
    end
  end

  defp serve(shell, opts) do
    case Resident.serve(idle_ms: opts[:idle_ms] || Resident.idle_ms()) do
      :stale -> shell.info("the beams changed underneath it; exiting rather than answering stale")
      :idle -> shell.info("nothing asked anything for the idle budget; exiting")
      :stopped -> shell.info("stopped")
      {:error, reason} -> shell.error("could not listen: #{inspect(reason)}")
    end
  end

  defp start(shell, opts) do
    if Resident.alive?() do
      shell.info("a resident harness is already answering on this address")
    else
      # It was not answering, so whatever the file says is about a server that
      # is gone. Leaving it would make the next client wait for a connect that
      # can only be refused.
      Resident.forget()
      spawn_detached(opts)

      case await(@start_timeout_ms) do
        :ok ->
          shell.info("resident harness started")

        :error ->
          shell.error(
            "the resident harness did not answer within #{div(@start_timeout_ms, 1000)}s. " <>
              "The hook falls back to the cold path, so nothing is broken; " <>
              "`noetic-harness resident --serve` in a terminal shows why."
          )

          exit({:shutdown, 1})
      end
    end
  end

  # `elixir -pa <ebin>` rather than `mix`, for the reason `noetic-harness hook`
  # gives: booting mix costs more than the server saves, and a detached process
  # that holds a mix build lock is a process that blocks the next compile.
  defp spawn_detached(opts) do
    idle = opts[:idle_ms] || Resident.idle_ms()

    # The root travels in the environment, not in the script: a subprocess
    # cannot read this process's dictionary, and `NOETIC_HARNESS_ROOT` is
    # already the per-subprocess override the rest of the harness uses.
    script = "Noetic.Harness.Resident.serve(idle_ms: #{idle})"

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :hide,
        :exit_status,
        args: ["--erl", "-detached", "-pa", Resident.ebin(), "-e", script],
        env: [{~c"NOETIC_HARNESS_ROOT", String.to_charlist(Noetic.Harness.root())}]
      ])

    # `elixir --erl -detached` returns as soon as it has forked, so this is
    # the launcher exiting and not the server.
    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      @start_timeout_ms -> :ok
    end
  end

  defp await(remaining) when remaining <= 0, do: :error

  defp await(remaining) do
    if Resident.alive?() do
      :ok
    else
      Process.sleep(@poll_ms)
      await(remaining - @poll_ms)
    end
  end

  defp stop(shell) do
    case Resident.ask("stop", %{}, 2_000) do
      {:ok, _} ->
        Resident.forget()
        shell.info("resident harness stopped")

      {:error, _reason} ->
        Resident.forget()
        shell.info("no resident harness was answering; removed the address file")
    end
  end

  defp ask(shell, opts) do
    payload = if opts[:prompt], do: %{"prompt" => opts[:prompt]}, else: %{}

    case Resident.ask(opts[:ask], payload) do
      {:ok, answer} ->
        shell.info(answer)

      {:error, reason} ->
        shell.error("no answer: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp status(shell, opts) do
    state = Resident.status()

    if opts[:json] do
      shell.info(JSON.encode!(state))
    else
      cond do
        state["alive"] == true and state["stale"] == true ->
          shell.info("""
          resident harness: answering on port #{state["port"]}, and STALE.

          The beams have changed since it booted, so it will refuse the next
          request and exit rather than answer off old code. The hook falls back
          to the cold path meanwhile, and the next `SessionStart` starts a fresh
          one — or `noetic-harness resident --stop && noetic-harness resident --start`.
          """)

        state["alive"] == true ->
          shell.info(
            "resident harness: answering on port #{state["port"]} since #{state["started_at"]} " <>
              "(os pid #{state["os_pid"]}, #{state["fingerprint"]["count"]} beams)"
          )

        true ->
          shell.info(
            "resident harness: not running#{if state["error"], do: " — " <> state["error"], else: ""}.\n" <>
              "The hook is on the cold path, which is ~1.0 s of BEAM boot per event.\n" <>
              "`noetic-harness resident --start` starts one."
          )
      end
    end
  end
end
