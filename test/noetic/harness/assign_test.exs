defmodule Noetic.Harness.AssignTest do
  @moduledoc """
  `noetic-harness assign`: an epic's paths are disjoint from every
  other live epic's, or it is refused with the files named.

  Against fixtures: a profiles document and a tracked-file list small enough
  to read, and live assignments built by hand. The task itself is run once,
  under `--dry-run` against this repository, with a stand-in for bd, because a
  suite that reads or writes the real tracker is a suite that depends on it.
  """
  # `async: false` for the last describe only: it sets `:assign_beads`, an
  # application env key, which is VM-global.
  use ExUnit.Case, async: false

  alias Noetic.Harness.Assign

  # On the pack (`Noetic.Harness.Pack`), with `workers` on and an ADR layout
  # of its own: an assignment is the worker protocol's, and where an ADR file
  # would be is the project's to say. Both used to be this repository's.
  @moduletag pack_integrations: ["workers"]
  @moduletag pack_project: %{
               "adr" => %{"dir" => "docs/decisions", "prefix" => "DR-", "digits" => 3}
             }
  setup {Noetic.Harness.Pack, :root}

  @tracked ~w(
    lib/world/nex.ex lib/world/live.ex lib/world/client.ts
    lib/content/canon.ex lib/content/parser.ex
    lib/harness/router.ex lib/harness/kb.ex
    CLAUDE.md bin/tool .beads/issues.jsonl
    .agents/runs/r1.json .agents/handoff/bd-1.json .agents/policies/gates.json
    docs/decisions/DR-030-something.md
  )

  defp doc do
    %{
      "profiles" => [
        profile("visual-world", ["lib/world/**"], 2),
        profile("content", ["lib/content/**"], 1),
        profile("harness", ["lib/harness/**", ".agents/**"], 1, ["lib/harness/kb.ex"]),
        profile("memory", ["lib/harness/kb.ex"], 1)
      ],
      "coordinator" => %{
        "description" => "held",
        "held" => [%{"glob" => "CLAUDE.md", "why" => "x"}, %{"glob" => "bin/**", "why" => "x"}]
      },
      "refused" => [%{"glob" => ".beads/**", "why" => "x"}],
      "add_only" => [%{"glob" => ".agents/runs/*.json", "why" => "x"}],
      "per_epic" => [%{"glob" => ".agents/handoff/{epic}.json", "why" => "x"}],
      "shared" => []
    }
  end

  defp profile(id, owns, max, except \\ []) do
    %{"id" => id, "owns" => owns, "except" => except, "max_concurrent" => max}
  end

  defp opts(live \\ %{}),
    do: [doc: doc(), tracked: @tracked, fence: [".agents/policies/**"], live: {live, 0}]

  defp live_record(epic, profile, scope, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "2026-09-25-assign-#{epic}-aaaaaa",
        "act" => "assign",
        "at" => "2026-09-25T10:00:00Z",
        "bead" => epic,
        "profile" => profile,
        "branch" => "claude/#{epic}-work",
        "scope" => scope,
        "narrowed" => true,
        "grants" => [],
        "reserved_adr_numbers" => []
      },
      extra
    )
  end

  describe "overlap is decided on tracked files" do
    test "a second epic that shares a file with a live one is refused, and the file is named" do
      live = %{"bd-1" => live_record("bd-1", "visual-world", ["lib/world/nex.ex"])}

      assert {:error, [reason]} =
               Assign.plan(
                 %{epic: "bd-2", profile: "visual-world", scope: ["lib/world/*.ex"]},
                 opts(live)
               )

      assert reason =~ "shares 1 tracked file(s) with bd-1 (visual-world, claude/bd-1-work)"
      assert reason =~ "lib/world/nex.ex"
      refute reason =~ "lib/world/live.ex"
    end

    test "disjoint scopes of one profile are accepted" do
      live = %{"bd-1" => live_record("bd-1", "visual-world", ["lib/world/nex.ex"])}

      assert {:ok, plan} =
               Assign.plan(
                 %{epic: "bd-2", profile: "visual-world", scope: ["lib/world/client.ts"]},
                 opts(live)
               )

      assert plan.files == 1
    end

    test "grants are compared as well as scope" do
      live = %{"bd-1" => live_record("bd-1", "content", ["lib/content/**"])}

      assert {:error, [reason]} =
               Assign.plan(
                 %{
                   epic: "bd-2",
                   profile: "visual-world",
                   scope: ["lib/world/nex.ex"],
                   grants: ["lib/content/parser.ex"]
                 },
                 opts(live)
               )

      assert reason =~ "with bd-1" and reason =~ "lib/content/parser.ex"
    end

    test "a live epic on the profile's whole scope keeps its carve-outs out of the comparison" do
      # harness owns lib/harness/** less kb.ex; memory owns kb.ex.
      live = %{
        "bd-1" =>
          live_record("bd-1", "harness", ["lib/harness/**", ".agents/**"], %{"narrowed" => false})
      }

      assert {:ok, _} = Assign.plan(%{epic: "bd-2", profile: "memory"}, opts(live))
    end

    test "add-only and per-epic files are in every scope, and are not a conflict" do
      live = %{
        "bd-1" =>
          live_record("bd-1", "visual-world", [
            "lib/world/nex.ex",
            ".agents/runs/*.json",
            ".agents/handoff/bd-1.json"
          ])
      }

      assert {:ok, plan} =
               Assign.plan(
                 %{
                   epic: "bd-2",
                   profile: "visual-world",
                   scope: ["lib/world/live.ex", ".agents/runs/*.json"]
                 },
                 opts(live)
               )

      assert plan.files == 1
    end
  end

  describe "a scope stays inside its profile" do
    test "--scope that reaches another profile's file is refused, naming it and its owner" do
      assert {:error, [reason]} =
               Assign.plan(%{epic: "bd-2", profile: "content", scope: ["lib/**"]}, opts())

      assert reason =~ "--scope leaves content's paths"
      assert reason =~ "lib/world/nex.ex (visual-world's)"
      assert reason =~ "--grant"
    end

    test "the refused set is never granted; a held path needs --ack" do
      request = %{
        epic: "bd-2",
        profile: "content",
        scope: ["lib/content/**"],
        grants: [".beads/**", "CLAUDE.md"]
      }

      assert {:error, reasons} = Assign.plan(request, opts())

      assert Enum.any?(
               reasons,
               &(&1 =~ "refused paths, which no epic may change: .beads/issues.jsonl")
             )

      assert Enum.any?(reasons, &(&1 =~ "coordinator-held paths, which need --ack: CLAUDE.md"))

      request = %{request | grants: ["CLAUDE.md"]} |> Map.put(:ack, true)
      assert {:ok, plan} = Assign.plan(request, opts())
      assert plan.acked == ["CLAUDE.md"]
    end

    test "a fenced grant needs --ack too" do
      request = %{
        epic: "bd-2",
        profile: "content",
        scope: ["lib/content/**"],
        grants: [".agents/policies/gates.json"]
      }

      assert {:error, [reason]} = Assign.plan(request, opts())
      assert reason =~ "fenced paths, which need --ack"
    end
  end

  describe "the other refusals" do
    test "a profile at its max_concurrent is refused" do
      live = %{"bd-1" => live_record("bd-1", "content", ["lib/content/canon.ex"])}

      assert {:error, [reason]} =
               Assign.plan(
                 %{epic: "bd-2", profile: "content", scope: ["lib/content/parser.ex"]},
                 opts(live)
               )

      assert reason =~ "content runs at most 1 session(s), and bd-1 already hold(s) an assignment"
    end

    test "an ADR number that exists, or that a live epic reserved, is refused" do
      live = %{
        "bd-1" =>
          live_record("bd-1", "visual-world", ["lib/world/nex.ex"], %{
            "reserved_adr_numbers" => [31]
          })
      }

      request = %{epic: "bd-2", profile: "content", scope: ["lib/content/**"], adrs: [30, 31, 32]}

      assert {:error, reasons} = Assign.plan(request, opts(live))
      assert "ADR-30 exists already" in reasons
      assert "ADR-31 is reserved by bd-1" in reasons
      refute Enum.any?(reasons, &(&1 =~ "ADR-32"))
    end

    test "every reason is given at once" do
      live = %{"bd-1" => live_record("bd-1", "content", ["lib/content/**"])}

      request = %{
        epic: "bd-2",
        profile: "content",
        scope: ["lib/**"],
        grants: [".beads/**"],
        adrs: [30]
      }

      assert {:error, reasons} = Assign.plan(request, opts(live))
      assert length(reasons) >= 4
    end

    test "an unknown profile is named with the ones that exist" do
      assert {:error, [reason]} = Assign.plan(%{epic: "bd-2", profile: "nope"}, opts())

      assert reason =~
               "no profile \"nope\"; the profiles are visual-world, content, harness, memory"
    end
  end

  describe "reassignment and release" do
    test "an epic that is live already needs --reassign, which numbers its slug" do
      live = %{
        "bd-1" =>
          live_record("bd-1", "content", ["lib/content/**"], %{"branch" => "claude/bd-1-canon"})
      }

      request = %{epic: "bd-1", profile: "content"}

      assert {:error, [reason]} = Assign.plan(request, opts(live))
      assert reason =~ "bd-1 is already assigned to content on claude/bd-1-canon"

      assert {:ok, plan} = Assign.plan(Map.put(request, :reassign, true), opts(live))

      # The holder bd is asked to confirm is the live assignment's
      # profile; a first assign has none.
      assert Assign.holder(plan) == plan.previous["profile"]
      assert is_binary(Assign.holder(plan))
      assert Assign.branch(plan, "canon") == "claude/bd-1-canon-2"

      assert Assign.branch(%{plan | previous: %{"branch" => "claude/bd-1-canon-2"}}, "canon") ==
               "claude/bd-1-canon-3"

      record =
        Assign.record("reassign", plan,
          at: "2026-09-25T11:00:00Z",
          nonce: "bbbbbb",
          branch: "claude/bd-1-canon-2",
          previous_head: "abc123"
        )

      assert record["previous"] == %{
               "record" => "2026-09-25-assign-bd-1-aaaaaa",
               "branch" => "claude/bd-1-canon",
               "head" => "abc123"
             }

      assert record["id"] == "2026-09-25-reassign-bd-1-bbbbbb"
    end

    test "a release record carries the old branch's head" do
      previous = live_record("bd-1", "content", ["lib/content/**"])

      record =
        Assign.release_record(previous,
          at: "2026-09-25T12:00:00Z",
          nonce: "cccccc",
          previous_head: "def456"
        )

      assert record["act"] == "abandon"
      assert record["previous"]["head"] == "def456"
      assert record["previous"]["branch"] == "claude/bd-1-work"
    end
  end

  describe "what is live" do
    test "the latest scoped record decides; an abandon or a closed epic ends it; unscoped are counted" do
      records = [
        live_record("bd-1", "content", ["a/**"]),
        live_record("bd-2", "content", ["b/**"]),
        live_record("bd-2", "content", ["b/**"], %{
          "act" => "abandon",
          "at" => "2026-09-25T11:00:00Z",
          "id" => "x"
        }),
        live_record("bd-3", "content", ["c/**"]),
        %{"act" => "assign", "bead" => "bd-old", "profile" => "content"}
      ]

      status = fn
        "bd-3" -> {:ok, "closed"}
        _ -> :error
      end

      assert {live, 1} = Assign.live(records: records, status: status)
      assert Map.keys(live) == ["bd-1"]
    end
  end

  describe "records on disk" do
    setup do
      root = Noetic.Harness.TestTmp.path("assign")
      File.mkdir_p!(Path.join(root, ".agents"))
      previous = Noetic.Harness.root_override()
      Noetic.Harness.put_root(root)

      on_exit(fn ->
        if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
        File.rm_rf!(root)
      end)

      {:ok, root: root}
    end

    test "a record is written once, read back as live, and never overwritten" do
      {:ok, plan} = Assign.plan(%{epic: "bd-9", profile: "content"}, opts())

      record =
        Assign.record("assign", plan,
          at: "2026-09-25T13:00:00Z",
          nonce: "dddddd",
          branch: "claude/bd-9-work"
        )

      assert {:ok, path} = Assign.write(record)
      assert Path.basename(path) == "2026-09-25-assign-bd-9-dddddd.json"
      assert {:error, message} = Assign.write(record)
      assert message =~ "never overwritten"

      assert {%{"bd-9" => %{"branch" => "claude/bd-9-work"}}, 0} = Assign.live()
    end
  end

  describe "the brief" do
    test "is byte-identical for identical inputs, and opens with the line a worker accepts" do
      {:ok, plan} =
        Assign.plan(
          %{
            epic: "bd-7",
            profile: "content",
            scope: ["lib/content/parser.ex"],
            grants: ["CLAUDE.md"],
            adrs: [33],
            ack: true
          },
          opts()
        )

      text = "bd-7 · the GSL checker says where\n\nAcceptance: it does.\n"
      brief = Assign.brief(plan, "claude/bd-7-parser-where", text)

      assert brief == Assign.brief(plan, "claude/bd-7-parser-where", text)

      assert brief == """
             EPIC bd-7: branch claude/bd-7-parser-where, scope lib/content/parser.ex, grants CLAUDE.md

             ## The epic, as bd shows it

             bd-7 · the GSL checker says where

             Acceptance: it does.

             ## Scope

                 lib/content/parser.ex
                 .agents/handoff/bd-7.json
                 .agents/runs/*.json                      (new files only)
                 .agents/memory/records/*.json            (new files only)

             ## Grants

                 CLAUDE.md

             Coordinator-held or fenced, landed only with --ack: CLAUDE.md

             ## Reserved ADR numbers

             ADR-33

             ## Protocol

             CLAUDE.md, *If you are a cloud worker*: WF-021, the handoff,
             WIP pushes, `run --finish`, the pull request against develop.
             End with `EPIC bd-7 READY <S> <pr-url>`, or `EPIC bd-7 BLOCKED <reason>`.
             """
    end

    test "a whole-profile scope names the paths another profile holds inside it" do
      {:ok, plan} = Assign.plan(%{epic: "bd-8", profile: "harness"}, opts())
      assert Assign.brief(plan, "claude/bd-8-x", "") =~ "not lib/harness/kb.ex"
    end
  end

  describe "the task, under --dry-run" do
    defmodule StandInBeads do
      @moduledoc false
      def work_item(id),
        do: record({:work_item, id}, {:ok, %{title: "a stand-in epic", body: "#{id} · stand-in"}})

      def status(id), do: record({:status, id}, :error)

      def assign(epic, profile, _notes, previous \\ nil),
        do: record({:assign, epic, profile, previous}, :ok)

      def release(epic, profile, _notes), do: record({:release, epic, profile}, :ok)

      defp record(call, answer) do
        send(Process.get(:assign_test_pid) || self(), {:bd, call})
        answer
      end
    end

    setup do
      previous = Application.get_env(:noetic_harness, :assign_beads)
      Application.put_env(:noetic_harness, :assign_beads, StandInBeads)
      Process.put(:assign_test_pid, self())

      on_exit(fn ->
        if previous,
          do: Application.put_env(:noetic_harness, :assign_beads, previous),
          else: Application.delete_env(:noetic_harness, :assign_beads)
      end)
    end

    # The task against this repository's profiles.json, whose `harness`
    # profile owns the scope; the pack has no profiles.
    @tag this_repository: true
    test "writes nothing, in bd or on disk, and prints the brief" do
      before = File.ls!(Assign.dir())

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Harness.Assign.run(
            ~w(--epic bd-dry --profile harness --scope docs/design/harness.md --dry-run)
          )
        end)

      assert output =~
               "EPIC bd-dry: branch claude/bd-dry-a-stand-in-epic, scope docs/design/harness.md, grants none"

      assert File.ls!(Assign.dir()) == before

      refute_received {:bd, {:assign, _, _}}
      refute_received {:bd, {:release, _, _}}
      assert_received {:bd, {:work_item, "bd-dry"}}
    end
  end
end
