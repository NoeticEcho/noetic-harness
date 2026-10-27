defmodule Noetic.Harness.KB.LoadMarker do
  @moduledoc """
  Whether `docs/kb` has been loaded into the knowledge store, as the marker that
  `bin/worker-session-start` keeps says.

  A cloud worker's Postgres starts empty. `bin/worker-session-start` loads the
  knowledge base into it in the background, which takes a minute or more after
  the build and Postgres are up, and keeps a JSON marker at
  `.agents/telemetry/worker-session-start.kb.json` while it does:

    * `"state":"loading"`, with `step`, `started_at` and the job's `pid`;
    * `"state":"failed"`, with `reason`;
    * `"state":"loaded"`, with `finished_at`, `load_seconds`, `counts` and
      `stores`, written by `mix kb.load --marker` itself.

  `noetic-harness kb` answers from the files whatever this says. What changes is
  what it says about the knowledge store: a knowledge store that answers a TCP connect while the
  load is half done is not a knowledge base, and "Postgres answers" was the
  only thing the answer could say about it before. `Noetic.Harness.KB.Backends`
  puts `describe/1` into the knowledge store's note.

  ## A marker that says "loading" for a job that is gone

  The job writes its own pid. A marker that says `loading` for a pid that
  `/proc` does not have is `:stopped`: the job died without writing `failed`,
  which a `kill -9`, a VM restart or an out-of-memory kill does. Where there is
  no `/proc` at all the pid cannot be judged, and the marker is believed.

  On the workstation there is no marker, so `status/1` is `:absent` and the
  notes read as they did before.
  """

  @path ".agents/telemetry/worker-session-start.kb.json"

  @type state :: :absent | :loading | :loaded | :failed | :stopped | :unreadable
  @type t :: %{
          required(:state) => state(),
          optional(:step) => String.t(),
          optional(:reason) => String.t(),
          optional(:since) => String.t(),
          optional(:finished_at) => String.t(),
          optional(:records) => non_neg_integer(),
          optional(:pid) => pos_integer()
        }

  @doc "Where the marker is, relative to the repository root."
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  What the marker at `file` says. `file` defaults to the repository's own.
  """
  @spec status(Path.t()) :: t()
  def status(file \\ Path.join(Noetic.Harness.root(), @path)) do
    case File.read(file) do
      {:error, _} ->
        %{state: :absent}

      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, %{"state" => state} = marker} -> read(state, marker)
          _ -> %{state: :unreadable}
        end
    end
  end

  defp read("loading", marker) do
    pid = marker["pid"]
    state = if gone?(pid), do: :stopped, else: :loading

    %{state: state, step: str(marker["step"]), since: str(marker["started_at"])}
    |> put_if(:pid, if(is_integer(pid), do: pid))
  end

  defp read("failed", marker),
    do: %{state: :failed, reason: str(marker["reason"]), since: str(marker["started_at"])}

  # `sourcings` are TypeDB's edges from a record to its documents, not rows of
  # the knowledge store, so they are not counted as its records.
  defp read("loaded", marker) do
    records =
      case marker["counts"] do
        %{} = counts ->
          counts
          |> Map.delete("sourcings")
          |> Map.values()
          |> Enum.filter(&is_integer/1)
          |> Enum.sum()

        _ ->
          0
      end

    %{state: :loaded, finished_at: str(marker["finished_at"]), records: records}
  end

  defp read(_state, _marker), do: %{state: :unreadable}

  # Linux's /proc, and only there: without it a pid cannot be judged.
  defp gone?(pid) when is_integer(pid) and pid > 0,
    do: File.dir?("/proc/self") and not File.dir?("/proc/#{pid}")

  defp gone?(_pid), do: false

  defp str(value) when is_binary(value), do: value
  defp str(_), do: ""

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @doc """
  One clause about the load for the knowledge store's note, or `nil` when there is no
  marker to speak of.

      iex> Noetic.Harness.KB.LoadMarker.describe(%{state: :absent})
      nil

      iex> Noetic.Harness.KB.LoadMarker.describe(%{state: :loading, step: "waiting for Postgres at localhost:5432", since: "2026-09-25T13:40:00Z"})
      "docs/kb is still loading into it (waiting for Postgres at localhost:5432, since 2026-09-25T13:40:00Z)"
  """
  @spec describe(t()) :: String.t() | nil
  def describe(%{state: :absent}), do: nil

  def describe(%{state: :loading} = load),
    do: "#{kb()} is still loading into it (#{load.step}, since #{load.since})"

  def describe(%{state: :loaded} = load),
    do: "#{kb()} was loaded into it at #{load.finished_at} (#{load.records} records)"

  def describe(%{state: :failed} = load),
    do: "the load of #{kb()} into it failed: #{load.reason}"

  def describe(%{state: :stopped} = load) do
    "the load of #{kb()} into it stopped without saying why (#{load.step}; " <>
      "pid #{load[:pid]} is gone): see .agents/telemetry/worker-session-start.log"
  end

  def describe(%{state: :unreadable}),
    do: "#{@path} could not be read, so whether #{kb()} is in it is unknown"

  # The project's knowledge base by its directory (`kb.root`), as the
  # messages have always named it, or in words where the project names none.
  defp kb, do: Noetic.Harness.Project.kb("root") || "the knowledge base"
end
