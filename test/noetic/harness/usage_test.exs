defmodule Noetic.Harness.UsageTest do
  @moduledoc """
  What a session cost, and the two things this must never do: read content,
  and turn a file it did not understand into a zero.
  """
  # `async: true` since an earlier change. It was sync because the fixture root was
  # `NOETIC_HARNESS_ROOT`, a VM-global, so a fixture tree here was visible to
  # every other test in the VM. `Noetic.Harness.put_root/1` scopes it to this
  # process and the `Task`s it spawns, so the isolation is per test.
  use ExUnit.Case, async: true

  alias Noetic.Harness.Usage

  defp transcript(lines) do
    path =
      Path.join(
        System.tmp_dir!(),
        "usage-#{System.pid()}-#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, Enum.map_join(lines, "\n", &JSON.encode!/1) <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp assistant(usage, opts \\ []) do
    %{
      "type" => "assistant",
      "message" =>
        %{
          "model" => Keyword.get(opts, :model, "claude-opus-5"),
          "usage" => usage
        }
        |> then(fn m ->
          case Keyword.get(opts, :content) do
            nil -> m
            content -> Map.put(m, "content", content)
          end
        end)
    }
  end

  describe "the four counters" do
    test "each is summed separately, because they do not price the same" do
      path =
        transcript([
          assistant(%{
            "input_tokens" => 2,
            "output_tokens" => 190,
            "cache_creation_input_tokens" => 42_132,
            "cache_read_input_tokens" => 35_777
          }),
          assistant(%{
            "input_tokens" => 5,
            "output_tokens" => 10,
            "cache_creation_input_tokens" => 1,
            "cache_read_input_tokens" => 100_000
          })
        ])

      assert {:ok, summary} = Usage.read(path)

      assert summary["messages"] == 2

      assert summary["tokens"] == %{
               "input_tokens" => 7,
               "output_tokens" => 200,
               "cache_creation_input_tokens" => 42_133,
               "cache_read_input_tokens" => 135_777
             }
    end

    test "thinking tokens come out of output_tokens_details" do
      path =
        transcript([
          assistant(%{
            "output_tokens" => 500,
            "output_tokens_details" => %{"thinking_tokens" => 120}
          })
        ])

      assert {:ok, summary} = Usage.read(path)
      assert summary["thinking_tokens"] == 120
    end

    test "a counter that is absent, negative or not a number counts as nothing" do
      path =
        transcript([
          assistant(%{"output_tokens" => -5, "input_tokens" => "many"})
        ])

      assert {:ok, summary} = Usage.read(path)
      assert summary["tokens"]["output_tokens"] == 0
      assert summary["tokens"]["input_tokens"] == 0
      # The message still counted: it happened, and one bad field is not a
      # reason to lose the turn.
      assert summary["messages"] == 1
    end

    test "the counter names are read from one place" do
      assert Usage.counters() == ~w(
               input_tokens output_tokens
               cache_creation_input_tokens cache_read_input_tokens
             )
    end
  end

  describe "what it refuses to read" do
    test "a tool call contributes its name and nothing else" do
      secret = "SUPERSECRET-" <> String.duplicate("a", 24)

      path =
        transcript([
          assistant(%{"output_tokens" => 1},
            content: [
              %{"type" => "text", "text" => "here is the password #{secret}"},
              %{
                "type" => "tool_use",
                "name" => "Bash",
                "input" => %{
                  "command" => "curl -H 'Authorization: #{secret}' https://example.com"
                }
              },
              %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "ls"}}
            ]
          )
        ])

      assert {:ok, summary} = Usage.read(path)

      # The whole summary, inspected as the ledger would write it, and
      # asserted *first*. A transcript records everything a person said and
      # everything their files held, and `.agents/runs/` is committed to git —
      # so the rule is not "redact", it is "do not look".
      #
      # The order matters and an independent review is why: with the count
      # asserted first, the mutation that keeps the whole `tool_use` block
      # fails on `%{"Bash" => 2}` three lines before these ever run, so the
      # assertions the spec cited as the calibration were themselves
      # uncalibrated.
      rendered = Noetic.Harness.Loader.pretty!(summary)
      refute rendered =~ secret
      refute rendered =~ "curl"
      refute rendered =~ "password"
      refute rendered =~ "command"

      assert summary["tools"] == %{"Bash" => 2}
    end

    test "a model field is a label or it is nothing" do
      # `model` was copied verbatim and unchecked until a review put a
      # credential in one. A printable binary within the bound is kept; a
      # long one, an unprintable one, an iodata list — which `to_string/1`
      # flattens, appending raw bytes — and a map are all `unrecognised`.
      secret = "ghp_" <> String.duplicate("z", 36)

      path =
        transcript([
          assistant(%{"output_tokens" => 1}, model: "claude-opus-5"),
          assistant(%{"output_tokens" => 1}, model: "claude-opus-5 " <> secret),
          assistant(%{"output_tokens" => 1}, model: "<synthetic>"),
          assistant(%{"output_tokens" => 1}, model: String.duplicate("m", 200)),
          assistant(%{"output_tokens" => 1}, model: ["leak", 2]),
          assistant(%{"output_tokens" => 1}, model: %{"api_key" => secret}),
          assistant(%{"output_tokens" => 1}, model: "opus\u0000five")
        ])

      assert {:ok, summary} = Usage.read(path)

      # Rendered, because a map key that is itself a map made
      # `Loader.pretty!` raise inside `Enum.sort_by/3` — which the hook
      # swallowed, so the session was silently never recorded.
      rendered = Noetic.Harness.Loader.pretty!(summary)
      refute rendered =~ secret
      refute rendered =~ "api_key"

      assert summary["models"]["claude-opus-5"] == 1
      assert summary["models"]["<synthetic>"] == 1
      assert summary["models"]["unrecognised"] == 5

      # What the bound does not stop, asserted so that nobody reads more into
      # it than it says: a token-shaped secret with no whitespace is kept.
      # The privacy claim rests on no content field being read at all, not on
      # this.
      bare =
        transcript([
          assistant(%{"output_tokens" => 1}, model: "ghp_" <> String.duplicate("z", 36))
        ])

      assert {:ok, kept} = Usage.read(bare)
      assert kept["models"]["ghp_" <> String.duplicate("z", 36)] == 1
    end

    test "the keys a transcript can invent are bounded in number" do
      # 20 000 distinct tool names took a run file from 6 KB to 1.1 MB in one
      # observation. The busiest are kept and the tail is summed under
      # `other`, because "which tools did this lean on" is the question.
      calls = for i <- 1..500, do: %{"type" => "tool_use", "name" => "tool-#{i}"}
      bash = for _ <- 1..50, do: %{"type" => "tool_use", "name" => "Bash"}

      path = transcript([assistant(%{"output_tokens" => 1}, content: bash ++ calls)])

      assert {:ok, summary} = Usage.read(path)
      assert map_size(summary["tools"]) <= 40
      assert summary["tools"]["Bash"] == 50
      assert summary["tools"]["other"] > 0

      # Nothing is lost, only bucketed.
      assert summary["tools"] |> Map.values() |> Enum.sum() == 550
    end

    test "a tool name longer than the bound is a bucket, not a key" do
      path =
        transcript([
          assistant(%{"output_tokens" => 1},
            content: [%{"type" => "tool_use", "name" => String.duplicate("n", 200)}]
          )
        ])

      assert {:ok, summary} = Usage.read(path)
      assert summary["tools"] == %{"unrecognised" => 1}
    end

    test "a tool_use block with no name is not counted as a tool" do
      path =
        transcript([
          assistant(%{"output_tokens" => 1}, content: [%{"type" => "tool_use"}])
        ])

      assert {:ok, summary} = Usage.read(path)
      assert summary["tools"] == %{}
    end
  end

  describe "a file it could not read is not a session that cost nothing" do
    test "a malformed line is counted rather than skipped" do
      path = transcript([assistant(%{"output_tokens" => 7})])
      File.write!(path, File.read!(path) <> "{not json at all\n")

      assert {:ok, summary} = Usage.read(path)
      assert summary["unreadable"] == 1
      assert summary["messages"] == 1
    end

    test "a usage object carrying none of the four counters is unreadable, not a turn" do
      # `%{}` satisfies `is_map`, so counting the message would let an
      # unrecognised shape past the no-usage-anywhere guard one message at a
      # time — which is the guard going around the outside.
      path = transcript([assistant(%{}), assistant(%{"cost" => 0.4})])

      assert {:error, message} = Usage.read(path)
      assert message =~ "no assistant message carrying a usage object"
    end

    test "a transcript with no usage anywhere is an error, not a zero" do
      path =
        transcript([
          %{"type" => "user", "message" => %{"content" => "hello"}},
          %{"type" => "system", "subtype" => "init"}
        ])

      assert {:error, message} = Usage.read(path)
      assert message =~ "no assistant message carrying a usage object"
      assert message =~ "is not a session that cost nothing"
    end

    test "a path that is not a file is an error naming it" do
      assert {:error, message} = Usage.read("/tmp/there-is-no-such-transcript.jsonl")
      assert message =~ "no transcript at"
    end

    test "something that is not a path at all is refused rather than raising" do
      assert {:error, message} = Usage.read(nil)
      assert message =~ "is not a path to a transcript"
    end
  end

  describe "recording it against a run" do
    setup do
      root = Noetic.Harness.TestTmp.path("usage-runs") |> Noetic.Harness.Pack.populate()

      previous = Noetic.Harness.root_override()
      Noetic.Harness.put_root(root)

      on_exit(fn ->
        if previous,
          do: Noetic.Harness.put_root(previous),
          else: Noetic.Harness.delete_root()

        File.rm_rf!(root)
      end)

      {:ok, run} =
        Noetic.Harness.Run.start(
          workflow: "WF-002",
          title: "usage #{System.unique_integer([:positive])}",
          ephemeral: false
        )

      {:ok, run: run["id"]}
    end

    test "sessions are kept apart from dispatches, so no ceiling moves", %{run: run} do
      path = transcript([assistant(%{"output_tokens" => 10, "cache_read_input_tokens" => 999})])
      {:ok, summary} = Usage.read(path)

      assert {:ok, recorded} = Noetic.Harness.Run.observe(run, summary)
      assert [session] = recorded["sessions"]
      assert session["tokens"]["cache_read_input_tokens"] == 999
      assert session["at"] =~ "T"

      # The dispatch ceiling reads `dispatches` and must not learn about this:
      # a session is not something the harness bounded, and `spent/1` feeds
      # `Dispatcher`'s cost ceiling.
      assert recorded["dispatches"] == []
      assert Noetic.Harness.Run.spent(run).cost_usd == 0.0
    end

    test "observing the same transcript twice replaces the entry", %{run: run} do
      path = transcript([assistant(%{"output_tokens" => 10})])
      {:ok, first} = Usage.read(path)

      File.write!(
        path,
        File.read!(path) <> JSON.encode!(assistant(%{"output_tokens" => 90})) <> "\n"
      )

      {:ok, second} = Usage.read(path)

      {:ok, _} = Noetic.Harness.Run.observe(run, first)
      {:ok, recorded} = Noetic.Harness.Run.observe(run, second)

      assert length(recorded["sessions"]) == 1
      assert Noetic.Harness.Run.observed(run)["tokens"]["output_tokens"] == 100
      assert Noetic.Harness.Run.observed(run)["messages"] == 2
    end

    test "two different sessions both count", %{run: run} do
      for output <- [10, 25] do
        path = transcript([assistant(%{"output_tokens" => output})])
        {:ok, summary} = Usage.read(path)
        {:ok, _} = Noetic.Harness.Run.observe(run, summary)
      end

      observed = Noetic.Harness.Run.observed(run)
      assert observed["sessions"] == 2
      assert observed["tokens"]["output_tokens"] == 35
    end

    test "record/1 refuses each of the four ways it can fail to know the run", %{run: _run} do
      # None of these had a test: an independent review deleted `record/1`
      # outright and all thirty tests still passed, because the only thing
      # naming it was a `grep` for a string in `noetic-harness hook`.
      assert {:error, message} = Usage.record(%{})
      assert message =~ "carries no transcript_path"

      assert {:error, message} = Usage.record(%{"transcript_path" => ""})
      assert message =~ "carries no transcript_path"

      assert {:error, message} = Usage.record(%{"transcript_path" => "/tmp/not-a-transcript"})
      assert message =~ "no transcript at"

      assert {:error, message} = Usage.record(nil)
      assert message =~ "not an object"
    end

    test "record/1 records against the open run when there is exactly one", %{run: run} do
      path = transcript([assistant(%{"output_tokens" => 42})])

      assert {:ok, ^run, summary} = Usage.record(%{"transcript_path" => path})
      assert summary["tokens"]["output_tokens"] == 42
      assert Noetic.Harness.Run.observed(run)["tokens"]["output_tokens"] == 42
    end

    test "two transcripts with the same basename do not replace each other", %{run: run} do
      # Identity is a digest of the full path. Keyed on the basename these
      # would be one session and the first number would vanish.
      for dir <- ["a", "b"] do
        full =
          Noetic.Harness.TestTmp.path("usage-same-#{dir}")

        File.mkdir_p!(full)
        path = Path.join(full, "session.jsonl")
        File.write!(path, JSON.encode!(assistant(%{"output_tokens" => 5})) <> "\n")
        on_exit(fn -> File.rm_rf(full) end)

        {:ok, summary} = Usage.read(path)
        {:ok, _} = Noetic.Harness.Run.observe(run, summary)
      end

      assert Noetic.Harness.Run.observed(run)["sessions"] == 2
      assert Noetic.Harness.Run.observed(run)["tokens"]["output_tokens"] == 10
    end

    test "a run file whose sessions are malformed is read rather than raising", %{run: run} do
      path = Path.join(Noetic.Harness.agents_path("runs"), "#{run}.json")
      {:ok, stored} = Noetic.Harness.Loader.load(path)

      File.write!(
        path,
        Noetic.Harness.Loader.pretty!(
          Map.put(stored, "sessions", [
            "not a map",
            %{"messages" => "lots", "tokens" => %{"output_tokens" => "many"}},
            %{"messages" => 3, "tokens" => %{"output_tokens" => 9}}
          ])
        )
      )

      # These files are written by people and by other sessions. `run --status`
      # died halfway through its own output on both of the first two.
      observed = Noetic.Harness.Run.observed(run)
      assert observed["messages"] == 3
      assert observed["tokens"]["output_tokens"] == 9
    end

    # A worker's SessionEnd recorded its usage into another
    # worker's run: the only open run it could see, left open on develop.
    defp open_run(bead) do
      {:ok, run} =
        Noetic.Harness.Run.start(
          workflow: "WF-021",
          title: "usage #{bead} #{System.unique_integer([:positive])}",
          bead: bead,
          ephemeral: false
        )

      run["id"]
    end

    test "with two open runs, one foreign, the session's own epic is the one recorded", %{
      run: unrelated
    } do
      mine = open_run("bd-mine")
      foreign = open_run("bd-other")
      path = transcript([assistant(%{"output_tokens" => 7})])

      assert {:ok, ^mine, _} = Usage.record(%{"transcript_path" => path}, epic: "bd-mine")
      assert Noetic.Harness.Run.observed(mine)["tokens"]["output_tokens"] == 7
      assert Noetic.Harness.Run.observed(foreign)["sessions"] == 0
      assert Noetic.Harness.Run.observed(unrelated)["sessions"] == 0
    end

    test "when only other epics' runs are open, it refuses, names them, and records nothing", %{
      run: unrelated
    } do
      foreign = open_run("bd-other")
      path = transcript([assistant(%{"output_tokens" => 7})])

      assert {:error, message} = Usage.record(%{"transcript_path" => path}, epic: "bd-mine")
      assert message =~ "no open run is this session's epic bd-mine"
      assert message =~ "#{foreign}"

      assert Usage.outcome(%{"transcript_path" => path}, epic: "bd-mine") == "foreign_run"
      assert Noetic.Harness.Run.observed(foreign)["sessions"] == 0
      assert Noetic.Harness.Run.observed(unrelated)["sessions"] == 0
    end

    test "two open runs for the session's own epic are still not guessed between" do
      a = open_run("bd-mine")
      b = open_run("bd-mine")

      assert {:many, message} = Usage.session_run(epic: "bd-mine")
      assert message =~ a and message =~ b
    end

    test "with no epic, the old rule stands: exactly one open run, or none", %{run: run} do
      assert Usage.session_run(epic: nil) == {:ok, run}
      open_run("bd-other")
      assert {:many, _} = Usage.session_run(epic: nil)
    end

    test "a run that is not in the ledger is refused" do
      path = transcript([assistant(%{"output_tokens" => 1})])
      {:ok, summary} = Usage.read(path)

      assert {:error, _} = Noetic.Harness.Run.observe("run-there-is-no-such-thing", summary)
    end
  end

  describe "session_epic/0" do
    # A real git checkout, because the epic is read from the checked-out
    # branch and the handoff that names it.
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "usage-epic-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      File.mkdir!(root)
      File.mkdir_p!(Path.join([root, ".agents", "handoff"]))
      git = fn args -> {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true) end
      git.(~w(init -q -b develop))
      git.(~w(-c user.name=t -c user.email=t@t commit -q --allow-empty -m start))

      previous = Noetic.Harness.root_override()
      Noetic.Harness.put_root(root)

      on_exit(fn ->
        if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
        File.rm_rf!(root)
      end)

      handoff = fn epic, branch ->
        File.write!(
          Path.join([root, ".agents", "handoff", epic <> ".json"]),
          JSON.encode!(%{"epic" => epic, "branch" => branch, "status" => "working"})
        )
      end

      {:ok, git: git, handoff: handoff}
    end

    test "is the epic whose handoff names the checked-out branch", %{git: git, handoff: handoff} do
      handoff.("bd-other", "claude/bd-other-elsewhere")
      handoff.("bd-mine.3", "claude/bd-mine.3-slug")
      git.(~w(switch -q -c claude/bd-mine.3-slug))

      assert Usage.session_epic() == "bd-mine.3"
    end

    test "is nil on a branch no handoff names, however it is spelled", %{
      git: git,
      handoff: handoff
    } do
      # The coordinator's session branch is `claude/<name>` too; reading the
      # name as an epic would make the coordinator's own runs foreign.
      handoff.("bd-other", "claude/bd-other-elsewhere")
      git.(~w(switch -q -c claude/laughing-franklin))
      assert Usage.session_epic() == nil

      git.(~w(switch -q develop))
      assert Usage.session_epic() == nil
    end
  end
end
