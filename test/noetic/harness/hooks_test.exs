defmodule Noetic.Harness.HooksTest do
  # `async: false`, and the reason is a defect this suite already paid for.
  # `Hooks.log_path/0` resolves through `NOETIC_HARNESS_HOOK_LOG`, which is a
  # VM-global. An async test that sets it points *every* concurrently running
  # test in the same VM at this temporary file, and when the test finishes and
  # deletes it, whatever they were reading is gone. That is exactly how
  # `usage_test.exs` took down `SecurityTest` three runs out of five, under a
  # failure message that named neither of them.
  use ExUnit.Case, async: false

  alias Noetic.Harness.Hooks

  @env "NOETIC_HARNESS_HOOK_LOG"

  setup do
    path =
      Path.join(Noetic.Harness.TestTmp.path("hooks"), "hooks.jsonl")

    previous = System.get_env(@env)
    System.put_env(@env, path)

    on_exit(fn ->
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)
      File.rm_rf(Path.dirname(path))
    end)

    {:ok, path: path}
  end

  defp write(observations) do
    Enum.each(observations, &Hooks.record/1)
  end

  defp observation(event, ms, overrides \\ %{}) do
    Map.merge(
      %{"event" => event, "ms" => ms, "bytes" => 100, "outcome" => "injected", "bounded" => true},
      overrides
    )
  end

  describe "the log" do
    test "an absent log is no observations, not zero latency", %{path: path} do
      refute File.exists?(path)

      read = Hooks.observations()

      assert read["observations"] == []
      assert read["path"] == path
      assert Hooks.latency(read) == %{}
    end

    test "a recorded observation comes back with every field" do
      write([observation("user_prompt", 1204)])

      assert [entry] = Hooks.observations()["observations"]
      assert entry["event"] == "user_prompt"
      assert entry["ms"] == 1204
      assert entry["bytes"] == 100
      assert entry["outcome"] == "injected"
      assert entry["bounded"] == true
      assert is_binary(entry["at"])
    end

    test "a line that will not parse is counted, not skipped", %{path: path} do
      write([observation("user_prompt", 10)])
      File.write!(path, "{ this is not json\n", [:append])
      write([observation("user_prompt", 20)])

      read = Hooks.observations()

      assert length(read["observations"]) == 2
      assert read["unreadable"] == 1
    end

    test "an event this module did not write is unreadable, not a new bucket", %{path: path} do
      # Grouping by whatever string is in the field would let a stranger's row
      # into a percentile this repository then defends a budget with.
      write([observation("user_prompt", 10)])
      File.write!(path, ~s({"event":"deploy_to_prod","ms":50000}\n), [:append])

      read = Hooks.observations()

      assert read["unreadable"] == 1
      assert Map.keys(Hooks.latency(read)) == ["user_prompt"]
    end

    test "a malformed duration is unreadable, never the fastest possible value" do
      # The direction matters and the first version had it backwards: a float,
      # a string or a negative became `0`, so any writer emitting `1200.5`
      # instead of `1200` would drive the median to zero and hold the gate
      # green forever. An independent review found it. The one number the gate
      # reads fails closed.
      write([
        observation("user_prompt", -5),
        observation("user_prompt", "1200"),
        observation("user_prompt", 1200.5),
        observation("user_prompt", nil)
      ])

      read = Hooks.observations()

      assert read["observations"] == []
      assert read["unreadable"] == 4
    end

    test "an absurd duration is unreadable, so one appended line cannot turn the gate red" do
      write([observation("user_prompt", 99_999_999_999), observation("user_prompt", 1200)])

      read = Hooks.observations()

      assert Enum.map(read["observations"], & &1["ms"]) == [1200]
      assert read["unreadable"] == 1
    end

    test "a line missing any field the writer emits is unreadable, not defaulted", %{path: path} do
      # Renaming the shell's `bounded` key left the suite green, made every
      # observation read `bounded: false`, and made `noetic-harness telemetry`
      # print a confident and wrong explanation — that `timeout` was not on the
      # PATH. A silent default turns drift into a false diagnosis.
      for missing <- ~w(at ms bytes outcome bounded) do
        File.rm_rf(path)

        line =
          %{
            "event" => "user_prompt",
            "ms" => 10,
            "bytes" => 1,
            "outcome" => "injected",
            "bounded" => true,
            "at" => "2026-09-22T05:40:11Z"
          }
          |> Map.delete(missing)
          |> JSON.encode!()

        File.mkdir_p!(Path.dirname(path))
        File.write!(path, line <> "\n")

        read = Hooks.observations()

        assert read["observations"] == [],
               "a line with no #{missing} parsed anyway, and every field it did not carry " <>
                 "was invented"

        assert read["unreadable"] == 1
      end
    end

    test "bounded must be a boolean, not a string that looks like one", %{path: path} do
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        ~s({"at":"2026-09-22T05:40:11Z","event":"user_prompt","ms":10,"bytes":1,) <>
          ~s("outcome":"injected","bounded":"true"}\n)
      )

      assert Hooks.observations()["unreadable"] == 1
    end

    test "an outcome outside the vocabulary is bucketed, not stored" do
      write([observation("user_prompt", 10, %{"outcome" => "ghp_a_secret_someone_put_here"})])

      assert [%{"outcome" => "unrecognised"}] = Hooks.observations()["observations"]
    end

    test "record/1 writes bounded as a boolean whatever it was handed" do
      write([
        observation("user_prompt", 10, %{"bounded" => "true"}),
        observation("user_prompt", 10, %{"bounded" => nil})
      ])

      assert Hooks.observations()["observations"] |> Enum.map(& &1["bounded"]) == [false, false]
    end

    test "the timestamp is normalised on the way in, and matches the shell's format" do
      # `line/1` says every field is normalised before it is written, and this
      # was the field for which that was false — any string passed straight
      # through. The two writers also have to agree: the shell writes
      # `date -u +%Y-%m-%dT%H:%M:%SZ`, so `record/1` writes seconds too rather
      # than `DateTime.to_iso8601/1`'s microseconds.
      write([
        observation("user_prompt", 10),
        observation("user_prompt", 10, %{"at" => String.duplicate("x", 10_000)}),
        observation("user_prompt", 10, %{"at" => 7})
      ])

      for entry <- Hooks.observations()["observations"] do
        assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, entry["at"]),
               "wrote #{inspect(entry["at"])}, which the shell would never produce"
      end
    end

    test "the window rolls rather than growing without bound" do
      write(Enum.map(1..520, &observation("user_prompt", &1)))

      read = Hooks.observations()

      assert length(read["observations"]) == 500

      # The *oldest* are the ones dropped: a window that discards the newest
      # observation is a window that never notices a regression.
      assert read["observations"] |> hd() |> Map.get("ms") == 21
      assert read["observations"] |> List.last() |> Map.get("ms") == 520
    end
  end

  describe "latency" do
    test "percentiles are observations, not interpolations between two of them" do
      write(
        Enum.map(
          [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000],
          &observation("user_prompt", &1)
        )
      )

      stats = Hooks.latency()["user_prompt"]

      assert stats["count"] == 10
      assert stats["p50"] == 500
      assert stats["p95"] == 1000
      assert stats["max"] == 1000
      assert stats["p50"] in [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]
    end

    test "p95 is the outlier a mean would bury, and only while it is 5% of the window" do
      # Nine fast observations and one 14-second one: the mean is 1.6s and
      # says nothing about either, while p95 is the 14 seconds somebody
      # actually waited for.
      write(Enum.map(List.duplicate(200, 9) ++ [14_000], &observation("user_prompt", &1)))

      stats = Hooks.latency()["user_prompt"]
      assert stats["p50"] == 200
      assert stats["p95"] == 14_000

      # And the part worth knowing before reading the number: nearest rank
      # takes the ceil(0.95n)-th observation, so the *same* single outlier in
      # a window of twenty is no longer the 95th percentile — it is the
      # maximum, which is why `max` is printed beside it rather than implied.
      write(Enum.map(List.duplicate(200, 10), &observation("user_prompt", &1)))

      wider = Hooks.latency()["user_prompt"]
      assert wider["count"] == 20
      assert wider["p95"] == 200
      assert wider["max"] == 14_000
    end

    test "a median below the floor is reported and not checked" do
      write(Enum.map(1..9, fn _ -> observation("user_prompt", 99_999) end))

      stats = Hooks.latency()["user_prompt"]

      assert stats["count"] == 9
      assert stats["p50"] == 99_999
      refute stats["checked"]

      refute stats["over_ceiling"],
             "nine observations declared a budget breach; a median of nine is not a median, " <>
               "and `min_observations/0` exists so that the gate cannot fire on an anecdote"
    end

    test "a median over the ceiling is over the ceiling once the floor is cleared" do
      over = Hooks.ceiling("user_prompt") + 1
      write(Enum.map(1..Hooks.min_observations(), fn _ -> observation("user_prompt", over) end))

      stats = Hooks.latency()["user_prompt"]

      assert stats["checked"]
      assert stats["over_ceiling"]
      assert stats["ceiling"] == Hooks.ceiling("user_prompt")
    end

    test "an event with no written ceiling is never declared over it" do
      # Every event in `events/0` has one today. This asserts the *shape*: a
      # missing ceiling must read as "not checked", never as "passed" and
      # never as a crash comparing an integer with nil.
      refute Hooks.ceiling("no_such_event")

      write(Enum.map(1..20, fn _ -> observation("user_prompt", 1) end))
      assert Hooks.latency()["user_prompt"]["checked"]
    end

    test "unbounded observations are counted so the report cannot imply a budget was applied" do
      write([
        observation("user_prompt", 10),
        observation("user_prompt", 10, %{"bounded" => false})
      ])

      assert Hooks.latency()["user_prompt"]["unbounded"] == 1
    end

    test "outcomes are counted per event, so a silent refusal is visible" do
      # The five refusals are named rather than collapsed into one `refused`:
      # "no open run" is the ordinary state of most sessions, and "two runs are
      # open" is the one worth noticing. A single word told you that it did not
      # record and not why, which an independent review said was less than the
      # hole it claimed to close.
      write([
        observation("session_end", 900, %{"outcome" => "recorded"}),
        observation("session_end", 900, %{"outcome" => "no_run"}),
        observation("session_end", 900, %{"outcome" => "many_runs"})
      ])

      assert Hooks.latency()["session_end"]["outcomes"] ==
               %{"recorded" => 1, "no_run" => 1, "many_runs" => 1}
    end
  end

  describe "the budgets themselves" do
    test "every event has both a kill budget and a ceiling" do
      for event <- Hooks.events() do
        assert is_integer(Hooks.kill_budget(event)), "#{event} can run forever"
        assert is_integer(Hooks.ceiling(event)), "#{event} has no ceiling to be checked against"
      end
    end

    test "reading stdin has a budget of its own" do
      # The hook's first act is `payload="$(cat)"`, and the first version of
      # this change left it unbounded — so a writer that never closed stdin
      # hung the hook forever, before it reached the `timeout` that the prose
      # said covered "every event", and left no observation at all.
      assert is_integer(Hooks.stdin_budget())
      assert Hooks.stdin_budget() > 0

      for event <- Hooks.events() do
        assert Hooks.stdin_budget() < Hooks.kill_budget(event),
               "#{event}: reading the payload may take longer than running the harness"
      end
    end

    test "the kill budget is above the ceiling for every event" do
      # They answer different questions — "this session is not hostage to the
      # harness" and "the harness has not quietly got slower" — and a kill
      # budget at or below the ceiling would collapse the two: every
      # observation that should have been reported as slow would instead be
      # reported as a timeout, and the median would look fine forever.
      for event <- Hooks.events() do
        assert Hooks.kill_budget(event) > Hooks.ceiling(event),
               "#{event}: the kill budget #{Hooks.kill_budget(event)} ms is not above the " <>
                 "#{Hooks.ceiling(event)} ms ceiling, so a slow hook is killed rather than counted"
      end
    end
  end

  describe "the cutoff that keeps the gate from reading its own noise" do
    # Every test here uses a fixture log, because the property is
    # about the filter and not about this machine.
    @before "2026-09-22T10:00:00Z"
    @after_ "2026-09-22T11:00:00Z"
    @cutoff "2026-09-22T10:30:00Z"

    test "an observation recorded after the cutoff is dropped and counted" do
      write([
        observation("user_prompt", 1200, %{"at" => @before}),
        observation("user_prompt", 9000, %{"at" => @after_})
      ])

      read = Hooks.until(Hooks.observations(), @cutoff)

      assert Enum.map(read["observations"], & &1["ms"]) == [1200]
      assert read["excluded"] == 1
      assert read["cutoff"] == "2026-09-22T10:30:00Z"
    end

    test "an observation exactly at the cutoff is kept" do
      write([observation("user_prompt", 1200, %{"at" => @cutoff})])

      assert length(Hooks.until(Hooks.observations(), @cutoff)["observations"]) == 1
    end

    test "an at nobody can parse is excluded, not kept" do
      # The module's existing rule, applied to the other field the gate now
      # depends on: a line that cannot be shown to predate the cutoff has not
      # been shown to predate the cutoff. Keeping it would put exactly the
      # observations this filter exists to remove back into the sample, since
      # a malformed line is more likely to be a damaged one than an old one.
      write([
        observation("user_prompt", 1200, %{"at" => @before}),
        observation("user_prompt", 9000, %{"at" => "yesterday"})
      ])

      read = Hooks.until(Hooks.observations(), @cutoff)

      assert Enum.map(read["observations"], & &1["ms"]) == [1200]
      assert read["excluded"] == 1
    end

    test "a cutoff nobody can parse yields nothing, not everything" do
      # Failing open here would silently restore the defect, and the gate would
      # go on reporting a pass. There is no observation it is safe to keep when
      # the cutoff is unknown.
      write([observation("user_prompt", 1200, %{"at" => @before})])

      read = Hooks.until(Hooks.observations(), "not a date")

      assert read["observations"] == []
      assert read["excluded"] == :unreadable_cutoff
    end

    test "the filter changes the verdict, which is the only reason it exists" do
      # The discriminating test. Without it the fix is unfalsifiable: the
      # median is comfortably under the ceiling on this machine today, so
      # deleting the `until/2` call from the gate would leave the whole suite
      # green and the defect back.
      #
      # Ten fast observations before the cutoff, eleven slow ones after —
      # the shape a lane run produces, where the suite runs for fourteen
      # minutes and the session driving it fires `pre_tool` on every edit.
      ceiling = Hooks.ceiling("user_prompt")

      write(
        for _ <- 1..Hooks.min_observations() do
          observation("user_prompt", 1000, %{"at" => @before})
        end ++
          for _ <- 1..(Hooks.min_observations() + 1) do
            observation("user_prompt", ceiling * 2, %{"at" => @after_})
          end
      )

      unfiltered = Hooks.latency(Hooks.observations())["user_prompt"]
      filtered = Hooks.latency(Hooks.until(Hooks.observations(), @cutoff))["user_prompt"]

      assert unfiltered["over_ceiling"],
             "the fixture does not reproduce the defect, so this test proves nothing: " <>
               "unfiltered median is #{unfiltered["p50"]} against a ceiling of #{ceiling}"

      assert filtered["checked"],
             "the filter dropped the sample below the floor, so the gate stopped checking " <>
               "rather than checking correctly — #{filtered["count"]} observation(s) left"

      refute filtered["over_ceiling"],
             "the cutoff did not remove the interference: median #{filtered["p50"]} over " <>
               "#{filtered["count"]} observations"
    end
  end

  describe "the budget the hooks are actually held to" do
    # The gate an earlier change asks for: a test that fails when the recorded
    # median passes the written ceiling. It reads the *real* log, not the
    # fixture, because the claim is about this machine.
    #
    # Below the floor it does not assert and says which way it went, which is
    # this repository's existing answer to a test that silently does not run
    # (`test_helper.exs` prints the same way for the `:qdrant` tag). A CI
    # runner has never run the hooks, so there it will always print; the
    # machine-independent half of this bead is the pair of tests above and the
    # one in `entry_points_test.exs` that proves the shell enforces what this
    # module wrote down.
    test "no event's median latency has passed its ceiling on this machine" do
      System.delete_env(@env)

      # As the log stood when the suite began, not as it stands now.
      # Everything this run's own session appended while the
      # suite was running is excluded, because a hook firing beside a four-way
      # `mix test` on two cores is measuring the load and not the hook. That
      # made this gate fail two lane runs in three while the same command
      # passed standalone four times.
      started = Application.get_env(:noetic_harness, :suite_started_at)

      assert started,
             "the suite did not record when it started, so this gate would read its own " <>
               "interference as data. See test_helper.exs."

      read = Hooks.until(Hooks.observations(), started)
      latency = Hooks.latency(read)

      if read["excluded"] > 0 do
        IO.puts(
          "\n  hook budget: #{read["excluded"]} observation(s) recorded during this run " <>
            "were excluded"
        )
      end

      # Reported **per event**, not only when nothing at all cleared the
      # floor. The first version printed the "not checked" line only when
      # `checked == []`, so with `pre_tool` and `user_prompt` over ten
      # observations and `session_start` at three, the slowest event in the
      # harness — the one carrying `bd ready` — was silently unchecked while
      # the test looked satisfied. That is the §5 failure this whole file is
      # about, committed by the file itself.
      unchecked =
        Hooks.events()
        |> Enum.map(fn event -> {event, latency[event]} end)
        |> Enum.reject(fn {_event, stats} -> stats && stats["checked"] end)

      saturated = latency |> Map.values() |> Enum.map(& &1["saturated"]) |> Enum.sum()

      if saturated > 0 do
        IO.puts(
          "\n  hook budget: #{saturated} observation(s) excluded, recorded at a load average " <>
            "above #{Hooks.load_ceiling()} on #{:erlang.system_info(:schedulers_online)} " <>
            "scheduler(s) — a measurement of the machine, not of the hook"
        )
      end

      if unchecked != [] do
        IO.puts(
          "\n  hook budget: not checked for #{length(unchecked)} of #{length(Hooks.events())} event(s), " <>
            "#{Hooks.min_observations()} observations needed —"
        )

        for {event, stats} <- unchecked do
          IO.puts("    #{event}: #{(stats && stats["count"]) || 0} observation(s)")
        end
      end

      for {event, stats} <- latency, stats["checked"] do
        refute stats["over_ceiling"],
               "#{event}: median #{stats["p50"]} ms over #{stats["count"]} observations, " <>
                 "against a ceiling of #{stats["ceiling"]} ms (p95 #{stats["p95"]}, " <>
                 "max #{stats["max"]}). Either the hook got slower or the ceiling in " <>
                 "Noetic.Harness.Hooks is wrong — raising it is a decision with a reason, " <>
                 "not a way to make this pass. Neither is deleting the log it reads: the " <>
                 "file is git-ignored, so that leaves no trace in a diff, and §4 counts it " <>
                 "as a change to the gate."
      end

      # And per path. The aggregate above cannot defend the
      # fast path: a resident server that quietly stopped being resident would
      # produce cold numbers, which are exactly what the aggregate ceiling was
      # written for. The split is the only place a 500 ms budget is a budget.
      for {event, stats} <- latency,
          {via, split} <- stats["via"],
          split["checked"] do
        refute split["over_ceiling"],
               "#{event} via #{via}: median #{split["p50"]} ms over #{split["count"]} " <>
                 "observations, against a ceiling of #{split["ceiling"]} ms (p95 " <>
                 "#{split["p95"]}, max #{split["max"]}). For `resident` this means the " <>
                 "server that is supposed to already be running was not, or has stopped " <>
                 "being fast; `noetic-harness resident --status` says which."
      end
    end
  end
end
