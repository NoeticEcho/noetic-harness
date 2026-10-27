defmodule Noetic.Harness.EpicBranchTest do
  @moduledoc """
  WF-021, the `handoff` lane and the handoff file: what a cloud
  worker's run is judged over, when it may finish, and what it records.

  Every test that touches git builds a repository of its own, with an
  `origin/develop` made by `update-ref` rather than a remote: the claim under
  test is which paths a merge-base diff yields, and a network or a bare
  remote would add nothing to it. The lanes that run are one-gate lanes whose
  command is `true` or `test -f marker`, in a copy of `policies/`, because
  `handoff` itself runs ci-local and takes minutes.
  """

  # async: false: `Run.start/1` writes into the fixture's `.agents/runs/`, and
  # `put_root/1` is per process but `on_exit` runs in another one.
  use ExUnit.Case, async: false

  alias Noetic.Harness.{Git, Run, Validation, Workflow}

  describe "what a WF-021 lane runs over" do
    setup :epic_repo

    test "merge-base(origin/develop, HEAD)..HEAD, minus the run and the handoff", %{root: root} do
      # The epic's own work, committed before its run opened.
      commit(root, %{"lib/a.ex" => "defmodule A, do: nil\n"})

      epic = start("WF-021")
      wf002 = start("WF-002")

      commit(root, %{
        ".agents/runs/r.json" => "{}\n",
        ".agents/handoff/bd-x.json" => "{}\n"
      })

      # develop moves on, and the branch merges it, as the sync step says.
      develop_head = advance_develop(root, %{"develop-only.txt" => "not the epic's\n"})
      git!(root, ["merge", "-q", "--no-edit", "origin/develop"])

      # Uncommitted and untracked: not in a committed-only set.
      File.write!(Path.join(root, "README"), "edited, not committed\n")
      File.write!(Path.join(root, "lib/b.ex"), "never added\n")

      {paths, from} = Run.lane_paths(epic)

      assert paths == ["lib/a.ex"],
             "committed before the run opened, so `changed since base` would have missed it; " <>
               "and develop's own file, merged in, is not the epic's change"

      assert from =~
               "merge-base(origin/develop, HEAD)..HEAD, minus .agents/runs/, .agents/handoff/"

      assert from =~ "merge-base #{develop_head}"

      # Any other workflow is exactly as it was.
      assert Run.lane_paths(wf002) ==
               {elem(Git.changed_since(wf002["base"]), 1),
                "changed since #{String.slice(wf002["base"], 0, 12)}"}

      {old_paths, _} = Run.lane_paths(wf002)
      assert "develop-only.txt" in old_paths, "the reason WF-021 has a rule of its own"
      refute "lib/a.ex" in old_paths
    end

    test "with no origin/develop: no paths, every gate, and the sentence says why", %{
      root: root
    } do
      git!(root, ["update-ref", "-d", "refs/remotes/origin/develop"])
      epic = start("WF-021")

      assert {[], from} = Run.lane_paths(epic)
      assert from =~ "could not answer merge-base(origin/develop, HEAD)"
      assert from =~ "every gate"
    end

    test "a rename is both its old path and its new one", %{root: root} do
      # The review of an earlier change removed `--no-renames` from
      # `Git.committed_between/2` and every other test still passed. Without
      # it a rename is its new path alone, and merge-check's scope check would
      # never see that a file left the epic's scope by being moved out of it.
      commit(root, %{"lib/old_name.ex" => "defmodule Old, do: nil\n"})
      git!(root, ["update-ref", "refs/remotes/origin/develop", "HEAD"])
      git!(root, ["mv", "lib/old_name.ex", "lib/new_name.ex"])
      git!(root, ["commit", "-q", "-m", "rename"])

      {paths, _from} = Run.lane_paths(start("WF-021"))

      assert Enum.sort(paths) == ["lib/new_name.ex", "lib/old_name.ex"]
    end

    test "explicit paths still win" do
      epic = start("WF-021")
      assert {["x.ex"], "given"} == Run.lane_paths(epic, paths: ["x.ex"])
    end
  end

  describe "a WF-021 finish refuses a tree that is not its head" do
    setup :epic_repo

    test "clean but for the run and the handoff is clean", %{root: root} do
      commit(root, %{".agents/handoff/bd-x.json" => "{}\n"})
      epic = start("WF-021")
      File.write!(Path.join(root, ".agents/handoff/bd-x.json"), ~s({"status": "working"}\n))

      assert :ok == Run.committed_tree(epic)
    end

    test "an untracked file is refused, and named", %{root: root} do
      epic = start("WF-021")
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "lib/new.ex"), "never added\n")

      assert {:error, message} = Run.committed_tree(epic)
      assert message =~ "commit first — the lane's verdict is recorded against a head"
      assert message =~ "  lib/new.ex"
      refute message =~ "  .agents/runs/", "the run's own file is exempt"
    end

    test "a modified tracked file is refused", %{root: root} do
      epic = start("WF-021")
      File.write!(Path.join(root, "README"), "edited\n")

      assert {:error, message} = Run.committed_tree(epic)
      assert message =~ "  README"
    end

    test "every other workflow is left alone", %{root: root} do
      File.write!(Path.join(root, "README"), "edited\n")
      assert :ok == Run.committed_tree(start("WF-002"))
    end

    test "finish says so before any lane runs, and records no attempt", %{root: root} do
      epic = all_done(start("WF-021"))
      File.write!(Path.join(root, "README"), "edited\n")

      assert {:error, message} = Run.finish(epic["id"])
      assert message =~ "commit first"

      {:ok, stored} = Run.fetch(epic["id"])
      assert stored["status"] == "open"
      refute Map.has_key?(stored, "finish_attempts"), "the lane never ran"
    end
  end

  describe "run --finish records the head it ran at" do
    setup [:epic_repo, :fast_lanes]

    test "a WF-021 run, in `gates` and in its attempt", %{root: root} do
      commit(root, %{"lib/a.ex" => "defmodule A, do: nil\n"})
      {:ok, head} = Git.head_sha()
      epic = all_done(start("WF-021", lane: "epic-fast"))

      assert {:ok, closed} = Run.finish(epic["id"])
      assert closed["status"] == "done"
      assert closed["gates"]["head"] == head
      assert is_integer(closed["gates"]["seconds"]) and closed["gates"]["seconds"] >= 0
      assert closed["gates"]["paths"] == ["lib/a.ex"]
      assert closed["gates"]["paths_from"] =~ "merge-base"

      assert [%{"head" => ^head, "status" => "passed", "tree" => tree}] =
               closed["finish_attempts"]

      assert is_binary(tree), "head is beside the tree fingerprint, not instead of it"
    end

    test "any workflow, a failed attempt included", %{root: root} do
      run = all_done(start("WF-003", lane: "epic-flaky"))
      {:ok, head} = Git.head_sha()

      assert {:error, _} = Run.finish(run["id"], paths: [])
      File.write!(Path.join(root, "marker"), "")
      assert {:ok, closed} = Run.finish(run["id"], paths: [])

      assert closed["gates"]["head"] == head

      assert Enum.map(closed["finish_attempts"], &{&1["status"], &1["head"]}) ==
               [{"failed", head}, {"passed", head}]
    end

    test "the CLI prints it, so the handoff copies it from there", %{root: root} do
      commit(root, %{"lib/a.ex" => "defmodule A, do: nil\n"})
      {:ok, head} = Git.head_sha()
      epic = all_done(start("WF-021", lane: "epic-fast"))

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Harness.Run.run(["--run", epic["id"], "--finish"])
        end)

      assert out =~ "ran at #{head} in "
      assert out =~ "over 1 path(s): merge-base(origin/develop, HEAD)..HEAD"
    end
  end

  describe "handoff validation" do
    setup :handoff_root

    test "a valid handoff passes; the schema and the two cross-checks catch the rest", %{
      handoffs: dir
    } do
      working = %{
        "epic" => "bd-ok",
        "profile" => "harness",
        "session" => "session_01ABC",
        "branch" => "claude/bd-ok-the-work",
        "status" => "working",
        "children" => [%{"id" => "bd-ok.1", "outcome" => "open"}]
      }

      ready =
        Map.merge(working, %{
          "epic" => "bd-ready",
          "branch" => "claude/bd-ready-the-work",
          "status" => "ready",
          "base_develop" => String.duplicate("a", 40),
          "children" => [
            %{
              "id" => "bd-ready.1",
              "outcome" => "done",
              "commits" => [String.duplicate("b", 40)]
            },
            %{"id" => "bd-ready.2", "outcome" => "reparented", "to" => "bd-other"}
          ],
          "discovered" => [%{"text" => "the HUD leaks a listener", "paths" => ["x.ts"]}],
          "questions" => [%{"text" => "which ADR number?", "blocking" => false}],
          "shared_change_requests" => [%{"text" => "a new test tag", "paths" => ["mix.exs"]}],
          "runs" => ["run-2026-09-24-wf-021-bd-ready-0a1b2c3d"],
          "lane" => %{
            "verdict" => "passed",
            "seconds" => 612,
            "head" => String.duplicate("c", 40),
            "gates" => [
              %{"id" => "ci.local", "outcome" => "passed"},
              %{"id" => "harness.test", "outcome" => "skipped"}
            ]
          }
        })

      write(dir, "bd-ok", working)
      write(dir, "bd-ready", ready)
      write(dir, "bd-nostatus", working |> Map.put("epic", "bd-nostatus") |> Map.delete("status"))
      write(dir, "bd-x", Map.put(working, "epic", "bd-y"))
      write(dir, "bd-unquoted", ready |> Map.put("epic", "bd-unquoted") |> Map.delete("lane"))

      write(
        dir,
        "bd-badprofile",
        working |> Map.merge(%{"epic" => "bd-badprofile", "profile" => "ops"})
      )

      {:ok, findings} = Validation.run([:schemas])
      about = fn stem -> for {:error, m} <- findings, m =~ "handoff/#{stem}.json", do: m end

      assert about.("bd-ok") == []
      assert about.("bd-ready") == []

      assert [missing] = about.("bd-nostatus")
      assert missing =~ "missing required key status"

      assert [misnamed] = about.("bd-x")
      assert misnamed =~ "says epic bd-y"

      assert [unquoted] = about.("bd-unquoted")
      assert unquoted =~ "ready with no lane"

      assert [profile] = about.("bd-badprofile")
      assert profile =~ ~s("ops" is not one of)

      refute Enum.any?(findings, &match?({:warning, "handoff" <> _}, &1)),
             "the schema uses only what the evaluator implements"
    end

    test "what the schema's descriptions promise is enforced, not only written", %{
      handoffs: dir
    } do
      # An independent review of an earlier change wrote each of these and watched
      # `validate` pass all four, because the evaluator has no `if`/`then` and
      # only the stem and the missing lane were cross-checked.
      base = %{
        "profile" => "harness",
        "session" => "session_01ABC",
        "status" => "ready",
        "children" => [%{"id" => "bd-z.1", "outcome" => "done"}],
        "lane" => %{
          "verdict" => "passed",
          "seconds" => 1,
          "head" => String.duplicate("c", 40),
          "gates" => []
        }
      }

      handoff = fn epic, changes ->
        base
        |> Map.merge(%{"epic" => epic, "branch" => "claude/#{epic}-x"})
        |> Map.merge(changes)
      end

      write(dir, "bd-good", handoff.("bd-good", %{}))

      write(
        dir,
        "bd-openready",
        handoff.("bd-openready", %{"children" => [%{"id" => "bd-z.9", "outcome" => "open"}]})
      )

      write(
        dir,
        "bd-failedready",
        handoff.("bd-failedready", %{"lane" => Map.put(base["lane"], "verdict", "failed")})
      )

      write(
        dir,
        "bd-nonote",
        handoff.("bd-nonote", %{
          "status" => "working",
          "children" => [%{"id" => "bd-z.2", "outcome" => "deferred"}]
        })
      )

      write(
        dir,
        "bd-noto",
        handoff.("bd-noto", %{
          "status" => "working",
          "children" => [%{"id" => "bd-z.3", "outcome" => "reparented"}]
        })
      )

      # PCRE's `$` also matches before a final newline; JSON Schema's is
      # ECMA-262's and does not. A head copied with its newline is not a sha.
      write(
        dir,
        "bd-newline",
        handoff.("bd-newline", %{
          "lane" => Map.put(base["lane"], "head", String.duplicate("c", 40) <> "\n")
        })
      )

      {:ok, findings} = Validation.run([:schemas])
      about = fn stem -> for {:error, m} <- findings, m =~ "handoff/#{stem}.json", do: m end

      assert about.("bd-good") == []
      assert [open] = about.("bd-openready")
      assert open =~ "child bd-z.9 still open"
      assert [failed] = about.("bd-failedready")
      assert failed =~ "ready on a failed lane"
      assert [note] = about.("bd-nonote")
      assert note =~ "bd-z.2 is deferred with no note"
      assert [to] = about.("bd-noto")
      assert to =~ "bd-z.3 is reparented with no `to`"
      assert [newline] = about.("bd-newline")
      assert newline =~ "head"
    end

    test "no handoff directory at all is not a finding", %{handoffs: dir} do
      File.rm_rf!(dir)
      {:ok, findings} = Validation.run([:schemas])
      refute Enum.any?(findings, fn {_, m} -> m =~ "handoff" end)
    end
  end

  # ---- fixtures --------------------------------------------------------------

  defp start(workflow, opts \\ []) do
    {:ok, run} =
      Run.start(
        [workflow: workflow, title: "epic test #{System.unique_integer([:positive])}"] ++ opts
      )

    run
  end

  defp all_done(run) do
    {:ok, workflow} = Workflow.fetch(run["workflow"])

    for step <- workflow["steps"], not Map.get(step, "optional", false) do
      {:ok, _} = Run.record(run["id"], step: step["id"], outcome: "done", evidence: ["synthetic"])
    end

    run
  end

  # A repository whose `.agents/` is the pack's (`Noetic.Harness.Pack`) entry
  # by entry, except `runs/` and `handoff/`: real directories, so that a test
  # can commit into them, and the two prefixes WF-021 exempts. Everything linked (or copied, by
  # `fast_lanes/1`) is excluded from git by name, so the tree is clean when a
  # test says it is. On `claude/bd-x-test`, branched from an `origin/develop`
  # that is a ref and not a remote.
  defp epic_repo(_context) do
    real = Noetic.Harness.Pack.source()

    root =
      Noetic.Harness.TestTmp.path("harness-epic") |> Noetic.Harness.Pack.populate(tree: false)

    linked = Noetic.Harness.Pack.linked()

    git!(root, ["init", "-q", "-b", "develop"])
    git!(root, ["config", "user.email", "test@example.invalid"])
    git!(root, ["config", "user.name", "test"])
    git!(root, ["config", "commit.gpgsign", "false"])

    File.write!(
      Path.join([root, ".git", "info", "exclude"]),
      Enum.map_join(linked, "", &"/.agents/#{&1}\n")
    )

    commit(root, %{"README" => "the starting point\n"})
    git!(root, ["update-ref", "refs/remotes/origin/develop", "HEAD"])
    git!(root, ["switch", "-q", "-c", "claude/bd-x-test"])

    previous = Noetic.Harness.root_override()
    Noetic.Harness.put_root(root)

    on_exit(fn ->
      if previous,
        do: Noetic.Harness.put_root(previous),
        else: Noetic.Harness.delete_root()

      File.rm_rf!(root)
    end)

    {:ok, root: root, real: real}
  end

  # `policies/` copied over its link, with two lanes that answer in
  # milliseconds. Still excluded from git, by the same line.
  defp fast_lanes(%{root: root, real: real}) do
    policies = Path.join([root, ".agents", "policies"])
    File.rm!(policies)
    File.cp_r!(Path.join(real, "policies"), policies)

    gates_path = Path.join(policies, "gates.json")
    {:ok, gates} = Noetic.Harness.Loader.load(gates_path)

    gate = fn id, command ->
      %{
        "id" => id,
        "name" => id,
        "kind" => "command",
        "command" => command,
        "requires" => [],
        "severity" => "blocking"
      }
    end

    gates =
      gates
      |> Map.update!("lanes", fn lanes ->
        lanes ++
          [
            %{"id" => "epic-fast", "doc" => "test", "gates" => ["always"]},
            %{"id" => "epic-flaky", "doc" => "test", "gates" => ["marker-present"]}
          ]
      end)
      |> Map.update!("gates", fn defs ->
        defs ++ [gate.("always", "true"), gate.("marker-present", "test -f marker")]
      end)

    File.write!(gates_path, Noetic.Harness.Loader.pretty!(gates))
    :ok
  end

  # The pack's `.agents/`, linked, with a `handoff/` of the test's own.
  defp handoff_root(_context) do
    root = Noetic.Harness.TestTmp.path("harness-handoff") |> Noetic.Harness.Pack.populate()
    dir = Path.join([root, ".agents", "handoff"])

    previous = Noetic.Harness.root_override()
    Noetic.Harness.put_root(root)

    on_exit(fn ->
      if previous,
        do: Noetic.Harness.put_root(previous),
        else: Noetic.Harness.delete_root()

      File.rm_rf!(root)
    end)

    {:ok, handoffs: dir}
  end

  defp write(dir, stem, handoff),
    do: File.write!(Path.join(dir, "#{stem}.json"), Noetic.Harness.Loader.pretty!(handoff))

  defp advance_develop(root, files) do
    git!(root, ["switch", "-q", "develop"])
    commit(root, files)
    git!(root, ["update-ref", "refs/remotes/origin/develop", "HEAD"])
    sha = root |> git!(["rev-parse", "HEAD"]) |> String.trim()
    git!(root, ["switch", "-q", "claude/bd-x-test"])
    sha
  end

  defp commit(root, files) do
    for {name, content} <- files do
      path = Path.join(root, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      git!(root, ["add", "--", name])
    end

    git!(root, ["commit", "-q", "-m", "add #{Enum.join(Map.keys(files), ", ")}"])
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end
end
