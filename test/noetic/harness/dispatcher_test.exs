defmodule Noetic.Harness.DispatcherTest do
  @moduledoc """
  The dispatcher is the first thing in this repository that lets an agent act,
  so it is tested for what it refuses. Every refusal here has been checked to
  fail without its guard — a ceiling that is never reached by the test that
  claims to reach it is a test about nothing, and a design decision makes the fence's
  tests this module's readiness criterion.

  The tests go through WF-002 and the registry as the pack has them
  (`Noetic.Harness.Pack`), in a git repository of each test's own. They used
  to go through this repository's, on the grounds that the question worth
  answering was whether dispatch agrees with the workflow this repository has; that
  is a question about the registry, and `WorkflowTest` asks it. What these
  ask is what dispatch refuses, which does not change with the registry, and
  a worktree of the pack is a few hundred files where one of this repository
  was five thousand.
  """

  # async: false: these tests write run entries under `.agents/runs/`, some of
  # them repoint the dispatch adapter, which is application-global, and one
  # puts a stand-in `claude` on `PATH`, which is VM-global.
  use ExUnit.Case, async: false

  alias Noetic.Harness.{Adapter, Dispatcher, Policy, Run, Workspace}

  # A file the pack's tree has and its fence does not name.
  @clear "client/world/channel.ts"
  @fenced ".agents/policies/gates.json"
  # Fenced *and* marked `exemptible` in `.agents/policies/evaluators.json`: one
  # of the ten harness modules a scoring attempt may be exempted from. The
  # distinction is the whole of `Fence.unexemptible/1` — `@fenced` above is a
  # policy, which says what passing means, and is never exemptible.
  @exemptible "apps/noetic_harness/lib/noetic/harness/gates.ex"

  # The agent's writes are real files in a real worktree rather than a list of
  # path strings handed to the dispatcher. The first version of these tests
  # passed `paths:` and was testing the test's idea of what had changed; this
  # one makes the agent change something and lets git answer.
  defmodule WritingAdapter do
    @moduledoc "Writes whatever the test put in the process dictionary, into its own cwd."
    def call(_prompt, opts) do
      for {path, content} <- Process.get(:dispatch_writes, []) do
        full = Path.join(opts[:cwd], path)
        File.mkdir_p!(Path.dirname(full))
        # `:raw`: on the workstation a plain `File.write!/2` here waited 60 s
        # on OTP's file server under load.
        File.write!(full, content, [:raw])
      end

      {:ok, %{wrote: Enum.map(Process.get(:dispatch_writes, []), &elem(&1, 0)), cwd: opts[:cwd]}}
    end

    def available?, do: :ok
  end

  defp writes(pairs), do: Process.put(:dispatch_writes, pairs)

  # An adapter that says which model it actually used — what `jido`'s local
  # planner does — and what that cost in tokens.
  defmodule ModelReportingAdapter do
    @moduledoc false
    def available?, do: :ok

    def call(_prompt, _opts) do
      {:ok,
       %{
         output: "listed",
         model: "ollama/reported",
         cost_usd: 0.0,
         usage: %{"input_tokens" => 40, "output_tokens" => 8}
       }}
    end
  end

  # One model at every trust, like `jido`'s local planner.
  defmodule OneModelAdapter do
    @moduledoc false
    def available?, do: :ok
    def runs_model(_requested), do: "ollama/one"
    def call(_prompt, _opts), do: {:ok, %{output: "x", model: "ollama/one"}}
  end

  # One worktree per test, taken away afterwards whether the test passed or not.
  defp workspace!(id) do
    {:ok, workspace} = Workspace.open(id)
    on_exit(fn -> Workspace.close(workspace, discard: true) end)
    workspace
  end

  defmodule ChildRunAdapter do
    @moduledoc """
    An agent that opens a run of its own, which is what an agent handed this
    harness does. It records the run it opened so the test can read its parent.
    """
    def available?, do: :ok

    def call(_prompt, _opts) do
      {:ok, child} =
        Noetic.Harness.Run.start(
          workflow: "WF-002",
          title: "#{System.os_time(:millisecond)}-#{:rand.uniform(99_999)} a run the agent opened"
        )

      Process.put(:child_run, child)
      {:ok, %{opened: child["id"]}}
    end
  end

  defmodule RaisingAdapter do
    @moduledoc """
    An adapter that must never be reached.

    "`prepare/2` refused" and "the agent ran and produced nothing" are
    different facts, and asserting on a refusal tuple alone cannot tell them
    apart — a dispatcher that called the agent and *then* refused would pass
    that assertion while having already spent the money and made the edits.
    """
    def available?, do: :ok
    def call(_prompt, _opts), do: raise("the adapter was called after a refusal")
  end

  # A run id is a slug of its title, and a run that dispatches gets a branch of
  # that name which outlives this VM. `System.unique_integer/1` restarts low in
  # every VM, so a suite killed before its cleanup left a branch the next suite
  # collided with. A timestamp does not repeat across VMs; it goes
  # *first* because the slug is cut at forty characters and a suffix can be cut.
  defp unique, do: "#{System.os_time(:millisecond)}-#{:rand.uniform(99_999)}"

  # A dispatch its timeout kills leaves `NOETIC_HARNESS_PARENT_RUN`
  # naming a deleted run, and every later `Run.start/1` refused: one stall was
  # 99 failures of this module's setup. `DispatchExport` puts it back. The
  # worktrees go on tmpfs (`TmpfsWorktrees`); the test about where they live
  # keeps the default root.
  setup_all {Noetic.Harness.TmpfsWorktrees, :root}
  setup {Noetic.Harness.DispatchExport, :guard}
  setup {Noetic.Harness.Pack, :git_root}
  setup {Noetic.Harness.TmpfsWorktrees, :use_root}

  setup do
    title = "#{unique()} dispatcher test"
    {:ok, run} = Run.start(workflow: "WF-002", title: title, agent: "test")

    on_exit(fn ->
      Noetic.Harness.agents_path("runs") |> Path.join("#{run["id"]}.json") |> File.rm()
    end)

    {:ok, id: run["id"]}
  end

  defp artifact!(kind) do
    {:ok, envelope} =
      Noetic.Harness.Artifact.new(%{
        kind: kind,
        created_by: "test",
        unverified: ["this envelope exists to be attached"]
      })

    {:ok, path} = Noetic.Harness.Artifact.write(envelope)
    on_exit(fn -> File.rm(path) end)
    envelope["id"]
  end

  defp adapter(module) do
    previous = Application.get_env(:noetic_harness, :dispatch_adapter)
    Application.put_env(:noetic_harness, :dispatch_adapter, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:noetic_harness, :dispatch_adapter, previous),
        else: Application.delete_env(:noetic_harness, :dispatch_adapter)
    end)
  end

  # A `claude` of the test's own, first on `PATH`, for the one test that
  # resolves `claude_code` through the policy. `ClaudeCode.available?/0` is
  # `System.find_executable("claude")` and nothing else, so without this the
  # test asserted that the machine had Claude Code installed: green on the
  # workstation, red on every GitHub run since v0.5.0.
  #
  # It exits 97 if anything runs it. `prepare/2` must not — preparing is not
  # dispatching — and a stand-in that answered would hide one that started to.
  # `AdapterTest` has the same helper and says more.
  defp claude_on_path!(tmp) do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)

    fake = Path.join(bin, "claude")

    File.write!(fake, """
    #!/bin/sh
    echo "stand-in claude from #{inspect(__MODULE__)}: preparing a dispatch must not run it" >&2
    exit 97
    """)

    File.chmod!(fake, 0o755)

    original = System.get_env("PATH")
    System.put_env("PATH", Enum.join([bin | List.wrap(original)], ":"))

    on_exit(fn ->
      if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
    end)

    fake
  end

  defp rules(refusals), do: refusals |> Enum.map(& &1.rule) |> Enum.sort()

  describe "the run an agent opens while it is being dispatched" do
    test "is a child of the dispatching run, not a sibling", %{id: id} do
      # Nothing in this repository wrote a non-`nil` `parent_run` outside the
      # suite until this: the depth ceiling bounded a tree that could not be
      # built, and `Evolution`'s independence walk — the one that refuses a
      # candidate scored by a run its own run dispatched — walked a chain of
      # length one. Found by an independent review, which observed that the
      # laundering path the policy describes could not be taken *and* that the
      # path which could, `noetic-harness run --start`, was refused by nothing.
      adapter(ChildRunAdapter)
      workspace = workspace!(id)
      Process.delete(:child_run)

      assert {:ok, _} = Dispatcher.attempt(id, "open a run", workspace: workspace)

      child = Process.get(:child_run)
      on_exit(fn -> Run.delete(child["id"]) end)

      assert child["parent_run"] == id
      assert Run.ancestor?(id, child["id"])
    end

    test "and the export does not outlive the call", %{id: id} do
      adapter(ChildRunAdapter)
      workspace = workspace!(id)
      Process.delete(:child_run)

      assert {:ok, _} = Dispatcher.attempt(id, "open a run", workspace: workspace)

      # Read here rather than inside `on_exit`: that callback runs in another
      # process, whose dictionary is empty — which is how three runs leaked
      # into `.agents/runs/` before anybody looked.
      child = Process.get(:child_run)
      on_exit(fn -> Run.delete(child["id"]) end)

      # A process-global that leaks is a run opened an hour later inheriting a
      # parent it never had.
      assert System.get_env("NOETIC_HARNESS_PARENT_RUN") == nil
    end
  end

  describe "what prepare/2 plans" do
    test "it dispatches the step the conductor named, to a role that staffs it", %{id: id} do
      assert {:ok, plan} = Dispatcher.prepare(id)

      assert plan.step == "context"
      assert plan.trust == "T0"
      assert plan.depth == 1
      assert plan.role != nil
      assert is_binary(plan.prompt)
    end

    test "the prompt is the runtime prompt, not the standing one", %{id: id} do
      {:ok, plan} = Dispatcher.prepare(id)

      # One code path with `noetic-harness prompt`, as a design decision requires of
      # `conduct`: the constitution first, then the work this run is for.
      assert plan.prompt =~ "Agent Constitution"
      assert plan.prompt =~ "dispatcher test"
    end

    test "a partial capability cover dispatches, and says what it does not cover", %{id: id} do
      # WF-002's first step asks for `runtime.context` and `architecture.domain`
      # together and no single role holds both. Refusing that would refuse the
      # commonest step there is; reporting it silently would be worse.
      assert {:ok, plan} = Dispatcher.prepare(id)
      assert plan.uncovered != []
      assert Enum.all?(plan.uncovered, &is_binary/1)
    end

    test "the default adapter runs nothing", %{id: _id} do
      # A default that dispatches for real is one misconfiguration away from
      # spending money in CI. The assertion is on what would be *resolved*, not
      # on `Dispatcher.adapter/0`: that now answers nil when nothing is pinned,
      # because the default comes from `.agents/policies/models.json` rather
      # than from a hardcoded module.
      pinned = Application.get_env(:noetic_harness, :dispatch_adapter)
      Application.delete_env(:noetic_harness, :dispatch_adapter)

      on_exit(fn ->
        if pinned, do: Application.put_env(:noetic_harness, :dispatch_adapter, pinned)
      end)

      assert {:ok, %{id: "null", module: Noetic.Harness.Dispatcher.NullAdapter}} =
               Adapter.resolve("T0")
    end
  end

  describe "the depth ceiling" do
    test "a dispatch at the ceiling is refused, and the refusal names the rule", %{id: id} do
      assert {:refused, refusals} = Dispatcher.prepare(id, %{depth: Dispatcher.depth_ceiling()})
      assert rules(refusals) == ["depth"]

      [%{why: why}] = refusals
      assert is_binary(why)
      assert why =~ "ceiling is #{Dispatcher.depth_ceiling()}"
    end

    test "one below the ceiling is allowed, so the ceiling is where it claims to be", %{id: id} do
      # Without this the test above passes for a dispatcher that refuses
      # everything, which is the other way to get a ceiling wrong.
      assert {:ok, plan} = Dispatcher.prepare(id, %{depth: Dispatcher.depth_ceiling() - 1})
      assert plan.depth == Dispatcher.depth_ceiling()
    end
  end

  describe "the wall-clock ceiling" do
    test "an exhausted budget is refused", %{id: id} do
      assert {:refused, refusals} = Dispatcher.prepare(id, %{remaining_ms: 0})
      assert rules(refusals) == ["wall_clock"]
      assert hd(refusals).why =~ "never a fresh allowance"
    end

    test "a child inherits what is left, not a fresh allowance", %{id: id} do
      # The whole point of §2's third row: depth 2 on a 30-minute budget is 90
      # minutes wearing a 30-minute label if this inherits the ceiling instead.
      assert {:ok, plan} = Dispatcher.prepare(id, %{remaining_ms: 5_000})
      assert plan.remaining_ms == 5_000
      refute plan.remaining_ms == Dispatcher.wall_clock_ceiling()
    end

    test "both ceilings refuse together rather than one at a time", %{id: id} do
      assert {:refused, refusals} =
               Dispatcher.prepare(id, %{depth: Dispatcher.depth_ceiling(), remaining_ms: 0})

      assert rules(refusals) == ["depth", "wall_clock"]
    end
  end

  describe "trust is derived downward" do
    test "a parent at T0 cannot hand its child the T1 its step grants", %{id: id} do
      {:ok, _} =
        Run.record(id,
          step: "context",
          outcome: "done",
          evidence: ["read it"],
          artifacts: [artifact!("ArchitectureMap")]
        )

      # The step the run now stands at grants more than the parent holds.
      assert {:ok, ungoverned} = Dispatcher.prepare(id)
      assert ungoverned.step == "plan"
      assert ungoverned.trust == "T1"

      assert {:ok, governed} = Dispatcher.prepare(id, %{trust: "T0"})
      assert governed.step == "plan"
      assert governed.trust == "T0"
    end

    test "the derivation itself has no upward path", %{id: _id} do
      # Exhaustive over the shapes that matter, because this is the function a
      # laundering attempt would go through and there is only one of it.
      assert Policy.derive_trust("T0", "T5", "T5") == "T0"
      assert Policy.derive_trust("T5", "T1", "T5") == "T1"
      assert Policy.derive_trust("T5", "T5", "T1") == "T1"
      assert Policy.derive_trust(nil, "T5", "T2") == "T2"
      assert Policy.derive_trust("T2", "T5", "T2") == "T2"
    end
  end

  describe "the conductor's refusals stand" do
    test "an exhausted retry budget refuses the dispatch", %{id: id} do
      for i <- 1..3 do
        {:ok, _} =
          Run.record(id, step: "context", outcome: "failed", evidence: ["attempt #{i} — no luck"])
      end

      assert {:refused, refusals} = Dispatcher.prepare(id)
      assert rules(refusals) == ["conductor"]
      assert hd(refusals).why =~ "exhausted"
    end

    test "a closed run has no step to dispatch", %{id: id} do
      {:ok, run} = Run.fetch(id)
      path = Noetic.Harness.agents_path("runs") |> Path.join("#{id}.json")
      File.write!(path, JSON.encode!(Map.put(run, "status", "abandoned")))

      assert {:refused, refusals} = Dispatcher.prepare(id)
      assert rules(refusals) == ["conductor"]
      assert hd(refusals).why =~ "no step to dispatch"
    end

    test "a run that does not exist is refused rather than invented", %{id: _id} do
      assert {:refused, refusals} = Dispatcher.prepare("run-that-was-never-started")
      assert rules(refusals) == ["run"]
    end
  end

  describe "the worktree" do
    test "the agent is told to write in the run's own worktree, not the parent's tree", %{id: id} do
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@clear, "export const channel = \"elsewhere\";\n"}])

      assert {:ok, result} = Dispatcher.dispatch(id, workspace: workspace)

      assert result.output.cwd == workspace.path
      assert result.paths == [@clear]

      # And the parent's copy is untouched. This is the property the whole bead
      # exists for: `git add -A` is forbidden here because sessions share a
      # working directory, and a dispatched agent has neither a watcher nor
      # exclusive use of one.
      parent = Path.join(Noetic.Harness.root(), @clear)
      refute File.read!(parent) == "export const channel = \"elsewhere\";\n"
    end

    @tag :default_root
    test "the worktree is not inside the working tree", %{id: id} do
      workspace = workspace!(id)

      # A worktree checked out beside the source shows up in the parent's
      # `git status` as an untracked directory, one `git add` away from being
      # committed by somebody who did not write it.
      refute String.starts_with?(workspace.path, Noetic.Harness.root() <> "/apps")
      refute String.starts_with?(workspace.path, Noetic.Harness.root() <> "/.agents")
      assert workspace.branch == "harness/run/" <> id
    end

    test "a file the agent creates is seen, not only one it edits", %{id: id} do
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{"apps/acme/lib/acme/invented_by_the_agent.ex", "defmodule X do\nend\n"}])

      assert {:ok, result} = Dispatcher.dispatch(id, workspace: workspace)

      # A plain `git diff` does not show an untracked file, so a fence built on
      # one would miss every new file an agent wrote — including a new gate.
      assert result.paths == ["apps/acme/lib/acme/invented_by_the_agent.ex"]
    end

    test "the result carries the diff itself, not a summary of one", %{id: id} do
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@clear, "export const channel = \"changed\";\n"}])

      assert {:ok, result} = Dispatcher.dispatch(id, workspace: workspace)

      assert result.diff =~ "diff --git"
      assert result.diff =~ ~s(channel = "changed")
    end

    test "a run that cannot be isolated is refused, and the agent never runs", %{id: id} do
      adapter(RaisingAdapter)

      # §33: a dispatched run that cannot be isolated does not run unisolated.
      # `NOETIC_HARNESS_WORKTREE_ROOT` pointed at a file rather than a
      # directory is the cheapest way to make `worktree add` fail for real.
      blocker =
        Noetic.Harness.TestTmp.path("not-a-directory")

      File.write!(blocker, "")
      original = System.get_env("NOETIC_HARNESS_WORKTREE_ROOT")

      try do
        System.put_env("NOETIC_HARNESS_WORKTREE_ROOT", blocker)
        assert {:refused, refusals} = Dispatcher.dispatch(id)
        assert rules(refusals) == ["workspace"]
        assert is_binary(hd(refusals).why)
      after
        File.rm(blocker)

        if original,
          do: System.put_env("NOETIC_HARNESS_WORKTREE_ROOT", original),
          else: System.delete_env("NOETIC_HARNESS_WORKTREE_ROOT")
      end
    end
  end

  describe "the fence" do
    test "an agent that edits an evaluator does not come back as a success", %{id: id} do
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@clear, "ordinary\n"}, {@fenced, ~s({"version": 1})}])

      assert {:refused, refusals} = Dispatcher.dispatch(id, workspace: workspace)
      assert rules(refusals) == ["evaluator_fence"]

      why = hd(refusals).why
      assert why =~ @fenced
      assert why =~ ".agents/policies/evaluators.json"
      assert is_binary(why)
    end

    test "the refusal leaves the evidence and says where it is", %{id: id} do
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@fenced, ~s({"version": 1})}])

      assert {:refused, [refusal]} = Dispatcher.dispatch(id, workspace: workspace)

      # `.agents/policies/failure.md`: the evidence is not reverted along with
      # the code. A rejected run is diagnosable or the rejection taught nobody
      # anything.
      assert refusal.why =~ workspace.branch
      assert refusal.why =~ workspace.path
      assert File.dir?(workspace.path)
      assert File.read!(Path.join(workspace.path, @fenced)) == ~s({"version": 1})

      # And the real one is untouched.
      refute File.read!(Path.join(Noetic.Harness.root(), @fenced)) == ~s({"version": 1})
    end

    test "a clear change comes back with what it changed and what the agent said", %{id: id} do
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@clear, "ordinary\n"}])

      assert {:ok, result} = Dispatcher.dispatch(id, workspace: workspace)

      assert result.paths == [@clear]
      assert result.step == "context"
      assert result.trust == "T0"
      assert result.workspace.branch == workspace.branch
    end

    test "the ledger records the model the adapter used, and its tokens", %{id: id} do
      adapter(__MODULE__.ModelReportingAdapter)
      workspace = workspace!(id)

      assert {:ok, result} = Dispatcher.dispatch(id, workspace: workspace)
      # Pinned, so the plan named no model; what the adapter says ran is kept
      # beside it rather than in its place.
      assert result.model == nil
      assert result.model_reported == "ollama/reported"

      {:ok, run} = Run.fetch(id)
      assert [entry] = run["dispatches"]
      assert entry["model"] == nil
      assert entry["model_reported"] == "ollama/reported"
      assert entry["cost_usd"] == 0.0
      assert entry["usage"] == %{"input_tokens" => 40, "output_tokens" => 8}
    end

    test "the elapsed time is taken off what remains", %{id: id} do
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@clear, "ordinary\n"}])

      assert {:ok, result} =
               Dispatcher.dispatch(id, workspace: workspace, parent: %{remaining_ms: 900})

      assert result.remaining_ms <= 900
      assert result.elapsed_ms >= 0
    end
  end

  describe "protected trust is not dispatched" do
    test "a step that genuinely declares T4 is refused" do
      # Not reachable by handing a parent's trust down: `derive_trust/3` only
      # narrows, so a T4 parent over a T0 step produces T0 and there is nothing
      # to refuse. The refusal is about a *step* that declares T4, which is why
      # this test walks a real WF-016 to its `contain` step rather than
      # asserting on a value it made up.
      {:ok, run} =
        Run.start(workflow: "WF-016", title: "#{unique()} incident")

      id = run["id"]

      on_exit(fn ->
        Noetic.Harness.agents_path("runs") |> Path.join("#{id}.json") |> File.rm()
      end)

      {:ok, _} = Run.record(id, step: "triage", outcome: "done", evidence: ["what broke"])
      {:ok, _} = Run.record(id, step: "preserve", outcome: "done", evidence: ["captured it"])

      assert {:refused, refusals} = Dispatcher.prepare(id)
      assert rules(refusals) == ["protected"]

      why = hd(refusals).why
      assert why =~ "T4"
      assert why =~ "trust_levels.json"
      assert why =~ "did not author"
    end

    test "T3 and below are dispatched", %{id: id} do
      # The other half, because a ceiling that refuses everything is not a
      # ceiling — it is a broken dispatcher that happens to pass the test above.
      assert {:ok, plan} = Dispatcher.prepare(id)
      assert plan.trust in ~w(T0 T1 T2 T3)
    end

    test "a parent cannot hand a child into T4 either", %{id: id} do
      # The laundering path, closed by `derive_trust/3` rather than by the
      # refusal: the parent's T4 is a ceiling, and the step's T0 still wins.
      assert {:ok, plan} = Dispatcher.prepare(id, %{trust: "T4"})
      assert plan.trust == "T0"
    end
  end

  describe "what dispatch writes to the ledger" do
    defp outcomes(id) do
      {:ok, run} = Run.fetch(id)
      Enum.map(run["steps"], & &1["outcome"])
    end

    test "a fence refusal is written down as a failed attempt", %{id: id} do
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@fenced, ~s({"version": 1})}])

      assert {:refused, _} = Dispatcher.dispatch(id, workspace: workspace)

      assert outcomes(id) == ["failed"]
      {:ok, run} = Run.fetch(id)
      assert hd(run["steps"])["step"] == "context"
      assert hd(run["steps"])["evidence"] |> hd() =~ @fenced
    end

    test "an agent that could not be called is a failure, with where it routes", %{id: id} do
      adapter(__MODULE__.FailingAdapter)
      workspace = workspace!(id)

      assert {:error, :enoent} = Dispatcher.dispatch(id, workspace: workspace)
      assert outcomes(id) == ["failed"]

      {:ok, run} = Run.fetch(id)

      # `Conductor.classify/1` is the single answer to where a failure goes.
      # Nothing in `failure.json` matches an adapter that could not be called,
      # and the note says *that* rather than being absent — a missing note
      # reads as "nobody asked".
      assert hd(run["steps"])["note"] =~ "unclassified"
      assert hd(run["steps"])["note"] =~ "failure.json"
    end

    test "an agent that returned nothing is a failure, not a thin success", %{id: id} do
      # "It ran" and "it produced something" are different facts.
      adapter(__MODULE__.SilentAdapter)
      workspace = workspace!(id)

      assert {:refused, refusals} = Dispatcher.dispatch(id, workspace: workspace)
      assert rules(refusals) == ["no_output"]
      assert outcomes(id) == ["failed"]
    end

    test "dispatch can write a failed and can never write a done", %{id: id} do
      adapter(__MODULE__.SilentAdapter)
      workspace = workspace!(id)

      {:refused, _} = Dispatcher.dispatch(id, workspace: workspace)
      {:refused, _} = Dispatcher.dispatch(id, workspace: workspace)

      # The asymmetry is the whole enforcement of "a dispatched step that
      # produced no evidence is failed, not done". A `done` here would mean
      # dispatch had become the way round the ledger's own refusal.
      refute "done" in outcomes(id)
    end

    test "a success is handed back rather than recorded", %{id: id} do
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@clear, "ordinary\n"}])

      assert {:ok, _} = Dispatcher.dispatch(id, workspace: workspace)
      assert outcomes(id) == []
    end

    test "a caller driving prepare itself can suppress the write", %{id: id} do
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@fenced, ~s({"version": 1})}])

      assert {:refused, _} = Dispatcher.dispatch(id, workspace: workspace, record: false)
      assert outcomes(id) == []
    end
  end

  describe "which agent it would send to" do
    setup do
      pinned = Application.get_env(:noetic_harness, :dispatch_adapter)
      previous = Application.get_env(:noetic_harness, :dispatch_adapter_id)
      key = System.get_env("ANTHROPIC_API_KEY")

      # A module pinned directly bypasses the policy, which is what every other
      # test here wants and what these three must not have.
      Application.delete_env(:noetic_harness, :dispatch_adapter)
      System.delete_env("ANTHROPIC_API_KEY")

      on_exit(fn ->
        if pinned, do: Application.put_env(:noetic_harness, :dispatch_adapter, pinned)

        if previous,
          do: Application.put_env(:noetic_harness, :dispatch_adapter_id, previous),
          else: Application.delete_env(:noetic_harness, :dispatch_adapter_id)

        if key, do: System.put_env("ANTHROPIC_API_KEY", key)
      end)
    end

    @tag :tmp_dir
    test "the plan names the adapter and the model the trust gets", %{id: id, tmp_dir: tmp} do
      claude_on_path!(tmp)
      Application.put_env(:noetic_harness, :dispatch_adapter_id, "claude_code")

      # The context step is T0: read and map, on the cheapest model that can
      # read, with no command execution at all.
      assert {:ok, plan} = Dispatcher.prepare(id)
      assert plan.adapter == "claude_code"
      assert plan.model == "haiku"
      assert plan.restricted == true
    end

    test "an adapter with no credential refuses, and does not become another one", %{id: id} do
      # §33. Falling back turns "which model produced this measurement?" into a
      # guess, and an earlier change's promotion gate has to answer it.
      Application.put_env(:noetic_harness, :dispatch_adapter_id, "api")

      assert {:refused, refusals} = Dispatcher.prepare(id)
      assert rules(refusals) == ["adapter"]
      assert hd(refusals).why =~ "ANTHROPIC_API_KEY"
    end

    test "a refused adapter means no worktree is opened either", %{id: id} do
      # The refusal is in `prepare/2`, so the 256 MB is not spent on a dispatch
      # that was never going to happen.
      Application.put_env(:noetic_harness, :dispatch_adapter_id, "api")

      before = Workspace.list()
      assert {:refused, [%{rule: "adapter"}]} = Dispatcher.dispatch(id)
      assert Workspace.list() == before
    end
  end

  describe "the one place the fence is narrowed" do
    test "an attempt may change the files its task named", %{id: id} do
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@exemptible, "# rewritten by the solver\n"}])

      assert {:ok, _} =
               Dispatcher.attempt(id, "fix the thing",
                 workspace: workspace,
                 task_paths: [@exemptible]
               )
    end

    test "and is still refused for a fenced file the task did not name", %{id: id} do
      # The subtraction, not a switch: the exemption takes those paths out of
      # what is judged and leaves the rest of the diff in. A solver doing the
      # task *and* rewriting the policy arrives as one diff.
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@exemptible, "# rewritten\n"}, {".agents/constitution.md", "rewritten\n"}])

      assert {:refused, refusals} =
               Dispatcher.attempt(id, "fix the thing",
                 workspace: workspace,
                 task_paths: [@exemptible]
               )

      assert rules(refusals) == ["evaluator_fence"]
      assert hd(refusals).why =~ ".agents/constitution.md"
      refute hd(refusals).why =~ @exemptible
    end

    test "a fenced path the policy does not mark exemptible cannot be one", %{id: id} do
      # The refusal an independent review showed was missing. An exemption may
      # reach the harness's own modules and never what says what passing means
      # outside this worktree — and `Environments.derive/2` takes everything a
      # commit changed except prose, `.beads/` and `.agents/`, so a commit
      # touching CI derives an environment whose source paths are exactly that.
      adapter(RaisingAdapter)
      workspace = workspace!(id)

      for path <- [@fenced, ".github/workflows/ci.yml", "scripts/ci-local.sh"] do
        assert {:refused, refusals} =
                 Dispatcher.attempt(id, "fix the thing",
                   workspace: workspace,
                   task_paths: [path]
                 )

        assert rules(refusals) == ["task_paths"], "#{path} was not refused"
        assert hd(refusals).why =~ "is not exemptible"
      end
    end

    test "a spelling git does not use is not an exemption", %{id: id} do
      # Not because a glob would widen anything — the comparison is list
      # subtraction, so it exempts nothing — but because `Tree.confine/3`'s
      # `keep` then matches nothing and reverts the solver's correct fix,
      # scoring `false` rather than refusing. Refused *before* the adapter,
      # which is what RaisingAdapter asserts.
      adapter(RaisingAdapter)
      workspace = workspace!(id)

      for path <- ["apps/noetic_harness/**", "./" <> @exemptible, "apps/../etc/passwd", ""] do
        assert {:refused, refusals} =
                 Dispatcher.attempt(id, "fix the thing",
                   workspace: workspace,
                   task_paths: [path]
                 )

        assert rules(refusals) == ["task_paths"], "#{inspect(path)} was not refused"
      end
    end

    test "and dispatch/2 has no such option", %{id: id} do
      # The workflow path produces a diff somebody is asked to land, and there
      # is no way to narrow the fence over one. The plan writes `[]`; an option
      # in `opts` reaches `run_in/3` and is not read.
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@exemptible, "# rewritten\n"}])

      assert {:refused, refusals} =
               Dispatcher.dispatch(id, workspace: workspace, task_paths: [@exemptible])

      assert rules(refusals) == ["evaluator_fence"]
    end
  end

  describe "nothing runs before the refusal" do
    test "a refused dispatch never reaches the adapter", %{id: id} do
      adapter(RaisingAdapter)

      assert {:refused, _} = Dispatcher.dispatch(id, parent: %{depth: Dispatcher.depth_ceiling()})
    end

    test "the fence runs after the adapter and still refuses", %{id: id} do
      # The ordering that matters: the agent may run, and its output still does
      # not become a landing. A fence checked only before dispatch would pass
      # every other test here and protect nothing, because the paths it must
      # judge do not exist until the agent has written them.
      adapter(__MODULE__.WritingAdapter)
      workspace = workspace!(id)
      writes([{@fenced, ~s({"version": 1})}])

      assert {:refused, refusals} = Dispatcher.dispatch(id, workspace: workspace)
      assert rules(refusals) == ["evaluator_fence"]
      assert File.read!(Path.join(workspace.path, @fenced)) == ~s({"version": 1})
    end
  end

  defmodule SilentAdapter do
    @moduledoc "An agent that was called and produced nothing."
    def available?, do: :ok
    def call(_prompt, _opts), do: {:ok, ""}
  end

  defmodule FailingAdapter do
    @moduledoc "An agent that could not be called at all."
    def available?, do: :ok
    def call(_prompt, _opts), do: {:error, :enoent}
  end

  defmodule RecordingAdapter do
    @moduledoc "Reports that it ran, to the process that dispatched."
    def call(prompt, _opts) do
      send(self(), :adapter_called)
      {:ok, %{prompt: prompt}}
    end
  end

  describe "the budget is ledger state, not an argument" do
    test "a caller that says nothing is still refused when the ledger says it is deep" do
      # The whole bead in one test. `prepare/2` is given `%{}` — no depth, no
      # remaining time, nothing — which used to mean "depth 0, full allowance".
      # The chain on disk says otherwise, and the chain is what happened.
      chain = chain_of(Dispatcher.depth_ceiling() + 1)

      assert {:refused, refusals} = Dispatcher.prepare(List.last(chain), %{})
      assert "depth" in rules(refusals)
    end

    test "a caller that understates its depth is contradicted, not believed" do
      chain = chain_of(Dispatcher.depth_ceiling() + 1)

      assert {:refused, refusals} = Dispatcher.prepare(List.last(chain), %{depth: 0})
      assert "depth" in rules(refusals)
    end

    test "the stricter of the two wins in the other direction too" do
      # A shallow run on disk, a caller claiming to be at the ceiling: still
      # refused. `max/2` is the operator, and it is the operator in both
      # directions on purpose.
      run = real_run("shallow")

      assert {:refused, refusals} = Dispatcher.prepare(run, %{depth: Dispatcher.depth_ceiling()})
      assert "depth" in rules(refusals)
    end

    test "wall-clock spent by the chain comes off the allowance" do
      root = real_run("clock root")
      child = real_run("clock child", parent_run: root)

      {:ok, _} = Run.spend(root, step: "context", elapsed_ms: Dispatcher.wall_clock_ceiling())

      assert {:refused, refusals} = Dispatcher.prepare(child, %{})
      assert "wall_clock" in rules(refusals)
    end

    test "cost the adapters reported is a ceiling, and it refuses" do
      run = real_run("expensive")

      {:ok, _} =
        Run.spend(run, step: "context", elapsed_ms: 10, cost_usd: Dispatcher.cost_ceiling())

      assert {:refused, refusals} = Dispatcher.prepare(run, %{})
      assert "cost" in rules(refusals)
    end

    test "an unknown cost does not bind, and the plan says so rather than pretending" do
      # §32 and §33. An adapter that reported no price must not be counted as
      # $0 — that would make the ceiling unreachable by exactly the adapters
      # whose spend is hardest to see — and must not refuse everything either.
      # The honest outcome is that the cost ceiling does not bind and the plan
      # carries `cost_known?: false`.
      run = real_run("unpriced")

      {:ok, _} =
        Run.spend(run, step: "context", elapsed_ms: 10, cost_usd: Dispatcher.cost_ceiling())

      {:ok, _} = Run.spend(run, step: "plan", elapsed_ms: 10)

      assert {:ok, plan} = Dispatcher.prepare(run, %{})
      refute plan.cost_known?
    end

    test "the ceilings come from the policy file, which is inside the fence" do
      {:ok, policy} = Noetic.Harness.Policy.dispatch()

      assert Dispatcher.depth_ceiling() == policy["depth"]["max"]
      assert Dispatcher.wall_clock_ceiling() == policy["wall_clock"]["max_ms"]
      assert Dispatcher.cost_ceiling() == policy["cost"]["max_usd"]

      # Every ceiling carries a reason, because a refusal that cannot be argued
      # with is a refusal that gets worked around.
      for key <- ~w(depth wall_clock cost) do
        assert is_binary(policy[key]["why"])
      end
    end
  end

  describe "a stopped run" do
    test "prepare refuses, naming the rule" do
      run = real_run("stopped")
      {:ok, _} = Run.stop(run, reason: "spending more than expected", by: "a-person")

      assert {:refused, refusals} = Dispatcher.prepare(run, %{})
      assert "stopped" in rules(refusals)
    end

    test "a stop above binds a run below it" do
      root = real_run("stop root")
      child = real_run("stop child", parent_run: root)
      {:ok, _} = Run.stop(root, reason: "stop the tree")

      assert {:refused, refusals} = Dispatcher.prepare(child, %{})
      assert "stopped" in rules(refusals)
    end

    test "the adapter is never reached" do
      # The assertion that matters: an adapter that raises when called. A
      # dispatcher that called the agent and *then* noticed the stop would
      # pass a refusal-tuple assertion while having already spent the money.
      run = real_run("stopped before the adapter")
      {:ok, _} = Run.stop(run, reason: "no")
      adapter(__MODULE__.RaisingAdapter)

      assert {:refused, refusals} = Dispatcher.dispatch(run, record: false)
      assert "stopped" in rules(refusals)
    end
  end

  # A chain `n` deep, returned root-first. Each run's `parent_run` is written
  # at `start/1`, which is where a dispatcher writes it.
  defp chain_of(depth) do
    Enum.reduce(0..depth, [], fn index, acc ->
      parent = List.last(acc)
      acc ++ [real_run("chain #{index}", parent_run: parent)]
    end)
  end

  defp real_run(title, opts \\ []) do
    opts = Enum.reject(opts, fn {_k, v} -> is_nil(v) end)

    {:ok, run} =
      Run.start(
        [
          workflow: "WF-002",
          title: "#{unique()} #{title}",
          agent: "test"
        ] ++ opts
      )

    on_exit(fn ->
      Noetic.Harness.agents_path("runs") |> Path.join("#{run["id"]}.json") |> File.rm()
    end)

    run["id"]
  end

  describe "review by the thing under review is not review" do
    test "a step declared independent_of one the same role already took is refused" do
      # WF-003's `verify` is `independent_of: ["patch"]`, and until now
      # `Router.independence_constraints/1` reported that constraint while its
      # own moduledoc said enforcing it was the orchestrator's job. The
      # dispatcher is the orchestrator.
      run = wf003_run("independence")
      {:ok, plan} = advance_to_verify(run)

      # Record `patch` as having been taken by exactly the role the dispatcher
      # would now staff `verify` with.
      {:ok, _} =
        Run.record(run,
          step: "patch",
          outcome: "done",
          evidence: ["fixed it"],
          artifacts: [artifact!("CodePatch")],
          agent: plan.role
        )

      assert {:refused, refusals} = Dispatcher.prepare(run, %{})
      assert "independence" in rules(refusals)

      why = Enum.find(refusals, &(&1.rule == "independence")).why
      assert why =~ "independent_of"
      assert why =~ plan.role
    end

    test "a different role taking the earlier step is not refused" do
      run = wf003_run("independence ok")
      {:ok, _} = advance_to_verify(run)

      {:ok, _} =
        Run.record(run,
          step: "patch",
          outcome: "done",
          evidence: ["fixed it"],
          artifacts: [artifact!("CodePatch")],
          agent: "somebody.else"
        )

      assert {:ok, plan} = Dispatcher.prepare(run, %{})
      assert plan.step == "verify"
    end

    test "the constraint the workflow declares is the one enforced" do
      # Not a hardcoded pair: whatever `independent_of` says is what binds.
      {:ok, workflow} = Noetic.Harness.Workflow.fetch("WF-003")
      verify = Enum.find(workflow["steps"], &(&1["id"] == "verify"))

      assert "patch" in verify["independent_of"]
    end

    test "a review is dispatched to the stronger model when Sonnet wrote the work" do
      run = wf003_run("opus reviews sonnet")
      {:ok, _} = Run.spend(run, step: "patch", elapsed_ms: 1, model: "sonnet")
      assert {:ok, plan} = advance_to_verify(run)
      assert plan.step == "verify"
      assert plan.model == "claude-opus-5-5"
      assert plan.independent_model?
    end

    test "work Opus wrote is reviewed by Sonnet, not by Opus" do
      # By the model a dispatch named, by the one its adapter reported, and by
      # the actor's name on a step a session recorded by hand.
      named = wf003_run("opus named")
      {:ok, _} = Run.spend(named, step: "patch", elapsed_ms: 1, model: "opus")
      assert {:ok, plan} = advance_to_verify(named)
      assert plan.model == "claude-sonnet-5"
      assert plan.independent_model?

      reported = wf003_run("opus reported")

      {:ok, _} =
        Run.spend(reported,
          step: "patch",
          elapsed_ms: 1,
          model: "some-alias",
          model_reported: "anthropic/claude-opus-5-5"
        )

      assert {:ok, plan} = advance_to_verify(reported)
      assert plan.model == "claude-sonnet-5"

      by_hand = wf003_run("opus by hand")
      assert {:ok, plan} = advance_to_verify(by_hand, "claude-opus-5-5")
      assert plan.step == "verify"
      assert plan.model == "claude-sonnet-5"
    end

    test "an adapter that runs one model cannot review that model's work: refused" do
      # Review of an earlier change found the ledger comparing a reported model with an
      # alias, so an adapter running one model at every trust read as
      # independent of itself. Recording the fact was the first fix; this is
      # the second — the review is refused rather than taken.
      adapter(__MODULE__.OneModelAdapter)
      run = wf003_run("one model")
      {:ok, _} = Run.spend(run, step: "patch", elapsed_ms: 1, model: "ollama/one")

      assert {:refused, refusals} = advance_to_verify(run)
      assert "independent_model" in rules(refusals)
      why = Enum.find(refusals, &(&1.rule == "independent_model")).why
      assert why =~ "ollama/one"
      assert why =~ "§23"

      # And the same adapter reviewing work another model did is not refused.
      other = wf003_run("different model")
      {:ok, _} = Run.spend(other, step: "patch", elapsed_ms: 1, model: "ollama/two")
      assert {:ok, plan} = advance_to_verify(other)
      assert plan.model == "ollama/one"
      assert plan.independent_model?
    end

    test "a step that reviews nothing keeps the model by_trust gave it" do
      run = wf003_run("no review")
      assert {:ok, plan} = Dispatcher.prepare(run, %{})
      refute plan.step == "verify"
      refute plan.model in Adapter.review_models()
    end

    test "model families: an alias, a full id and a router id are one model" do
      assert Adapter.model_family("sonnet") == "sonnet"
      assert Adapter.model_family("claude-sonnet-5") == "sonnet"
      assert Adapter.model_family("anthropic/claude-opus-5-5") == "opus"
      assert Adapter.model_family("claude-opus-5") == Adapter.model_family("claude-opus-5-5")
      assert Adapter.model_family("ollama/one") == "ollama/one"
      assert Adapter.model_family(nil) == nil
    end
  end

  # WF-003 up to the point where `verify` is the next step, with every earlier
  # step recorded by a role that is deliberately nobody.
  # Every step up to `verify`, recorded by a role that is deliberately nobody,
  # and with the envelopes their `outputs` declare — the conductor's artifact
  # debt is checked before anything here is, and a step owing one never gets
  # as far as the independence question.
  @wf003_artifacts %{
    "hypothesis" => "Hypothesis",
    "patch" => "CodePatch",
    "regression" => "EvaluationRun"
  }

  # `patch_agent` is who recorded the step under review: a role id, or — the
  # way a session records one with `HARNESS_AGENT` set — a model's id.
  defp advance_to_verify(run, patch_agent \\ "nobody.at.all") do
    for step <- ~w(reproduce evidence hypothesis bisect patch regression) do
      artifacts =
        case @wf003_artifacts[step] do
          nil -> []
          kind -> [artifact!(kind)]
        end

      {:ok, _} =
        Run.record(run,
          step: step,
          outcome: "done",
          evidence: ["e"],
          artifacts: artifacts,
          agent: if(step == "patch", do: patch_agent, else: "nobody.at.all")
        )
    end

    Dispatcher.prepare(run, %{})
  end

  defp wf003_run(title) do
    {:ok, run} =
      Run.start(
        workflow: "WF-003",
        title: "#{unique()} #{title}",
        agent: "test"
      )

    on_exit(fn ->
      Noetic.Harness.agents_path("runs") |> Path.join("#{run["id"]}.json") |> File.rm()
    end)

    run["id"]
  end
end
