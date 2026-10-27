defmodule Noetic.Harness.GatesTest do
  @moduledoc """
  The fourth outcome. A lane that reports green with an unavailable gate in it
  is the single most damaging thing this harness could do, so most of these
  tests are about `unavailable`.

  The engine's tests run on the pack's gate policy (`Noetic.Harness.Pack`).
  Those tagged `this_repository` are about this repository's own policy —
  that every lane it declares resolves, and that its shell gate exists and
  guards its scripts — and read it.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Fixture, Gates, Policy}

  setup {Noetic.Harness.Pack, :root}

  test "lanes expand transitively" do
    {:ok, full} = Gates.expand("full")
    {:ok, release} = Gates.expand("release")

    assert Enum.all?(full, &(&1 in release)), "release contains full"
    assert "gitleaks" in release
    refute "gitleaks" in full
  end

  @tag this_repository: true
  test "every lane expands to at least one real gate" do
    {:ok, doc} = Policy.gates()
    gate_ids = MapSet.new(doc["gates"], & &1["id"])

    for lane <- doc["lanes"] do
      {:ok, expanded} = Gates.expand(lane["id"])
      assert expanded != [], "#{lane["id"]} expands to nothing"
      assert Enum.all?(expanded, &MapSet.member?(gate_ids, &1))
    end
  end

  test "an unknown lane is an error rather than an empty run" do
    assert {:error, message} = Gates.expand("imaginary")
    assert message =~ "no lane named"
  end

  test "a gate with a path filter applies only when a path matches" do
    {:ok, applied} = Gates.applicable("focused", ["apps/acme_web/assets/js/app.ts"])
    ids = Enum.map(applied, & &1["id"])

    assert "assets.check" in ids
    refute "typeql.check" in ids
  end

  test "with no paths known, every gate applies — not knowing what changed is not a reason to skip" do
    {:ok, applied} = Gates.applicable("focused", [])
    ids = Enum.map(applied, & &1["id"])

    assert "assets.check" in ids
    assert "typeql.check" in ids
  end

  test "a gate whose tool is absent reports unavailable, never passed" do
    {:ok, {status, results}} = Gates.run("focused", paths: ["schema.tql"], only: ["typeql.check"])

    [result] = results
    assert result.outcome == :unavailable
    assert result.detail =~ "not available"
    assert status == :partial
  end

  test "a lane containing an unavailable blocking gate is partial, not passed" do
    results = [
      %{
        id: "a",
        name: "a",
        kind: "command",
        severity: "blocking",
        outcome: :passed,
        command: nil,
        detail: "",
        duration_ms: 0
      },
      %{
        id: "b",
        name: "b",
        kind: "command",
        severity: "blocking",
        outcome: :unavailable,
        command: nil,
        detail: "",
        duration_ms: 0
      }
    ]

    assert Gates.status(results) == :partial
  end

  test "a failure outranks an unavailable" do
    results = [
      %{
        id: "a",
        name: "a",
        kind: "command",
        severity: "blocking",
        outcome: :failed,
        command: nil,
        detail: "",
        duration_ms: 0
      },
      %{
        id: "b",
        name: "b",
        kind: "command",
        severity: "blocking",
        outcome: :unavailable,
        command: nil,
        detail: "",
        duration_ms: 0
      }
    ]

    assert Gates.status(results) == :failed
  end

  test "an advisory gate does not decide the lane" do
    results = [
      %{
        id: "a",
        name: "a",
        kind: "command",
        severity: "advisory",
        outcome: :failed,
        command: nil,
        detail: "",
        duration_ms: 0
      }
    ]

    assert Gates.status(results) == :passed
  end

  test "a review or evidence gate is unavailable to a command runner and says whose it is" do
    {:ok, {_status, results}} = Gates.run("protected", only: ["human.approval"], dry_run: true)

    [result] = results
    assert result.outcome == :unavailable
    assert result.detail =~ "human_architect"
  end

  test "the summary names what is unverified rather than listing only passes" do
    {:ok, {status, results}} = Gates.run("focused", paths: ["schema.tql"], only: ["typeql.check"])
    summary = Gates.summarise("focused", {status, results})

    assert summary =~ "partial"
    assert summary =~ "unverified:"
    assert summary =~ "typeql.check"
  end

  @tag :fixture
  test "a command gate actually runs its command" do
    Fixture.with_tree(Fixture.minimal(), fn _root ->
      {:ok, {status, [result]}} = Gates.run("fast", paths: [])

      assert result.id == "compile"
      assert result.outcome == :passed
      assert status == :passed
    end)
  end

  @tag :fixture
  test "a failing command gate fails the lane and keeps the output" do
    tree =
      put_in(Fixture.minimal()["policies/gates.json"]["gates"], [
        %{
          "id" => "compile",
          "name" => "compile",
          "kind" => "command",
          "command" => "echo 'it broke' >&2; exit 1",
          "requires" => [],
          "severity" => "blocking"
        }
      ])

    Fixture.with_tree(tree, fn _root ->
      {:ok, {status, [result]}} = Gates.run("fast", paths: [])

      assert status == :failed
      assert result.outcome == :failed
      assert result.detail =~ "it broke"
    end)
  end

  describe "options that were not really given" do
    test "`paths: nil` means no paths, not an empty enumerable" do
      # A caller building its options with `Keyword.take/2` hands over
      # `[paths: nil]` without meaning to. This used to reach `applies?/2` as a
      # nil to enumerate and crashed the lane instead of running it — found by
      # the run ledger, on its own first real `--finish`.
      assert {:ok, {_status, results}} = Gates.run("fast", paths: nil, dry_run: true)
      assert results != []
    end

    test "`paths: nil` behaves as no paths in a lane whose gates filter on paths" do
      # The test above passes without the fix, because `fast` has no
      # gate with `applies_when`, and only such a gate enumerates the paths a
      # nil crashed on. `focused` has five; the assertion below says so rather
      # than trusting the policy file to keep them.
      {:ok, ids} = Gates.expand("focused")
      {:ok, defs} = Noetic.Harness.Policy.gates_by_id()

      assert Enum.any?(ids, &match?(%{"applies_when" => [_ | _]}, defs[&1])),
             "focused has no path-filtered gate any more, so this test proves nothing"

      # Both calls below default to `git status`, and they used to
      # ask it of the repository itself — the working tree every other
      # `async: true` module runs against. `ValidationTest` plants a row in the
      # tracked `.agents/policies/failure.json` and restores it afterwards, so
      # on a clean CI checkout the first call saw one changed path under
      # `.agents/` (five gates) and the second saw none (all nine), on two
      # runs in five. The comparison was between two moments, not between two
      # options. So the tree is this test's own, and its change set is known.
      changed = "apps/acme_web/assets/js/world/scene.ts"

      with_changed_tree(changed, fn ->
        assert Noetic.Harness.Git.changed_paths() == {:ok, [changed]},
               "the fixture tree does not report the one change it was built with"

        # A change set that selected every gate could not tell "defaulted to
        # the working tree" from "treated nil as an empty list", which also
        # applies every gate. This one has to select strictly fewer.
        {:ok, selected} = Gates.applicable("focused", [changed])
        {:ok, everything} = Gates.applicable("focused", [])
        selected = Enum.map(selected, & &1["id"])

        assert length(selected) < length(everything),
               "#{changed} selects every focused gate, so the comparison below proves nothing"

        assert {:ok, {_, given_nil}} = Gates.run("focused", paths: nil, dry_run: true)
        assert {:ok, {_, not_given}} = Gates.run("focused", dry_run: true)
        assert Enum.map(given_nil, & &1.id) == Enum.map(not_given, & &1.id)
        assert Enum.map(not_given, & &1.id) == selected
      end)
    end
  end

  # A repository of the calling test's own: a copy of the real gate and tool
  # policy, committed, and one tracked file modified — so `git status` answers
  # exactly `[changed]` whatever the rest of the suite is doing to the working
  # tree. The root override is per process (`Noetic.Harness.put_root/1`), which
  # is what lets this module stay `async: true`.
  defp with_changed_tree(changed, fun) do
    policies = Noetic.Harness.agents_path("policies")
    root = Noetic.Harness.TestTmp.path("gates-tree")
    File.mkdir_p!(Path.join(root, ".agents/policies"))

    for file <- ~w(gates.json tools.json) do
      File.cp!(Path.join(policies, file), Path.join([root, ".agents/policies", file]))
    end

    File.mkdir_p!(Path.join(root, Path.dirname(changed)))
    File.write!(Path.join(root, changed), "// before\n")

    git!(root, ["init", "-q"])
    git!(root, ["add", "--", ".agents/policies", changed])

    git!(root, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-q",
      "--no-verify",
      "-m",
      "fixture"
    ])

    File.write!(Path.join(root, changed), "// after\n")

    previous = Noetic.Harness.put_root(root)

    try do
      fun.()
    after
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
      File.rm_rf!(root)
    end
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed in the fixture: #{output}"
  end

  describe "what a failing gate reports" do
    test "the excerpt keeps the tail, because that is where a test runner puts the answer" do
      # Measured twice on 2026-09-22: a `mix cmd --app noetic_harness mix test`
      # failure opens with a deprecation warning and a six-line stack trace
      # from `Mix.Tasks.Cmd`, so a report truncated to the first 400 characters
      # said nothing about which test failed and the lane had to be reproduced
      # by hand to find out what it meant.
      noise = String.duplicate("warning: the --app in mix cmd is deprecated.\n", 200)
      answer = "1) test the thing (SomeTest)\n   Assertion failed\nResult: 531/532 passed"

      report =
        Noetic.Harness.Gates.summarise(
          "focused",
          {:failed,
           [
             %{
               id: "test.touched",
               severity: "blocking",
               outcome: :failed,
               command: "mix test",
               detail: noise <> answer,
               duration_ms: 1
             }
           ]}
        )

      assert report =~ "Result: 531/532 passed"
      assert report =~ "1) test the thing"
      assert report =~ "bytes elided"

      # And the head is still there, because a gate that could not start at all
      # says so in its first line and has no tail worth reading.
      assert report =~ "deprecated"
    end
  end
end
