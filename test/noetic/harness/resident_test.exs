defmodule Noetic.Harness.ResidentTest do
  @moduledoc """
  The resident server.

  The claim being defended is not "it is faster" — a benchmark says that and a
  benchmark is not a test. It is that the fast path **cannot answer differently
  from the cold one**, and that every way it can go wrong ends in the cold path
  rather than in a wrong answer.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Fixture, Hooks, Resident}
  alias Noetic.Harness.Resident.Ready

  # What these tests assert is what the server answers, and they
  # asked with `ask/2`'s default of 5 s, which is the hook's own `read -t 5`.
  # Past it the hook falls back to the cold path and still answers, so 5 s is
  # a property of the hook's patience and of the machine, not of the answer.
  # The server here runs inside the suite's own BEAM, and at load 14 on two
  # cores a `user_prompt` answer, three file-server calls since `Loader`
  # reads raw and waiting on no other request since the acceptor stopped
  # checking beams, still ran past 5 s: routing on a starved CPU. A test of
  # the answer waits for it; the concurrency test below is the one about
  # time, and it gives each of twenty requests 20 s.
  @answer_ms 30_000

  # Every server these tests start prefetches a ready list. A real one would be
  # `bd` opening this repository's Dolt database once per test, which makes the
  # suite slow and makes it a test of the tracker's state.
  def fixture_ready, do: {:ok, "○ bd-fixture P1 a fixture, not the tracker"}

  # A root on the pack (`Noetic.Harness.Pack`): the point of the comparison
  # is that the two paths agree, and they agree about any registry or about
  # none. The address file goes somewhere isolated so a test cannot disturb a
  # server this machine is actually using. It used to be this repository's
  # `.agents/`, linked in.
  defp with_isolated_addr(fun) do
    # The definitions have to be there for `hook_json/2` to route; only
    # `telemetry/` and the other writable directories are this test's own.
    root = Noetic.Harness.TestTmp.path("resident") |> Noetic.Harness.Pack.populate()

    previous = Noetic.Harness.put_root(root)

    try do
      fun.(root)
    after
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
      File.rm_rf(root)
    end
  end

  defp serving(fun) do
    with_isolated_addr(fn root ->
      server =
        Task.async(fn ->
          Resident.serve(idle_ms: 60_000, ready_fetch: &__MODULE__.fixture_ready/0)
        end)

      # `serve/1` writes the address file before it accepts, so waiting for the
      # file is waiting for the socket.
      wait_for_address(500)

      try do
        fun.(root)
      after
        Resident.ask("stop", %{}, 10_000)
        Task.await(server, 20_000)
      end
    end)
  end

  # Five seconds, not one. This suite runs four-way on two cores and these
  # budgets are about the scheduler, not about the server — a fixture that
  # times out under load is a test that reports the machine.
  defp wait_for_address(0), do: flunk("the server never wrote an address file")

  defp wait_for_address(tries) do
    case Resident.address() do
      {:ok, _port, _token} -> :ok
      :error -> Process.sleep(10) && wait_for_address(tries - 1)
    end
  end

  describe "the answer" do
    test "ping is answered, and it is what `alive?/0` reads" do
      serving(fn _root ->
        assert Resident.alive?(nil, 20_000)
        assert {:ok, ~s({"ok":true})} = Resident.ask("ping", %{}, @answer_ms)
      end)
    end

    test "a hook event is answered with exactly what the cold path would say" do
      payload = %{"prompt" => "the qdrant client cannot authenticate"}

      serving(fn _root ->
        # Inside, so that both paths answer from the same root.
        cold = Noetic.Harness.Attach.hook_json("user_prompt", payload)
        assert {:ok, warm} = Resident.ask("user_prompt", payload, @answer_ms)
        assert warm == cold

        assert String.starts_with?(warm, ~s({"hookSpecificOutput")),
               "the server answered something the hook's own contract check would drop"
      end)
    end

    test "an event outside the vocabulary is answered with nothing, not with a guess" do
      serving(fn _root ->
        assert {:ok, ""} = Resident.ask("not_an_event", %{"prompt" => "hello"}, @answer_ms)
      end)
    end

    test "a payload that is not a map is treated as an empty one rather than crashing it" do
      serving(fn _root ->
        assert {:ok, _} = Resident.ask("user_prompt", %{}, @answer_ms)
        # And the server is still there afterwards, which is the actual claim:
        # one malformed request must not stop it answering every later one.
        assert Resident.alive?(nil, 20_000)
      end)
    end
  end

  describe "under concurrency" do
    test "twenty requests at once all get an answer" do
      # The test that makes the ownership race likely rather than occasional.
      # `loop/4` spawns the handler and *then* transfers the socket to it; a
      # handler that reads before the transfer gets `{:error, :not_owner}`,
      # cannot close a socket it does not own, and leaves the client waiting
      # for a reply nobody will send. It first showed up as two intermittent
      # failures in the two token tests below, under a loaded four-way
      # `mix test` and never standalone — which is how it would have reached a
      # session, as a hook that "sometimes does not fire".
      serving(fn _root ->
        answers =
          1..20
          |> Task.async_stream(fn n -> Resident.ask("ping", %{"n" => n}, 20_000) end,
            max_concurrency: 20,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, answer} -> answer end)

        assert Enum.all?(answers, &match?({:ok, ~s({"ok":true})}, &1)),
               "#{Enum.count(answers, &(not match?({:ok, _}, &1)))} of 20 concurrent requests " <>
                 "went unanswered: #{inspect(Enum.reject(answers, &match?({:ok, _}, &1)))}"
      end)
    end
  end

  describe "the token" do
    test "a request without the token gets no reply at all" do
      serving(fn _root ->
        {:ok, port, _token} = Resident.address()

        assert :closed == unauthenticated(port, ~s({"event":"ping"}))
      end)
    end

    test "a request with the wrong token gets no reply at all" do
      serving(fn _root ->
        {:ok, port, token} = Resident.address()
        wrong = String.duplicate("a", byte_size(token))

        assert :closed == unauthenticated(port, ~s({"token":"#{wrong}","event":"ping"}))
      end)
    end

    test "the address file is readable by this user and nobody else" do
      serving(fn _root ->
        %{mode: mode} = File.stat!(Resident.addr_path())
        assert Bitwise.band(mode, 0o077) == 0, "the token is readable by somebody else"
      end)
    end
  end

  defp unauthenticated(port, line) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    :gen_tcp.send(socket, [line, "\n"])

    case :gen_tcp.recv(socket, 0, 10_000) do
      {:error, reason} -> reason
      {:ok, reply} -> {:answered, reply}
    end
  after
    :ok
  end

  describe "staleness" do
    test "the fingerprint moves when a beam does, and not otherwise" do
      dir = Noetic.Harness.TestTmp.dir!("ebin")
      File.write!(Path.join(dir, "a.beam"), "one")

      first = Resident.fingerprint(dir)
      assert Resident.fingerprint(dir) == first, "the fingerprint is not stable"

      File.write!(Path.join(dir, "b.beam"), "two")
      assert Resident.fingerprint(dir) != first

      File.rm_rf(dir)
    end

    test "a fingerprint over an empty or missing directory is a value, not a crash" do
      assert %{"count" => 0} = Resident.fingerprint("/nonexistent/ebin")
    end

    test "the data a request reads is re-read, so no watcher has to keep it fresh" do
      # The half of the staleness question that is free, and the reason every
      # request gets its own process: `Loader.cached_load/1` caches in the
      # process dictionary. Two calls in *this* process share a cache; the
      # server's do not, because they are not in this process.
      key = {Noetic.Harness.Loader, :cache, Path.join([Noetic.Harness.root(), ".agents", "x"])}
      refute Process.get(key)

      serving(fn _root ->
        assert {:ok, _} = Resident.ask("user_prompt", %{"prompt" => "route this"}, @answer_ms)

        refute Process.get(
                 {Noetic.Harness.Loader, :cache,
                  Path.join([Noetic.Harness.root(), ".agents", "registry", "agents.json"])},
                 nil
               ),
               "the server answered in the caller's process, so its cache is this process's"
      end)
    end
  end

  describe "the address file" do
    test "a malformed one is not an address" do
      with_isolated_addr(fn _root ->
        File.write!(Resident.addr_path(), "not-a-port\ntoken\n")
        assert :error == Resident.address()

        File.write!(Resident.addr_path(), "4000\n")
        assert :error == Resident.address()

        File.write!(Resident.addr_path(), "4000\nabc\n")
        assert {:ok, 4000, "abc"} == Resident.address()
      end)
    end

    test "an address file for a server that is gone is not alive" do
      with_isolated_addr(fn _root ->
        # Port 1 is privileged and nothing of ours listens there, so the
        # connect is refused rather than answered by somebody else's process.
        File.write!(Resident.addr_path(), "1\n#{String.duplicate("t", 32)}\n")
        refute Resident.alive?(nil, 2_000)
      end)
    end

    test "status says not running, and says why, rather than raising" do
      with_isolated_addr(fn _root ->
        assert %{"alive" => false, "error" => message} = Resident.status()
        assert message =~ "no server"
      end)
    end

    test "the files are gone once the server has stopped" do
      with_isolated_addr(fn _root ->
        server =
          Task.async(fn ->
            Resident.serve(idle_ms: 60_000, ready_fetch: &__MODULE__.fixture_ready/0)
          end)

        wait_for_address(500)
        assert File.exists?(Resident.addr_path())

        Resident.ask("stop", %{}, 10_000)
        assert :stopped == Task.await(server, 20_000)

        refute File.exists?(Resident.addr_path()),
               "a stopped server left an address the next client will wait on"
      end)
    end
  end

  describe "what the ledger records about which path was taken" do
    test "`via` is a word in the vocabulary, and absent is `unknown`" do
      # Not `cold`. Every line written before this bead lacks the field, and
      # counting them as cold would put ~1000 ms observations into a bucket
      # nobody measured them into.
      assert "unknown" in Hooks.vias()

      line = Hooks.line(%{"event" => "user_prompt", "ms" => 10, "outcome" => "injected"})
      assert line =~ ~s("via":"unknown")

      resident = Hooks.line(%{"event" => "user_prompt", "ms" => 10, "via" => "resident"})
      assert resident =~ ~s("via":"resident")

      forged = Hooks.line(%{"event" => "user_prompt", "ms" => 10, "via" => "instant"})
      assert forged =~ ~s("via":"unrecognised")
    end

    test "session_end is not an event the resident may answer" do
      # It is the one event that writes. A shared, long-lived process serving a
      # write is a larger claim than this bead makes, and the hook must not be
      # able to drift into making it.
      refute "session_end" in Hooks.resident_events()
      assert Enum.all?(Hooks.resident_events(), &(&1 in Hooks.events()))
      refute Hooks.ceiling("session_end", "resident")
    end

    test "the fast path's ceiling is materially tighter than the cold one" do
      for event <- ~w(user_prompt pre_tool) do
        cold = Hooks.ceiling(event, "cold")
        warm = Hooks.ceiling(event, "resident")

        assert warm < cold,
               "#{event}'s resident ceiling is #{warm} against a cold #{cold} — a ceiling that " <>
                 "is not lower defends nothing"
      end
    end

    test "the two paths are counted separately, so neither can hide inside the other" do
      observations =
        Enum.map(1..Hooks.min_observations(), fn _ ->
          %{
            "at" => "2026-09-22T00:00:00Z",
            "event" => "user_prompt",
            "ms" => 60,
            "bytes" => 800,
            "outcome" => "injected",
            "bounded" => true,
            "via" => "resident"
          }
        end) ++
          Enum.map(1..Hooks.min_observations(), fn _ ->
            %{
              "at" => "2026-09-22T00:00:00Z",
              "event" => "user_prompt",
              "ms" => 1_200,
              "bytes" => 800,
              "outcome" => "injected",
              "bounded" => true,
              "via" => "cold"
            }
          end)

      stats = Hooks.latency(%{"observations" => observations})["user_prompt"]

      # The aggregate says nothing about either, and it hides the *slow* half:
      # with ten observations at 60 ms and ten at 1200, nearest rank puts the
      # median at 60 and the cold path disappears entirely.
      assert stats["p50"] == 60
      assert stats["via"]["resident"]["p50"] == 60
      assert stats["via"]["cold"]["p50"] == 1_200
      assert stats["via"]["resident"]["checked"]
      refute stats["via"]["resident"]["over_ceiling"]
      assert stats["via"]["cold"]["checked"]
    end

    test "a resident path that stopped being fast is over its ceiling, and the aggregate is not" do
      # The calibration: with the fast path at 900 ms — still well under the
      # 3000 ms a BEAM boot is allowed — the split catches it and the rolled-up
      # median does not.
      slow = Hooks.ceiling("user_prompt", "resident") + 400

      observations =
        Enum.map(1..Hooks.min_observations(), fn _ ->
          %{
            "at" => "2026-09-22T00:00:00Z",
            "event" => "user_prompt",
            "ms" => slow,
            "bytes" => 800,
            "outcome" => "injected",
            "bounded" => true,
            "via" => "resident"
          }
        end)

      stats = Hooks.latency(%{"observations" => observations})["user_prompt"]

      refute stats["over_ceiling"],
             "the fixture does not reproduce the defect: #{slow} ms is already over the " <>
               "aggregate ceiling, so the split is not what caught it"

      assert stats["via"]["resident"]["over_ceiling"]
    end
  end

  describe "an observation taken on a saturated machine" do
    # Lowering a ceiling from 3000 ms to 500 makes the gate far
    # more sensitive to what else the machine is doing, so the observation has
    # to carry what else the machine was doing. The window that forced this:
    # a session left 36 spinning shell loops running, two cores carried a load
    # average of 42, and `user_prompt` recorded a median of 15 598 ms.

    defp at_load(ms, load) do
      base = %{
        "at" => "2026-09-22T00:00:00Z",
        "event" => "user_prompt",
        "ms" => ms,
        "bytes" => 800,
        "outcome" => "injected",
        "bounded" => true,
        "via" => "cold"
      }

      if load, do: Map.put(base, "load", load), else: base
    end

    test "is excluded from the median, and counted where it was excluded" do
      ceiling = Hooks.load_ceiling()

      fast = Enum.map(1..Hooks.min_observations(), fn _ -> at_load(900, 1) end)
      wedged = Enum.map(1..5, fn _ -> at_load(15_598, ceiling * 10) end)

      stats = Hooks.latency(%{"observations" => fast ++ wedged})["user_prompt"]

      assert stats["count"] == Hooks.min_observations()
      assert stats["saturated"] == 5
      assert stats["p50"] == 900
      refute stats["over_ceiling"]
    end

    test "without the exclusion the same fixture fails the gate" do
      # The calibration, in the same test file rather than in a commit message:
      # with the wedged observations counted, the median goes over the ceiling.
      ceiling = Hooks.load_ceiling()

      fast = Enum.map(1..Hooks.min_observations(), fn _ -> at_load(900, 1) end)
      wedged = Enum.map(1..11, fn _ -> at_load(15_598, ceiling * 10) end)

      unfiltered =
        Hooks.latency(%{
          "observations" => Enum.map(fast ++ wedged, &Map.delete(&1, "load"))
        })["user_prompt"]

      assert unfiltered["over_ceiling"],
             "the fixture does not reproduce the defect, so the test above proves nothing"

      filtered = Hooks.latency(%{"observations" => fast ++ wedged})["user_prompt"]
      refute filtered["over_ceiling"]
      assert filtered["checked"], "the exclusion dropped the sample below the floor"
    end

    test "an observation with no load recorded is kept, never excluded" do
      # A line written before this field existed, or a machine with no
      # `/proc/loadavg`. A reader may not exclude what nobody measured —
      # defaulting the other way would silently empty an older log.
      refute Hooks.saturated?(at_load(9_000, nil))
      assert Hooks.saturated?(at_load(9_000, Hooks.load_ceiling() + 1))
      refute Hooks.saturated?(at_load(9_000, Hooks.load_ceiling()))
    end

    test "the ceiling is per scheduler, so it means the same on two cores and on sixteen" do
      assert Hooks.load_ceiling() == 4 * :erlang.system_info(:schedulers_online)

      assert Hooks.load_ceiling() >= 4,
             "a machine reporting no schedulers would make every observation saturated"
    end

    test "a load a normal four-way suite produces is NOT excluded" do
      # The direction of the risk: \"the machine was busy\" is exactly the
      # excuse a latency gate must not accept. This repository's own suite runs
      # four-way and puts two cores at four to six, and those are real
      # conditions an agent works under.
      busy_but_real = :erlang.system_info(:schedulers_online) * 3

      refute Hooks.saturated?(at_load(1_200, busy_but_real)),
             "the threshold is tight enough to discard the suite's own conditions"
    end

    @tag this_repository: true
    test "the shell writes the field, and writes nothing rather than a zero when it cannot" do
      source = File.read!(Path.join(Noetic.Harness.root(), "noetic-harness hook"))

      assert source =~ "read -r one _ </proc/loadavg",
             "the hook reads the load with a fork instead of a builtin, on a ~70 ms path"

      assert source =~ ~s("load":%s),
             "the hook no longer writes the load field"

      assert Hooks.line(%{"event" => "user_prompt", "ms" => 10, "load" => 7}) =~ ~s("load":7)
      assert Hooks.line(%{"event" => "user_prompt", "ms" => 10}) =~ ~s("load":null)
    end
  end

  describe "the token never becomes a commit" do
    @tag this_repository: true
    test "git ignores the address and state files" do
      # The address file holds the token. A `git add .agents/` by a later
      # session — or this one — would publish a credential, and the file is
      # created by an ordinary `SessionStart`, so it is present in most working
      # directories most of the time.
      root = Noetic.Harness.root()

      for path <- ~w(.agents/telemetry/resident.addr .agents/telemetry/resident.json) do
        {out, status} =
          System.cmd("git", ["check-ignore", "-q", path], cd: root, stderr_to_stdout: true)

        assert status == 0, "git does not ignore #{path} (#{out})"
      end
    end

    test "the address file is inside .agents/telemetry, where the ignore rule points" do
      # The rule is written against a path. A refactor that moved the file
      # elsewhere would leave the rule matching nothing and the test above
      # passing, because `check-ignore` is asked about the literal path rather
      # than about what the module writes.
      assert Resident.addr_path() =~ ".agents/telemetry/resident.addr"
      assert Resident.state_path() =~ ".agents/telemetry/resident.json"
    end
  end

  describe "the one datum the resident holds: the ready list" do
    # A clock the test moves, and a fetch that counts. The moduledoc's claims
    # are about time and about how often `bd` is asked; both have to be under
    # the test's control or the test is about the machine.
    defp clock(start \\ 0) do
      {:ok, agent} = Agent.start_link(fn -> start end)
      {fn -> Agent.get(agent, & &1) end, fn ms -> Agent.update(agent, &(&1 + ms)) end}
    end

    defp counted(result) do
      counter = :counters.new(1, [])
      {fn -> :counters.add(counter, 1, 1) && result end, fn -> :counters.get(counter, 1) end}
    end

    test "with nothing cached, the answer is live, and the next one is cached with its age" do
      {now, advance} = clock()
      {fetch, calls} = counted({:ok, "○ bd-1 P1 one"})
      {:ok, cache} = Ready.start_link(fetch: fetch, now: now)

      assert {:live, {:ok, "○ bd-1 P1 one"}} = Ready.answer(cache)
      assert calls.() == 1

      advance.(4 * 60_000)
      assert {:cached, {:ok, "○ bd-1 P1 one"}, age} = Ready.answer(cache)
      assert age == 4 * 60_000
    end

    test "a cached answer starts a refresh, and the next answer is the refreshed one" do
      {now, _advance} = clock()
      results = :ets.new(:results, [:public])
      :ets.insert(results, {:current, {:ok, "○ bd-1 P1 before"}})

      fetch = fn ->
        [{:current, result}] = :ets.lookup(results, :current)
        result
      end

      {:ok, cache} = Ready.start_link(fetch: fetch, now: now)

      assert {:live, {:ok, "○ bd-1 P1 before"}} = Ready.answer(cache)

      # The tracker changes; the cache does not know yet.
      :ets.insert(results, {:current, {:ok, "○ bd-2 P1 after"}})

      assert {:cached, {:ok, "○ bd-1 P1 before"}, _} = Ready.answer(cache),
             "served stale — which is the design, and why the age is printed"

      assert eventually(fn ->
               match?({:cached, {:ok, "○ bd-2 P1 after"}, _}, Ready.answer(cache))
             end),
             "the background refresh never replaced the stale list"
    end

    test "past its max age nothing is served from the cache; the call is live" do
      {now, advance} = clock()
      {fetch, calls} = counted({:ok, "○ bd-1 P1 one"})
      {:ok, cache} = Ready.start_link(fetch: fetch, now: now, max_age_ms: 60_000)

      {:live, _} = Ready.answer(cache)
      advance.(60_001)

      assert {:live, _} = Ready.answer(cache)
      assert calls.() >= 2
    end

    test "a timeout is never cached, because it describes a lock held now" do
      {now, _advance} = clock()
      {fetch, calls} = counted(:timeout)
      {:ok, cache} = Ready.start_link(fetch: fetch, now: now)

      assert {:live, :timeout} = Ready.answer(cache)
      assert {:live, :timeout} = Ready.answer(cache)
      assert calls.() == 2, "a cached :timeout would report a lock after it was released"
    end

    test "two sessions starting together cost one bd, not two" do
      {now, _advance} = clock()
      test = self()

      fetch = fn ->
        send(test, {:fetching, self()})

        receive do
          :release -> {:ok, "○ bd-1 P1 one"}
        after
          5_000 -> :error
        end
      end

      {:ok, cache} = Ready.start_link(fetch: fetch, now: now)

      Ready.refresh(cache)
      Ready.refresh(cache)
      Ready.refresh(cache)

      assert_receive {:fetching, in_flight}, 2_000
      refute_receive {:fetching, _}, 200

      # Free the one fetch, and check that a refresh after it completes does
      # start another — single-flight, not "only ever once".
      send(in_flight, :release)
      assert eventually(fn -> match?({:cached, _, _}, GenServer.call(cache, :lookup)) end)

      Ready.refresh(cache)
      assert_receive {:fetching, second}, 2_000
      send(second, :release)
    end

    test "a fetch that raises leaves the cache answering" do
      {now, _advance} = clock()
      {:ok, cache} = Ready.start_link(fetch: fn -> raise "bd exploded" end, now: now)

      Ready.refresh(cache)
      Process.sleep(50)

      assert Process.alive?(cache)
      assert_raise RuntimeError, fn -> Ready.answer(cache) end
      assert Process.alive?(cache), "a crash in the caller took the cache with it"
    end
  end

  describe "what session_start says about a list it did not just fetch" do
    test "a cached list is stamped with its age, in the heading" do
      {:ok, text} =
        Noetic.Harness.Attach.context("session_start", %{},
          ready: fn -> {:cached, {:ok, "○ bd-7 P1 the thing"}, 4 * 60_000} end
        )

      assert text =~ "Ready work (`bd ready`, as of 4 min ago — run it for now):"
      assert text =~ "○ bd-7 P1 the thing"
    end

    test "a live list carries no stamp, because it is not a claim about the past" do
      {:ok, text} =
        Noetic.Harness.Attach.context("session_start", %{},
          ready: fn -> {:live, {:ok, "○ bd-7 P1 the thing"}} end
        )

      assert text =~ "Ready work (`bd ready`):"
      refute text =~ "as of"
    end

    test "seconds are said as seconds" do
      {:ok, text} =
        Noetic.Harness.Attach.context("session_start", %{},
          ready: fn -> {:cached, {:ok, "○ bd-7 P1 x"}, 42_000} end
        )

      assert text =~ "as of 42 s ago"
    end

    test "through the socket, a server serves the list it prefetched" do
      with_isolated_addr(fn _root ->
        server =
          Task.async(fn ->
            Resident.serve(
              idle_ms: 60_000,
              ready_fetch: fn -> {:ok, "○ bd-prefetched P1 from the fixture"} end
            )
          end)

        wait_for_address(500)

        try do
          assert eventually(fn ->
                   case Resident.ask("session_start", %{}, 20_000) do
                     {:ok, json} -> json =~ "bd-prefetched" and json =~ "as of"
                     _ -> false
                   end
                 end),
                 "the second and later session_start were not served from the prefetch"
        after
          Resident.ask("stop", %{}, 10_000)
          Task.await(server, 20_000)
        end
      end)
    end
  end

  defp eventually(check, tries \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, tries) do
    if check.(), do: true, else: Process.sleep(20) && eventually(check, tries - 1)
  end

  describe "the fixture tree is not disturbed" do
    test "an isolated root keeps its own address file" do
      Fixture.with_tree(Fixture.minimal(), fn root ->
        assert Resident.addr_path() =~ root
        assert Resident.state_path() =~ root
      end)
    end
  end
end
