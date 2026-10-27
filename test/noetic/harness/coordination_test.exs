defmodule Noetic.Harness.CoordinationTest do
  @moduledoc """
  The coordination records pass `coordination.schema.json`, and
  `noetic-harness validate` says so.

  Once against this repository's records, which the schema was derived from
  and which cannot be rewritten; against a record broken each way the check
  claims to catch; and against what `Assign` writes, because the first record
  `noetic-harness assign` writes must not be the first one validate refuses.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Assign, Coordination, Loader, Profiles, TestTmp}

  # On the pack (`Noetic.Harness.Pack`) with `workers` switched on: the
  # records are the worker protocol's. "This repository" is tagged
  # `this_repository` and reads the records on this branch.
  @moduletag pack_integrations: ["workers"]
  setup {Noetic.Harness.Pack, :root}

  # The pack's copy, read when the module compiles: the harness root is not
  # yet any test's, and a standalone checkout of the engine has no `.agents/`.
  @schema Loader.load!(
            Path.join([Noetic.Harness.Pack.source(), "schemas", "coordination.schema.json"])
          )

  defp errors(findings), do: for({:error, message} <- findings, do: message)

  defp check(file, record), do: Coordination.validate(records: [{file, record}], schema: @schema)

  # A record that passes, the shape Assign.record/3 writes.
  defp assign(extra \\ %{}) do
    Map.merge(
      %{
        "id" => "2026-09-27-assign-bd-1-abc123",
        "act" => "assign",
        "at" => "2026-09-27T10:00:00Z",
        "by" => "the coordinator",
        "bead" => "bd-1",
        "profile" => "harness",
        "session" => nil,
        "branch" => "claude/bd-1-work",
        "scope" => ["lib/harness/**"],
        "narrowed" => true,
        "grants" => [],
        "acked" => [],
        "reserved_adr_numbers" => [],
        "files" => 3
      },
      extra
    )
  end

  defp file(record), do: record["id"] <> ".json"

  describe "a malformed record is refused" do
    test "an act's required field missing is named, with the file" do
      record = Map.delete(assign(), "branch")

      assert [message] = errors(check(file(record), record))
      assert message == "coordination: #{file(record)}: missing required key branch"
    end

    test "a field of the wrong type" do
      record = assign(%{"scope" => "lib/harness/**"})

      assert [message] = errors(check(file(record), record))
      assert message =~ "#{file(record)}.scope: expected array, got string"
    end

    test "one of the four every record has" do
      record = Map.delete(assign(), "by")
      assert ["coordination: " <> _] = errors(check(file(record), record))
    end

    test "an act that is not one" do
      record = assign(%{"act" => "asign"})
      findings = errors(check(file(record), record))

      assert Enum.any?(findings, &(&1 =~ ~s|"asign" is not one of|)), inspect(findings)
    end

    test "an id that is not the file's name" do
      record = assign()

      assert [message] = errors(check("2026-09-27-assign-bd-1-other.json", record))
      assert message =~ ~s|id "2026-09-27-assign-bd-1-abc123" is not the file's name|
    end

    test "an id naming another act" do
      record = assign(%{"id" => "coord-2026-09-27-approve-bd-1"})

      assert [message] = errors(check(file(record), record))
      assert message =~ "names the act approve, and the record's act is assign"
    end

    test "a time that is not UTC to the second" do
      record = assign(%{"at" => "2026-09-27 10:00"})
      assert [message] = errors(check(file(record), record))
      assert message =~ ".at:"
    end

    test "a hand approval without the paths it covers" do
      record = %{
        "id" => "coord-2026-09-27-approve-fence-x",
        "act" => "approve",
        "at" => "2026-09-27T10:00:00Z",
        "by" => "the coordinator",
        "approval" => %{"by" => "the person", "quote" => "«Да»"},
        "decision" => "x"
      }

      assert [message] = errors(check(file(record), record))
      assert message =~ "missing required key paths"
    end

    test "a file that is not JSON, and one that is not an object" do
      dir = TestTmp.dir!("coordination")
      File.write!(Path.join(dir, "coord-2026-09-27-assign-a.json"), "{not json")
      File.write!(Path.join(dir, "coord-2026-09-27-assign-b.json"), "[]")

      findings = errors(Coordination.validate(dir: dir, schema: @schema))

      assert [broken, list] = findings
      assert broken =~ "coord-2026-09-27-assign-a.json: " and broken =~ "invalid JSON"

      assert list ==
               "coordination: coord-2026-09-27-assign-b.json: a coordination record is a JSON object"
    end

    test "a broken record reaches validate's profiles check" do
      record = Map.delete(assign(), "branch")

      findings =
        Profiles.validate(
          doc: nil,
          coordination: [records: [{file(record), record}], schema: @schema]
        )

      assert "coordination: #{file(record)}: missing required key branch" in errors(findings)
    end
  end

  describe "what Assign writes passes" do
    @tracked ~w(lib/harness/a.ex lib/memory/b.ex CLAUDE.md)

    defp plan(request, live) do
      doc = %{
        "profiles" => [
          %{
            "id" => "harness",
            "owns" => ["lib/harness/**"],
            "except" => [],
            "max_concurrent" => 2
          }
        ],
        "coordinator" => %{
          "description" => "held",
          "held" => [%{"glob" => "CLAUDE.md", "why" => "x"}]
        },
        "refused" => [],
        "add_only" => [],
        "per_epic" => [],
        "shared" => []
      }

      {:ok, plan} = Assign.plan(request, doc: doc, tracked: @tracked, fence: [], live: {live, 0})
      plan
    end

    @at "2026-09-27T10:00:00Z"

    test "an assignment, with a session, an acknowledged grant and an ADR" do
      plan =
        plan(
          %{
            epic: "bd-2",
            profile: "harness",
            session: "session_01",
            grants: ["CLAUDE.md"],
            ack: true,
            adrs: [31]
          },
          %{}
        )

      record = Assign.record("assign", plan, at: @at, nonce: "a1b2c3", branch: "claude/bd-2-work")

      assert record["acked"] == ["CLAUDE.md"]
      assert check(file(record), record) == []
    end

    test "a first assignment with no session yet" do
      plan = plan(%{epic: "bd-2", profile: "harness"}, %{})
      record = Assign.record("assign", plan, at: @at, nonce: "a1b2c3", branch: "claude/bd-2-work")

      assert record["session"] == nil
      assert check(file(record), record) == []
    end

    test "a reassignment, and the release that ends it" do
      first =
        Assign.record("assign", plan(%{epic: "bd-2", profile: "harness"}, %{}),
          at: @at,
          nonce: "a1b2c3",
          branch: "claude/bd-2-work"
        )

      head = String.duplicate("a", 40)
      plan = plan(%{epic: "bd-2", profile: "harness", reassign: true}, %{"bd-2" => first})

      again =
        Assign.record("reassign", plan,
          at: "2026-09-27T11:00:00Z",
          nonce: "d4e5f6",
          branch: "claude/bd-2-work-2",
          previous_head: head
        )

      released = Assign.release_record(again, at: "2026-09-27T12:00:00Z", nonce: "0a0b0c")

      assert check(file(again), again) == []
      assert check(file(released), released) == []
      assert released["act"] == "abandon"
    end
  end
end
