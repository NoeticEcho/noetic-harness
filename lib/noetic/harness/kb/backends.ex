defmodule Noetic.Harness.KB.Backends do
  @moduledoc """
  Whether the knowledge store (Postgres) and Qdrant are there, asked with a TCP connect
  and a short timeout, so that a knowledge-base answer can say who gave it.

  ## Files answer; the stores are optional, and so far only probed

  The harness answers from `docs/kb/extraction/` because that is in every
  checkout and every VM, and a cloud VM's stores start empty until something
  loads them. The brief for an earlier change allowed ranked or semantic
  results from the stores when they are up. Neither is wired, and that is on
  purpose rather than a gap filled with a guess:

    * **Qdrant** holds vectors made by the product's own embedding function.
      A query has to be embedded by the same function, and the harness may
      not depend on the product's applications (`Noetic.Harness` moduledoc).
      Copying the
      function would be a second implementation that drifts from the first
      with nothing to notice it.
    * **the knowledge store** speaks the Postgres wire protocol, which the harness has
      no client for, and `psql` is not on every machine.

  So a store that is up is reported as up and *not queried*. A store that is
  down is reported as down. Neither changes the hits, and the answer names
  `files` as its backend either way — which is the degradation the brief asks
  for, said out loud.

  A probe is a connect to `host:port`, never a request, and it is bounded by
  `@timeout_ms`: an unroutable address answers in that time rather than the
  kernel's.

  ## a knowledge store that answers is not yet a knowledge base

  In a cloud worker the knowledge store is loaded in the background after the session
  starts, so for a minute or more Postgres answers a connect and
  holds nothing. the knowledge store's note says what `Noetic.Harness.KB.LoadMarker` reads
  from the loader's marker: still loading and at which step, loaded and when,
  or failed and why. Without a marker, which is the workstation, the note is
  what it was.
  """

  alias Noetic.Harness.KB.LoadMarker

  @timeout_ms 150

  @type status :: %{
          required(:name) => String.t(),
          required(:address) => String.t(),
          required(:up) => boolean(),
          required(:note) => String.t(),
          optional(:load) => LoadMarker.state()
        }

  @doc """
  Probe each store. `QDRANT_URL` and `DATABASE_URL` are read the way the
  product apps read them; unset, the `docker-compose.yml` ports on localhost.
  `addresses` (`postgres:` and `qdrant:`, each `{host, port}`) overrides them,
  which is how a test points a probe at a port it knows is closed without
  touching the environment every other test shares. `marker:` is the knowledge store
  load's marker file, the repository's own by default.
  """
  @spec probe(keyword()) :: [status()]
  def probe(addresses \\ []) do
    load =
      if marker = addresses[:marker], do: LoadMarker.status(marker), else: LoadMarker.status()

    [
      "postgres"
      |> probe(addresses[:postgres] || postgres_address(), "Postgres (the knowledge store)")
      |> with_load(load),
      probe("qdrant", addresses[:qdrant] || qdrant_address(), "Qdrant")
    ]
  end

  defp with_load(status, load) do
    case LoadMarker.describe(load) do
      nil ->
        status

      clause ->
        note =
          case {status.up, load.state} do
            {true, :loaded} ->
              "Postgres (the knowledge store) answers at #{status.address}, and #{clause}; " <>
                "the harness does not query it yet, so files answered"

            {true, _} ->
              "Postgres (the knowledge store) answers at #{status.address}, but #{clause}; files answered"

            {false, _} ->
              "Postgres (the knowledge store) is not reachable at #{status.address}; #{clause}; files answered"
          end

        %{status | note: note} |> Map.put(:load, load.state)
    end
  end

  defp probe(name, {host, port}, label) do
    address = "#{host}:#{port}"

    up =
      case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], @timeout_ms) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        {:error, _} ->
          false
      end

    note =
      if up,
        do:
          "#{label} answers at #{address}; the harness does not query it yet, so files answered",
        else: "#{label} is not reachable at #{address}; files answered"

    %{name: name, address: address, up: up, note: note}
  end

  @doc false
  def postgres_address do
    with url when is_binary(url) and url != "" <- System.get_env("DATABASE_URL"),
         %URI{host: host, port: port} when is_binary(host) <- URI.parse(url) do
      {host, port || 5432}
    else
      _ -> {System.get_env("PGHOST") || "localhost", env_port("PGPORT", 5432)}
    end
  end

  @doc false
  def qdrant_address do
    with url when is_binary(url) and url != "" <- System.get_env("QDRANT_URL"),
         %URI{host: host, port: port} when is_binary(host) <- URI.parse(url) do
      {host, port || 6333}
    else
      _ -> {"localhost", 6333}
    end
  end

  defp env_port(name, default) do
    case Integer.parse(System.get_env(name) || "") do
      {port, ""} -> port
      _ -> default
    end
  end
end
