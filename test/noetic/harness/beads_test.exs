defmodule Noetic.Harness.BeadsTest do
  # `async: false`: every test here shells out to the real `bd` against the
  # real repository root, which other tests in this VM redirect with
  # `NOETIC_HARNESS_ROOT`.
  use ExUnit.Case, async: false

  alias Noetic.Harness.Beads

  # On the pack (`Noetic.Harness.Pack`), with `beads` switched on, because
  # what is tested is what the harness does when it is. "The bound" is tagged
  # `this_repository`: it is `bd` against this repository's database, and
  # its answer is only worth having there.
  @moduletag pack_integrations: ["beads"]
  setup {Noetic.Harness.Pack, :root}

  describe "what the callers do with it" do
    test "a stuck tracker and an absent one read differently in an injected session" do
      # `Attach` is the text spliced into every session. "no work graph" and
      # "the tracker is stuck" are different instructions to whoever reads it,
      # and before an earlier change they were the same sentence.
      # The engine's own source, found from this file rather than from the
      # harness root, which is the pack's here.
      source = File.read!(Path.expand("../../../lib/noetic/harness/attach.ex", __DIR__))

      assert source =~ ":timeout ->",
             "Attach.ready_line/0 does not distinguish a timeout, so a stuck `bd` reads as an " <>
               "absent one"

      assert source =~ "did not answer within"
    end

    test "telemetry names a stuck tracker in its unverified list" do
      # `collect/1`'s `unverified` is the list of sources that could not be
      # read. A source that hung belongs in it, and used to be reported as
      # "not answering" -- which reads as "not installed".
      summary = Noetic.Harness.Telemetry.collect([])

      assert is_list(summary["unverified"])

      for line <- summary["unverified"] do
        assert is_binary(line)
      end
    end
  end

  describe "the ready block is rendered here, from the brief JSON" do
    @payload ~s|[
      {"id":"bd-21v","title":"Qdrant client cannot authenticate","status":"open",
       "priority":1,"issue_type":"task"},
      {"id":"bd-arc","title":"(EPIC) The harness dispatches","status":"open",
       "priority":1,"issue_type":"epic"},
      {"id":"bd-arc.22","title":"(EPIC) The harness measures itself","status":"open",
       "priority":1,"issue_type":"epic","parent":"bd-arc"},
      {"id":"bd-h62.1","title":"Surface the numbers","status":"open","priority":2,
       "issue_type":"task",
       "dependencies":[{"type":"parent-child","depends_on_id":"bd-h62"}]}
    ]
    Showing 4 of 69 ready issues. Use --limit 0 for all, or --limit N to raise the cap.|

    test "the trailing human sentence does not stop it parsing" do
      # `--json` is not only JSON. `bd` prints a sentence after the array, and
      # `cmd/2` merges stderr into stdout, so a warning can land on either side
      # of it. The first version decoded the whole string, failed, and fell
      # back to the slow path — which is how this was found, because the
      # fallback announces itself.
      assert {:ok, rendered} = Beads.render_ready(@payload)
      refute rendered =~ "Showing 4 of 69"
      refute rendered =~ "--limit 0"
    end

    test "each row is one line, with id, priority, type and title" do
      {:ok, rendered} = Beads.render_ready(@payload)
      lines = String.split(rendered, "\n")

      assert length(lines) == 4
      assert Enum.at(lines, 0) == "○ bd-21v P1 Qdrant client cannot authenticate"

      assert Enum.at(lines, 1) == "○ bd-arc P1 [epic] (EPIC) The harness dispatches",
             "an epic is marked; a plain task is not, because most rows are tasks"
    end

    test "the parent survives, from either place bd puts it" do
      # The saving comes from `--brief`, which drops each row's free-form text.
      # It keeps the parent, in two forms: a `parent` field and a
      # `parent-child` entry under `dependencies`. Both are read, because one
      # is a convenience and neither is a documented contract.
      {:ok, rendered} = Beads.render_ready(@payload)

      assert rendered =~
               "bd-arc.22 P1 [epic] (EPIC) The harness measures itself ← (EPIC) The harness dispatches",
             "the parent's title is resolved locally when the parent is in the same result"

      assert rendered =~ "bd-h62.1 P2 Surface the numbers ← bd-h62",
             "a parent outside the result falls back to its id rather than vanishing"
    end

    test "something that is not the shape we render is an error, not a guess" do
      assert :error = Beads.render_ready("")
      assert :error = Beads.render_ready("bd: command not found")
      assert :error = Beads.render_ready(~s|{"id":"bd-1"}|)
      assert :error = Beads.render_ready(~s|[1, 2, 3]|)
    end

    test "an empty ready list renders as an empty block, not as an error" do
      assert {:ok, ""} = Beads.render_ready("[]")
    end
  end

  describe "the harness filing its own beads" do
    # Every function here used to read, so a weakness the
    # harness detected survived only as long as somebody read the telemetry
    # output. These tests are all against `fileable/2` and `cluster_key/1`,
    # which are pure — the `bd` calls live in `file/2`, and a guard that can
    # only be tested by writing to the real tracker is a guard nobody tests.

    defp cluster(overrides) do
      Map.merge(
        %{
          "shape" => "routing.corrected",
          "subject" => ".agents/registry/signals.json",
          "count" => 13,
          "of" => 13,
          "reading" => "routing was corrected 13 times",
          "change" => "Route the last three corrected titles again with `--explain`.",
          "actionable" => true
        },
        overrides
      )
    end

    test "the key survives a rewording, which is the whole requirement" do
      # Filing the same bead every run is worse than filing none, and the
      # reading is prose somebody will improve. The key is the shape and the
      # subject and nothing else.
      original = cluster(%{})

      reworded =
        cluster(%{
          "reading" => "the router keeps being corrected",
          "change" => "Narrow the signal that keeps producing them.",
          "count" => 14,
          "of" => 14
        })

      assert Beads.cluster_key(original) == Beads.cluster_key(reworded)
    end

    test "a different subject is a different key" do
      refute Beads.cluster_key(cluster(%{})) ==
               Beads.cluster_key(cluster(%{"subject" => ".agents/workflows"}))

      refute Beads.cluster_key(cluster(%{})) ==
               Beads.cluster_key(cluster(%{"shape" => "run.abandoned"}))
    end

    test "the key is readable and bounded" do
      # It goes on a bead a person reads, so the slug is first; the digest is
      # what stops two subjects that truncate to the same fifty characters from
      # sharing one.
      key = Beads.cluster_key(cluster(%{"subject" => String.duplicate("very-long-", 20)}))

      assert String.starts_with?(key, "hc-routing-corrected-")
      assert String.length(key) < 80
      assert key =~ ~r/-[0-9a-f]{6}$/
    end

    test "a cluster below the filing threshold is refused, above the reporting one" do
      # Three is enough to *report* a cluster — the number WF-020 names. A slot
      # in a queue a person reads costs more, and at three this repository's
      # telemetry would have filed two beads reading "3 lessons share the scope
      # <x> out of 37".
      assert Beads.file_threshold() > 3

      assert {:error, message} = Beads.fileable(cluster(%{"count" => 3}))
      assert message =~ "needs #{Beads.file_threshold()}"

      assert {:ok, _} = Beads.fileable(cluster(%{"count" => Beads.file_threshold()}))
    end

    test "a cluster that names no change is refused" do
      assert {:error, message} =
               Beads.fileable(cluster(%{"actionable" => false, "change" => nil}))

      assert message =~ "names no change"
    end

    test "a cluster with no evidence is refused" do
      # A bead the harness filed about a number it cannot show is worse than no
      # bead.
      assert {:error, m1} = Beads.fileable(cluster(%{"reading" => nil}))
      assert m1 =~ "no reading or no population"

      assert {:error, m2} = Beads.fileable(cluster(%{"of" => nil}))
      assert m2 =~ "no reading or no population"
    end

    test "a cluster implying a change to a protected artifact is refused" do
      # Constitution §23: a change to the constitution, the trust levels, a
      # gate policy or the security policy is a proposal a human opens. The
      # harness may still say so — as an evolution candidate that
      # `promotable?/1` refuses to land — but not as a task in the work queue.
      for shape <- ~w(gate.unavailable gate.failed lane.partial policy.drift trust.escalated) do
        assert {:error, message} = Beads.fileable(cluster(%{"shape" => shape, "count" => 20}))

        assert message =~ "constitution",
               "#{shape} was allowed to become a bead: #{message}"

        assert message =~ "--from-cluster",
               "#{shape} was refused without naming the path that is allowed"
      end
    end

    test "an ordinary cluster is not treated as protected" do
      # The other direction. A guard that refuses everything makes the whole
      # mechanism decorative.
      for shape <- ~w(routing.corrected run.abandoned step.uncertain memory.scope) do
        assert {:ok, _} = Beads.fileable(cluster(%{"shape" => shape, "count" => 20}))
      end
    end

    test "the bead carries the evidence and the way to re-measure it" do
      assert {:ok, attrs} = Beads.fileable(cluster(%{}), population: %{"runs" => 23})

      assert attrs.title =~ "13 of 13"
      assert attrs.design =~ "routing was corrected 13 times"
      assert attrs.design =~ "--explain"
      assert attrs.design =~ "23 run(s)"

      assert attrs.design =~ "telemetry --clusters",
             "the bead does not say how to check whether the weakness is still there"

      assert attrs.design =~ "--from-cluster",
             "the bead does not offer the candidate path, which is the other thing to do " <>
               "with a cluster"
    end

    test "a write gets a longer budget than a read, and the reason is on the record" do
      # `bd create` commits to Dolt and re-exports `.beads/issues.jsonl`, and
      # the read budget was not enough: the first real run created the bead and
      # then reported `{:error, "could not file the bead"}` about a bead that
      # existed, because the `timeout` wrapper killed the call after the write
      # had landed. A write killed mid-way is not a write that did nothing.
      assert Beads.write_timeout() > Beads.timeout() * 2
    end
  end

  describe "release/3 and assign/4" do
    # A stand-in `bd` first on the PATH, recording each argument on its own
    # line, so an empty `--assignee ""` is visible as an empty line rather
    # than lost in a joined string.
    setup do
      dir = Path.join(System.tmp_dir!(), "beads-release-#{System.os_time(:microsecond)}")
      File.mkdir_p!(dir)
      record = Path.join(dir, "record")
      bd = Path.join(dir, "bd")

      File.write!(bd, """
      #!/bin/sh
      for arg in "$@"; do printf '[%s]\\n' "$arg" >> '#{record}'; done
      exit "${FAKE_BD_EXIT:-0}"
      """)

      File.chmod!(bd, 0o755)
      path = System.get_env("PATH")
      System.put_env("PATH", dir <> ":" <> path)

      on_exit(fn ->
        System.put_env("PATH", path)
        System.delete_env("FAKE_BD_EXIT")
        File.rm_rf!(dir)
      end)

      {:ok, record: record}
    end

    test "clears the assignee, guarded by the profile that holds it", %{record: record} do
      assert :ok = Beads.release("bd-1", "harness", "released")

      assert File.read!(record) |> String.split("\n", trim: true) ==
               ~w([update] [bd-1] [--if-assignee] [harness] [--assignee] []) ++
                 ~w([--status] [open] [--remove-label] [profile:harness]) ++
                 ["[--append-notes]", "[released]"]
    end

    test "assign/4, reassigning, confirms the holder and moves the label", %{
      record: record
    } do
      assert :ok = Beads.assign("bd-1", "memory", "moved", "harness")

      assert File.read!(record) |> String.split("\n", trim: true) ==
               ~w([update] [bd-1] [--if-assignee] [harness] [--remove-label] [profile:harness]) ++
                 ~w([--assignee] [memory] [--status] [in_progress] [--add-label] [profile:memory]) ++
                 ["[--append-notes]", "[moved]"]
    end

    test "assign/4, first time, carries no guard", %{record: record} do
      assert :ok = Beads.assign("bd-1", "harness", "given")
      refute File.read!(record) =~ "--if-assignee"
    end

    test "a guard bd refuses (exit 13: the assignee is no longer the profile) is an error" do
      System.put_env("FAKE_BD_EXIT", "13")
      assert {:error, message} = Beads.release("bd-1", "harness", "released")
      assert message =~ "bd update bd-1"
    end
  end
end
