defmodule Noetic.Harness.Resident do
  @moduledoc """
  A harness that is already running, so the hook does not boot a BEAM per prompt.

  An earlier change measured `noetic-harness hook` and the attribution
  killed two of the three options it proposed. What is left is the floor, and
  the floor is the boot:

  | what | ms on this machine |
  |---|---|
  | `erl -noshell -eval 'halt(0).'` | 450 |
  | `elixir -e ':ok'` | 710 |
  | `elixir -pa <ebin> -e ':ok'` | 906 |
  | the whole hook script | 1040 |
  | `Attach.hook_json/2` **warm, in a live BEAM** | **32** |

  A route cache saves the 32. An escript still boots a BEAM. Only a process
  that is already up removes the 906, and only a client that needs no `elixir`
  removes the ~330 ms `noetic-harness hook` spends sourcing `scripts/lib/toolchain.sh`
  before it can find one.

  ## The three questions the bead said this had to answer

  **Staleness — a server holding an old registry answers confidently and
  wrongly, which is worse than being slow.** Half of this is free and the free
  half is the important half: `Noetic.Harness.Loader.cached_load/1` caches in
  the **process dictionary**, so a request served in a *fresh process* re-reads
  every definition file. Data staleness cannot happen here by construction
  rather than by a watcher somebody has to keep correct — which is why every
  request gets its own process even though nothing about the concurrency
  requires it.

  **One exception, and it is disclosed:** the ready-work list `session_start`
  shows. `Noetic.Harness.Resident.Ready` holds the last one and serves it
  stamped with its age, because that list costs a Dolt open and nothing cheap
  can say whether it changed. Its moduledoc has the measurements.

  What is left is **code** staleness: the beams this server loaded at boot. It
  fingerprints `<ebin>/*.beam` — count, newest mtime, total size — and compares
  before every answer. On a change it answers nothing, removes its address file
  and **exits**, so the client falls back to the cold path and the next
  `SessionStart` starts a server on the new code. It does not hot-reload: a
  module reloaded while a module it was compiled against did not change is
  exactly the confident wrong answer this check exists to prevent.

  **Lifecycle — started by `SessionStart`, and reaped when.** Started detached
  by `noetic-harness hook` once `SessionStart` has been answered, or by
  `noetic-harness resident --start`. A server answering on the address file is
  the lock: a start that finds one answering a ping starts nothing, because
  more than one session shares this working directory and each of them fires
  `SessionStart`. A start that finds an address nothing answers removes it
  first, because a server killed with its VM never removes its own; the hook
  used to look only for the file, and such a file stopped every later session
  from starting a server. It reaps *itself* after
  thirty minutes of no requests, so a machine nobody is working on
  ends up with no harness running, without anything having to notice that the
  sessions ended.

  **The fallback — `noetic-harness hook` must still answer when the socket is not
  there.** The cold path is unchanged and is still the only path that is
  guaranteed to work. The fast path is tried first and *any* failure — no
  address file, a malformed one, connect refused, a slow or absent reply, a
  reply that is not one JSON object — falls through to it. The worst case a
  resident server can produce is therefore a connection refused on 127.0.0.1,
  which is immediate.

  ## Why TCP on the loopback, and what the token is for

  The client is `bash`, and bash speaks TCP with no process at all:
  `exec 3<>/dev/tcp/127.0.0.1/$port`. A Unix socket is a tighter boundary and
  would need `nc -U` or `socat`, a dependency the hook cannot take — it must
  work on a machine where `elixir` itself could not be found.

  So the socket is reachable by any process on this machine, and the token is
  what stands between that and "anything running as anybody can ask the harness
  to route, and be answered". It is 32 random bytes, written to a file this
  user alone can read, and a connection that does not open with it is closed
  without a reply. It is **not** a security boundary against a process that can
  read your files; it is the difference between a socket that answers everyone
  and one that answers you.
  """

  alias Noetic.Harness
  alias Noetic.Harness.{Attach, Beads}
  alias Noetic.Harness.Resident.Ready

  # How long the server sits with no request before it exits. Long enough to
  # cover a session someone walked away from, short enough that a laptop does
  # not accumulate one BEAM per repository per week.
  @idle_ms 30 * 60 * 1000

  # A request is one line of JSON and the hook's payloads are prompts, not
  # files. A megabyte is far past anything real and far short of anything that
  # matters to hold.
  @max_request 1_048_576

  # How long a connection may take to send its line before it is dropped. A
  # client that connects and says nothing must not hold a slot.
  @read_timeout_ms 5_000

  @token_bytes 32

  @doc """
  The file the client reads: port on line one, token on line two.

  `noetic-harness hook` reads the same path, and takes
  `NOETIC_HARNESS_RESIDENT_ADDR` as an override so that a test can stand up a
  server without touching the one this machine may actually be using. The
  override is **not** read here: a VM-global would be visible to every other
  async test in the suite, which is the defect an earlier change spent a session on.
  A caller that wants a different path passes `:addr_path` to `serve/1`.
  `noetic-harness hook` does, so that the server it starts writes the file it
  reads, the override's or this one.
  """
  @spec addr_path() :: Path.t()
  def addr_path, do: Path.join([Harness.root(), ".agents", "telemetry", "resident.addr"])

  @doc "The same facts, plus what a person would want to know, as JSON."
  @spec state_path() :: Path.t()
  def state_path, do: Path.join([Harness.root(), ".agents", "telemetry", "resident.json"])

  # The JSON summary sits beside the address file whatever the address file is,
  # so an isolated server's state does not land on the real one's.
  defp state_path_for(addr), do: Path.rootname(addr) <> ".json"

  @doc "The beam directory this server serves from."
  @spec ebin() :: Path.t()
  def ebin do
    case :code.lib_dir(:noetic_harness) do
      # Loaded without an application directory: this module's own beam is in
      # the directory the server serves from, wherever the engine is installed
      # (an earlier change — it used to guess the repository's `_build/dev`).
      {:error, _} -> __MODULE__ |> :code.which() |> List.to_string() |> Path.dirname()
      dir -> Path.join(List.to_string(dir), "ebin")
    end
  end

  @doc """
  A cheap summary of the compiled code: how many beams, the newest mtime, the
  total size.

  Three numbers rather than a hash of every file, because this runs before
  **every** answer and the answer it guards costs 32 ms. A change that leaves
  all three identical is a rewrite of one module to exactly its own size within
  the same second, which is not a thing `mix compile` does.
  """
  #
  # **Every call here is raw**. It was `Path.wildcard/1` and a
  # `File.stat/2` per beam: 84 calls to OTP's one file server per request,
  # which idle is nothing and under load was 2-5 s, because a file-server
  # call then waits ~25-60 ms. A raw call is made by the calling
  # process and queues behind nobody. `:prim_file.list_dir/1` is how the code
  # loader lists a directory without the file server; `:file` has no raw form
  # of it.
  @spec fingerprint(Path.t() | nil) :: map()
  def fingerprint(dir \\ nil) do
    dir = dir || ebin()

    beams =
      case :prim_file.list_dir(dir) do
        {:ok, names} ->
          for name <- names,
              name = List.to_string(name),
              String.ends_with?(name, ".beam"),
              do: Path.join(dir, name)

        {:error, _} ->
          []
      end

    stats =
      Enum.flat_map(beams, fn path ->
        case :file.read_file_info(path, [:raw, {:time, :posix}]) do
          {:ok, info} ->
            stat = File.Stat.from_record(info)
            [{stat.mtime, stat.size}]

          {:error, _} ->
            []
        end
      end)

    %{
      "count" => length(stats),
      "newest" => stats |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end),
      "bytes" => stats |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    }
  end

  @doc """
  Run the server in this process until it is stale, idle or stopped.

  **Returns rather than halting**, and the distinction is not cosmetic: a
  `System.halt/1` in here would mean the only way to test the accept loop is to
  not test it, because the test VM is the VM it would take down. The caller
  decides what the end of the loop means — the detached script ends, which ends
  its own VM; a test gets an atom back and carries on.

      :stale    the beams changed underneath it
      :idle     nobody asked anything for `idle_ms`
      :stopped  something authenticated asked it to stop
  """
  @spec serve(keyword()) :: :stale | :idle | :stopped | {:error, term()}
  def serve(opts \\ []) do
    idle = Keyword.get(opts, :idle_ms, @idle_ms)

    addr = Keyword.get(opts, :addr_path) || addr_path()

    # The one datum held; `Noetic.Harness.Resident.Ready`
    # says why it is an exception and how it stays honest. `:ready_fetch` is
    # for tests, which must not shell out to this repository's tracker.
    fetch = Keyword.get(opts, :ready_fetch, fn -> Beads.ready(6) end)

    case start_listener() do
      {:ok, socket, port, token} ->
        {:ok, cache} = Ready.start_link(fetch: fetch)
        Ready.refresh(cache)
        write_addr(addr, port, token)
        reason = loop(socket, token, fingerprint(), idle, cache)
        forget(addr)
        GenServer.stop(cache)
        reason

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_listener do
    options = [
      :binary,
      packet: :line,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1},
      backlog: 16
    ]

    with {:ok, socket} <- :gen_tcp.listen(0, options),
         {:ok, port} <- :inet.port(socket) do
      {:ok, socket, port,
       Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)}
    end
  end

  # Two lines, no JSON, no shell metacharacters: the reader is `bash` with
  # `read -r`, and anything it has to parse is something it can get wrong.
  defp write_addr(addr, port, token) do
    File.mkdir_p!(Path.dirname(addr))

    private!(addr, "#{port}\n#{token}\n")

    private!(
      state_path_for(addr),
      Noetic.Harness.Loader.pretty!(%{
        "port" => port,
        "os_pid" => System.pid(),
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "root" => Harness.root(),
        "ebin" => ebin(),
        "fingerprint" => fingerprint()
      })
    )
  end

  # Write beside it, tighten it, then rename.
  #
  # A `write!` followed by a `chmod!` leaves the file **world-readable for the
  # width of two syscalls**, and the thing in it is the token. Calibrated by
  # putting the two calls back: with two extra CPU burners on two cores, the
  # test that checks the mode fails **one run in six**, against none in six
  # with the rename. A race a reader would not have believed on inspection.
  #
  # The first version of this comment said four in six, from a run taken while
  # 36 burners the same session had leaked were still running and the load
  # average was 42. Same direction, wrong conditions; the number above is from
  # a load this session controlled.
  #
  # And a reader that arrives mid-write gets a port with no token, which
  # `address/0` would refuse and the hook would read as "no server". A rename
  # within one directory is atomic, so the file goes from absent to complete
  # with nothing in between.
  defp private!(path, contents) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(temporary, contents)
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, path)
  end

  @doc "Remove the address and state files. Safe to call when they are absent."
  @spec forget(Path.t() | nil) :: :ok
  def forget(addr \\ nil) do
    addr = addr || addr_path()
    File.rm(addr)
    File.rm(state_path_for(addr))
    :ok
  end

  defp loop(socket, token, fingerprint, idle, cache) do
    acceptor = self()

    case :gen_tcp.accept(socket, idle) do
      {:ok, connection} ->
        # A fresh process per request, which is what makes the definition
        # files re-read: `Loader.cached_load/1`'s cache is the process
        # dictionary.
        #
        # **The acceptor only accepts**. The staleness check used
        # to run here, before the hand-off, so every request waited for every
        # earlier request's check: 84 file-server calls each, 2-5 s under load,
        # and "twenty requests at once" left 13 of 20 unanswered at the
        # client's 20 s. Each handler checks now, in parallel, and a stale
        # handler stops the server the way an authenticated `stop` does.
        #
        # It waits to be told the socket is its own. Without that, the
        # handler can reach `:gen_tcp.recv/3` before
        # `controlling_process/2` has transferred it, get
        # `{:error, :not_owner}`, treat it as a refusal, and then fail to
        # close a socket it does not own — leaving the connection open,
        # owned by an acceptor that will never read it, until the client
        # times out.
        #
        # **This one is by inspection and is not calibrated.** Removing the
        # guard and running the suite six times under deliberate CPU load did
        # not reproduce it: `Task.start/1`'s child does not in practice get
        # scheduled before the transfer. It is kept because the ordering
        # hazard is real and the guard costs one message, and it is written
        # down as unproven rather than credited with the two intermittent
        # failures that prompted it — those were the address file's
        # permissions, below, which *is* calibrated.
        {:ok, task} =
          Task.start(fn ->
            receive do
              :yours -> handle(connection, token, socket, cache, fingerprint, acceptor)
            after
              @read_timeout_ms -> :gen_tcp.close(connection)
            end
          end)

        :gen_tcp.controlling_process(connection, task)
        send(task, :yours)
        loop(socket, token, fingerprint, idle, cache)

      {:error, :timeout} ->
        :gen_tcp.close(socket)
        :idle

      # An authenticated `stop`, or a handler that found the beams changed,
      # closes the listening socket from the process that served it, which is
      # how it reaches an acceptor blocked in `:gen_tcp.accept/2` without a
      # message it could not receive there. The handler that found them
      # changed says so first.
      {:error, :closed} ->
        receive do
          :stale -> :stale
        after
          0 -> :stopped
        end

      # Anything else — `:emfile` is the one worth naming — is retried, with a
      # pause. Without the pause a machine that has run out of descriptors
      # turns this into a process that pegs a core while failing, which is a
      # worse neighbour than a server that is simply down.
      {:error, _other} ->
        Process.sleep(50)
        loop(socket, token, fingerprint, idle, cache)
    end
  end

  # Serving one more answer off code that has been recompiled is the failure
  # the fingerprint exists to prevent, so a stale handler closes its
  # connection without a reply, and the client falls back.
  defp handle(connection, token, listener, cache, fingerprint, acceptor) do
    if fingerprint(ebin()) == fingerprint do
      answer(connection, token, listener, cache)
    else
      send(acceptor, :stale)
      :gen_tcp.close(connection)
      :gen_tcp.close(listener)
    end
  end

  defp answer(connection, token, listener, cache) do
    with {:ok, line} <- :gen_tcp.recv(connection, 0, @read_timeout_ms),
         true <- byte_size(line) <= @max_request,
         {:ok, request} <- JSON.decode(String.trim(line)),
         true <- is_map(request),
         true <- authentic?(request["token"], token) do
      :gen_tcp.send(connection, [respond(request, ready: fn -> Ready.answer(cache) end), "\n"])

      # Authenticated, and after the reply has gone out: a `--stop` that got no
      # answer would have to guess whether it worked.
      if request["event"] == "stop", do: :gen_tcp.close(listener)
    else
      _refused -> :ok
    end
  after
    :gen_tcp.close(connection)
  end

  # Constant-time, because the alternative compares a secret with `==` and the
  # cost of not doing it is a sentence explaining why it was fine.
  defp authentic?(offered, token) when is_binary(offered) do
    byte_size(offered) == byte_size(token) and :crypto.hash_equals(offered, token)
  end

  defp authentic?(_offered, _token), do: false

  @doc """
  What the server answers a well-formed request.

  Public because the test for it should exercise the answer rather than the
  socket: a test that has to stand up a listener to find out what `user_prompt`
  returns is a test of `:gen_tcp`.
  """
  @spec respond(map(), keyword()) :: String.t()
  def respond(request, opts \\ []) do
    event = request["event"]
    payload = if is_map(request["payload"]), do: request["payload"], else: %{}

    cond do
      event == "ping" -> ~s({"ok":true})
      event == "stop" -> ~s({"ok":true,"stopping":true})
      event in Noetic.Harness.Hooks.events() -> Attach.hook_json(event, payload, opts)
      true -> ""
    end
  rescue
    # `Attach.hook_json/2` does not raise — it says so, and it is tested. This
    # is here because a server that dies on one bad request stops answering
    # every later good one, and a hook that has to be restarted by hand is a
    # hook that gets turned off.
    _error -> ""
  end

  @doc """
  The port and token a client would use, or `:error`.

  Reads the file only; it does not check that anything is listening. The client
  finds that out by connecting, which is the only way to know.
  """
  @spec address(Path.t() | nil) :: {:ok, pos_integer(), String.t()} | :error
  def address(addr \\ nil) do
    with {:ok, contents} <- File.read(addr || addr_path()),
         [port, token | _] <- String.split(contents, "\n"),
         {port, ""} <- Integer.parse(String.trim(port)),
         token when byte_size(token) > 0 <- String.trim(token) do
      {:ok, port, token}
    else
      _ -> :error
    end
  end

  @doc """
  Ask the running server something, or say why not.

  This is the Elixir client — `--status` and the tests use it. The client that
  matters is the one in `noetic-harness hook`, which is nine lines of bash and
  spawns nothing.
  """
  @spec ask(String.t(), map(), non_neg_integer(), Path.t() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  def ask(event, payload \\ %{}, timeout \\ 5_000, addr \\ nil) do
    case address(addr) do
      :error ->
        {:error, :no_address}

      {:ok, port, token} ->
        connect(port, token, event, payload, timeout)
    end
  end

  defp connect(port, token, event, payload, timeout) do
    options = [:binary, packet: :line, active: false]

    case :gen_tcp.connect({127, 0, 0, 1}, port, options, timeout) do
      {:ok, socket} ->
        request = JSON.encode!(%{"token" => token, "event" => event, "payload" => payload})

        try do
          with :ok <- :gen_tcp.send(socket, [request, "\n"]),
               {:ok, line} <- :gen_tcp.recv(socket, 0, timeout) do
            {:ok, String.trim(line)}
          else
            {:error, reason} -> {:error, reason}
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether a server is up and answering on the recorded address.

  A pid that is alive is not the question — the question is whether the socket
  answers, and the only way to learn that is to ask it.
  """
  @spec alive?(Path.t() | nil, non_neg_integer()) :: boolean()
  def alive?(addr \\ nil, timeout \\ 2_000) do
    match?({:ok, ~s({"ok":true})}, ask("ping", %{}, timeout, addr))
  end

  @doc "What `--status` prints, as data."
  @spec status() :: map()
  def status do
    case File.read(state_path()) do
      {:ok, raw} ->
        case JSON.decode(raw) do
          {:ok, state} when is_map(state) ->
            state
            |> Map.put("alive", alive?())
            |> Map.put("stale", state["fingerprint"] != fingerprint())

          _ ->
            %{"alive" => false, "error" => "the state file is not readable JSON"}
        end

      {:error, _} ->
        %{"alive" => false, "error" => "no server has recorded an address here"}
    end
  end

  @doc "The idle budget, in milliseconds."
  @spec idle_ms() :: pos_integer()
  def idle_ms, do: @idle_ms
end
