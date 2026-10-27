defmodule Noetic.Harness.Resident.Ready do
  @moduledoc """
  The one piece of data the resident server holds: the last ready-work list,
  with the time it was fetched.

  `Noetic.Harness.Resident` says it holds **no data** — every request is served
  in a fresh process, so every definition file is re-read and nothing can go
  stale. This module is the exception, and it is an exception on purpose, so
  the argument is written here rather than left for someone to discover.

  ## Why the ready list, and why this shape

  `session_start` spent 3899 of its 3920 ms in `Beads.ready/1`: `bd` opening a
  Dolt database. The resident server cannot remove that, because the resident
  shells out to the same `bd`.

  A cache would remove it, and the question a cache must answer is *when is it
  wrong*. There is no cheap answer here, and that was measured rather than
  assumed:

  - Dolt's storage files move on a **read** — opening the database touches
    them — so their mtimes cannot tell a write from a `bd ready`.
  - `.beads/issues.jsonl` does not move on a write: `bd` throttles auto-export
    to an interval, so the export can lag the database by minutes.

  Every correct answer therefore needs a Dolt open, and "is my cache current"
  costs exactly what the cache was meant to save. So this is not a cache with
  invalidation. It is **stale-while-revalidate, disclosed**: the last list is
  served at once, stamped with its age, and a refresh starts in the background
  for the next `session_start`. The stamp is the whole of the honesty — a reader
  told "as of 4 min ago" knows what they were given, and the block already
  tells them to run `bd ready` themselves.

  Past `max_age_ms` nothing is served from here: the caller makes the live call
  as it always did. The default is the resident's own idle budget, so the
  oldest list this can ever serve is one taken while somebody was still
  working.

  ## What it never caches

  Only `{:ok, _}`. A `:timeout` is a Dolt lock held by another session, and the
  useful thing to say about it is that it is happening *now*; a cached one
  would report a lock that has since been released.
  """

  use GenServer

  @default_max_age_ms 30 * 60 * 1000

  @typedoc "What `Noetic.Harness.Beads.ready/2` returns."
  @type result :: {:ok, String.t()} | :timeout | :error | :off

  @doc """
  Start a cache. `:fetch` is the zero-arity function that produces a fresh
  result — `Beads.ready(6)` in the resident, a fixture in a test, because a
  test that shells out to `bd` is a test of this repository's tracker.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  The ready list to show, and where it came from.

    * `{:cached, result, age_ms}` — the last list, and a background refresh has
      been started for next time
    * `{:live, result}` — there was nothing fresh enough, so this is a live
      call, made in the caller's process and stored for next time

  The live call runs in the **caller**, not in this server, so a slow `bd`
  holds up the one request that needed it and not every later `take/1`.
  """
  @spec answer(pid()) :: {:cached, result(), non_neg_integer()} | {:live, result()}
  def answer(cache) do
    case GenServer.call(cache, :lookup) do
      {:cached, result, age_ms} ->
        refresh(cache)
        {:cached, result, age_ms}

      {:none, fetch} ->
        result = fetch.()
        put(cache, result)
        {:live, result}
    end
  end

  @doc """
  Store a result. Anything but `{:ok, _}` is ignored — see the moduledoc.

  Synchronous, and that is a correctness property rather than a preference. The
  stamp is taken when the server stores the list, so a `cast` stamped it
  whenever the server got round to it — after the caller had already moved on,
  and possibly after time had. The age then under-reported how old the list
  was, which is the one number this module exists to report honestly. The
  test that pins the age caught it: 4 min of clock movement read back as 0.
  """
  @spec put(pid(), result()) :: :ok
  def put(cache, result), do: GenServer.call(cache, {:put, result})

  @doc """
  Fetch a fresh list in the background. A no-op while one is already in
  flight, so two sessions starting together cost one `bd`, not two.
  """
  @spec refresh(pid()) :: :ok
  def refresh(cache), do: GenServer.cast(cache, :refresh)

  @doc "The default for `:max_age_ms`: the resident's idle budget."
  @spec default_max_age_ms() :: pos_integer()
  def default_max_age_ms, do: @default_max_age_ms

  # ---- server --------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       fetch: Keyword.fetch!(opts, :fetch),
       max_age_ms: Keyword.get(opts, :max_age_ms, @default_max_age_ms),
       now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
       result: nil,
       at: nil,
       refreshing: false
     }}
  end

  @impl GenServer
  def handle_call(:lookup, _from, state) do
    reply =
      case state do
        %{result: {:ok, _} = result, at: at} when is_integer(at) ->
          age = state.now.() - at
          if age <= state.max_age_ms, do: {:cached, result, age}, else: {:none, state.fetch}

        _nothing_usable ->
          {:none, state.fetch}
      end

    {:reply, reply, state}
  end

  def handle_call({:put, {:ok, _} = result}, _from, state) do
    {:reply, :ok, %{state | result: result, at: state.now.()}}
  end

  def handle_call({:put, _not_ok}, _from, state), do: {:reply, :ok, state}

  @impl GenServer

  def handle_cast(:refresh, %{refreshing: true} = state), do: {:noreply, state}

  def handle_cast(:refresh, state) do
    server = self()
    fetch = state.fetch

    # Unlinked on purpose: a `bd` that crashes the task must not take the
    # cache with it, and the cache must not take down the resident.
    Task.start(fn -> GenServer.cast(server, {:refreshed, safely(fetch)}) end)

    {:noreply, %{state | refreshing: true}}
  end

  def handle_cast({:refreshed, result}, state) do
    state = %{state | refreshing: false}

    case result do
      {:ok, _} -> {:noreply, %{state | result: result, at: state.now.()}}
      _kept_what_we_had -> {:noreply, state}
    end
  end

  defp safely(fetch) do
    fetch.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
