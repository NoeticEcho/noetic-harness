defmodule Noetic.Harness.ScoringTest do
  @moduledoc """
  Every test here is a way a candidate could come to carry a number that means
  something other than what it says.

  The loop is exercised against a **fake adapter** and a fake `mix`, the same
  device the `claude -p` adapter's tests use: a suite made of real model calls
  is a suite nobody runs, and a suite made entirely of assertions about
  intentions agrees with itself about an interface that does not exist. What
  is real here is the git worktrees, the reverse patch, the deletion and
  restoration of the verifier, the exit statuses and every refusal.
  """
  # `async: false`, and now for a written reason. `setup` repoints
  # `:noetic_harness, :dispatch_adapter` and the `scoring_test_*` keys with
  # `Application.put_env/3`, which is VM-global — the same reason
  # `dispatcher_test` is sync, and the adapter is exactly the thing whose
  # substitution the tests here depend on seeing.
  use ExUnit.Case, async: false

  alias Noetic.Harness.{Environments, Evolution, Scoring}

  defmodule SolvingAdapter do
    @moduledoc """
    An adapter that "solves" a task by writing the fix back.

    It reads `:noetic_harness, :scoring_test_solve` — a list of
    `{environment_id, arm}` it should solve — and applies the fix commit
    forward in the worktree it was given. Anything not in that list is left
    unsolved, which is how a delta other than zero is produced without a model.
    """
    @behaviour Noetic.Harness.Adapter

    @impl true
    def available?, do: :ok

    @impl true
    def call(prompt, opts) do
      cwd = Keyword.fetch!(opts, :cwd)
      label = Keyword.get(opts, :label, "")

      if label in Application.get_env(:noetic_harness, :scoring_test_solve, []) do
        File.write!(
          Path.join(cwd, "apps/tiny/lib/tiny.ex"),
          "defmodule Tiny do\n  def value, do: :FIXED\nend\n"
        )
      end

      # Not solving the task, but making the verifier pass anyway. The fake
      # `mix` treats a `SHORTCUT` file as "no tests ran, exit 0", which is what
      # rewriting `test_helper.exs` to exclude the failing test does.
      #
      # It is written **outside** `apps/*/test/**` on purpose. That path is on
      # the fixture's evaluator fence — which is what calibrates the
      # prepared-state commit — and the first version of this test wrote there
      # and was caught by the fence instead, so it proved nothing about
      # confinement. The real repository fences almost nothing under `apps/`,
      # which is exactly why `Tree.confine/3` has to exist.
      if label in Application.get_env(:noetic_harness, :scoring_test_cheat, []) do
        File.write!(Path.join(cwd, "apps/tiny/SHORTCUT"), "yes\n")
      end

      {:ok, %{dispatched: true, prompt: prompt, cost_usd: 0.01}}
    end
  end

  defmodule OracleRewritingAdapter do
    @moduledoc """
    A solver that rewrites the verifier, from inside the file it was asked to
    fix, after that file has been handed back to the scorer.

    It writes only its own source path — the file the task named, which the
    exemption permits and `Tree.confine/3` keeps — and the fake `mix` does the
    rewriting when it sees the marker, because that is where the real one does
    it: the compiler runs a module body before ExUnit loads the test. The
    defect is left unfixed, so without the hash this scores `solved: true`.
    """
    @behaviour Noetic.Harness.Adapter

    @impl true
    def available?, do: :ok

    @impl true
    def call(_prompt, opts) do
      cwd = Keyword.fetch!(opts, :cwd)

      File.write!(
        Path.join(cwd, "apps/tiny/lib/tiny.ex"),
        "defmodule Tiny do\n  # REWRITE_ORACLE\n  def value, do: :broken\nend\n"
      )

      {:ok, %{dispatched: true, cost_usd: 0.01}}
    end
  end

  defmodule PolicyEditingAdapter do
    @moduledoc """
    A solver that does the task and rewrites the fence in the same diff.

    An exemption applied to the whole change rather than subtracted from it
    would let this through, so it is the case that calibrates the subtraction.
    """
    @behaviour Noetic.Harness.Adapter

    @impl true
    def available?, do: :ok

    @impl true
    def call(_prompt, opts) do
      cwd = Keyword.fetch!(opts, :cwd)

      File.write!(
        Path.join(cwd, "apps/tiny/lib/tiny.ex"),
        "defmodule Tiny do\n  def value, do: :FIXED\nend\n"
      )

      # The fixture repository has no `.agents/` of its own; the policy the
      # fence reads lives beside it. What matters is that a path the fence
      # protects appears in this worktree's diff.
      File.mkdir_p!(Path.join(cwd, ".agents/policies"))
      File.write!(Path.join(cwd, ".agents/policies/evaluators.json"), "{\"paths\": []}\n")
      {:ok, %{dispatched: true, cost_usd: 0.01}}
    end
  end

  defmodule HistoryReadingAdapter do
    @moduledoc """
    A solver that does not solve anything: it asks git for the answer.

    It reads `:noetic_harness, :scoring_test_history` — the fix, the verifier's
    blob and a pid to report to — and runs, in the tree it was given, every
    question a worktree used to answer: the fix commit, the verifier one
    commit back, the verifier's blob by name, and every commit and reflog
    entry the repository knows — and the fix again from the tree's parent
    and grandparent, which is where a review found it after the
    first of these was closed. If the fix's version of the source comes
    back, it is written into the tree, so a history that still held the
    answer scores `solved: true` rather than merely reporting it.

    Every question is a `git` this adapter starts, so it runs with whatever
    environment a real solver's process would inherit, and `env` reports
    that environment's `GIT_*` variables. `config` asks git for
    `harness.test.origin`, a key only a configuration from outside the tree
    has.
    """
    @behaviour Noetic.Harness.Adapter

    @impl true
    def available?, do: :ok

    @impl true
    def call(_prompt, opts) do
      cwd = Keyword.fetch!(opts, :cwd)

      %{onlooker: onlooker, fix: fix, blob: blob} =
        Application.fetch_env!(:noetic_harness, :scoring_test_history)

      git = fn args -> System.cmd("git", args, cd: cwd, stderr_to_stdout: true) end

      answers = %{
        fix: git.(["show", fix]),
        verifier_before: git.(["show", "HEAD~1:apps/tiny/test/tiny_test.exs"]),
        verifier_blob: git.(["cat-file", "-p", blob]),
        answer: git.(["show", "#{fix}:apps/tiny/lib/tiny.ex"]),
        log: git.(["log", "--all", "--format=%H"]),
        reflog: git.(["reflog", "--format=%H"]),
        parent_fix: git.(["-C", "..", "show", fix]),
        grandparent_fix: git.(["-C", "../..", "show", fix]),
        parent_git_dir: git.(["-C", "..", "rev-parse", "--git-dir"]),
        config: git.(["config", "--get-all", "harness.test.origin"]),
        env:
          System.cmd("env", [], cd: cwd)
          |> elem(0)
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, "GIT_"))
      }

      case answers.answer do
        {source, 0} -> File.write!(Path.join(cwd, "apps/tiny/lib/tiny.ex"), source)
        _ -> :ok
      end

      send(onlooker, {:history, Keyword.get(opts, :label), answers})
      {:ok, %{dispatched: true, cost_usd: 0.01}}
    end
  end

  # Scoring dispatches, and a dispatch its timeout kills would leave
  # `NOETIC_HARNESS_PARENT_RUN` behind for every later run (`DispatchExport`).
  setup {Noetic.Harness.DispatchExport, :guard}

  setup do
    previous = Application.get_env(:noetic_harness, :dispatch_adapter)
    Application.put_env(:noetic_harness, :dispatch_adapter, SolvingAdapter)
    Application.put_env(:noetic_harness, :scoring_test_solve, [])
    Application.put_env(:noetic_harness, :scoring_test_cheat, [])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:noetic_harness, :dispatch_adapter, previous),
        else: Application.delete_env(:noetic_harness, :dispatch_adapter)

      Application.delete_env(:noetic_harness, :scoring_test_solve)
      Application.delete_env(:noetic_harness, :scoring_test_cheat)
      Application.delete_env(:noetic_harness, :scoring_test_history)
    end)

    :ok
  end

  # A real repository with a real fix commit, a fake `mix` that answers from
  # the source in front of it, an environment in the benchmark set, a run to
  # attribute the measurement to, and a candidate with two arms.
  defp with_scoring_repo(fun) do
    root =
      Noetic.Harness.TestTmp.path("harness-scoring") |> Noetic.Harness.Fixture.write_project()

    bin = Path.join(root, "bin")
    source = Path.join([root, "apps", "tiny", "lib", "tiny.ex"])
    verifier = Path.join([root, "apps", "tiny", "test", "tiny_test.exs"])

    File.mkdir_p!(Path.dirname(source))
    File.mkdir_p!(Path.dirname(verifier))
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "mix"), """
    #!/bin/sh
    # An arm whose tree says so fails the way a broken build fails: non-zero,
    # with a `** (Mix)` line and without ever reaching a test.
    if [ -f SHORTCUT ]; then
      printf '0 tests, 0 failures, 1 excluded\\n'
      exit 0
    fi
    if grep -q brokenbuild ../../HARNESS 2>/dev/null; then
      printf '** (Mix) Could not compile dependency :lazy_html\\n'
      exit 1
    fi
    if [ ! -f test/tiny_test.exs ]; then
      printf '** (Mix) no such file test/tiny_test.exs\\n'
      exit 1
    fi
    # The compiler runs the solver's module body before ExUnit loads the test.
    # This is that, in four lines: a source file that says so rewrites the
    # verifier that was just restored, and then passes.
    if grep -q REWRITE_ORACLE lib/tiny.ex 2>/dev/null; then
      # And if the write *fails*, the build fails, because a
      # compile-time raise aborts compilation. The first version of this fake
      # exited 0 regardless, so once the oracle was bound read-only the cheat
      # "succeeded" against a verifier that had never run — which is how that
      # gap was found.
      if printf 'rewritten by the module body\\n' > test/tiny_test.exs 2>/dev/null; then
        printf '1 test, 0 failures\\n'
        exit 0
      else
        printf '** (File.Error) could not write to "test/tiny_test.exs": read-only file system\\n'
        exit 1
      fi
    fi
    if grep -q FIXED lib/tiny.ex 2>/dev/null; then
      printf '1 test, 0 failures\\n'
      exit 0
    fi
    printf '1 test, 1 failure\\n'
    exit 1
    """)

    File.chmod!(Path.join(bin, "mix"), 0o755)

    File.write!(source, "defmodule Tiny do\n  def value, do: :broken\nend\n")
    File.write!(verifier, "# the oracle\n")

    git = fn args -> {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true) end

    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.email", "harness@example.invalid"])
    git.(["config", "user.name", "harness"])
    git.(["config", "commit.gpgsign", "false"])
    git.(["add", "apps/tiny/lib/tiny.ex", "apps/tiny/test/tiny_test.exs"])
    git.(["commit", "-q", "-m", "the defect"])

    File.write!(source, "defmodule Tiny do\n  def value, do: :FIXED\nend\n")
    git.(["add", "apps/tiny/lib/tiny.ex"])
    git.(["commit", "-q", "-m", "the fix"])

    {fix, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    {parent, 0} = System.cmd("git", ["rev-parse", "HEAD~1"], cd: root)
    fix = String.trim(fix)
    parent = String.trim(parent)

    # The two arms are versions of the *harness*, and both have to contain the
    # environment's fix — otherwise the defect cannot be reintroduced in them
    # and they are not answering the same question. Getting this wrong in the
    # first draft is what produced `ancestry_refusals/2`.
    File.write!(Path.join(root, "HARNESS"), "baseline\n")
    git.(["add", "HARNESS"])
    git.(["commit", "-q", "-m", "the baseline harness"])
    {baseline, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    baseline = String.trim(baseline)

    File.write!(Path.join(root, "HARNESS"), "candidate\n")
    git.(["add", "HARNESS"])
    git.(["commit", "-q", "-m", "the candidate harness"])
    {arm, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    arm = String.trim(arm)

    File.write!(Path.join(root, "HARNESS"), "brokenbuild\n")
    git.(["add", "HARNESS"])
    git.(["commit", "-q", "-m", "a harness that does not build"])
    {broken, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    broken = String.trim(broken)

    write = fn path, content ->
      full = Path.join([root, ".agents" | String.split(path, "/")])
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, JSON.encode!(content))
    end

    write.("evolution/environments/env-tiny.json", %{
      "id" => "env-tiny",
      "title" => "env-tiny",
      "statement" => "Tiny.value/0 answers :broken and the product is built on it.",
      "source" => %{
        "kind" => "fix_commit",
        "repository" => "self",
        "fix" => fix,
        "parent" => parent,
        "subject" => "the answer sheet",
        "bead" => nil
      },
      "verifier" => %{
        "kind" => "reverse_patch",
        "app" => "tiny",
        "files" => ["test/tiny_test.exs"],
        "source_paths" => ["apps/tiny/lib/tiny.ex"]
      },
      "set" => "benchmark",
      "verification" => %{
        "state" => "verified",
        "failed_before" => true,
        "passed_after" => true,
        "discrimination" => "assertion",
        "by" => "test",
        "by_attested" => false,
        "reason" => "because"
      },
      "verification_history" => []
    })

    # The evaluator fence fails closed and refuses everything when its own
    # policy cannot be read, which is correct and which a fixture tree has to
    # answer rather than work around.
    write.("policies/evaluators.json", %{
      "version" => 1,
      "doc" => "what a dispatched run may not land",
      "paths" => [
        %{
          "glob" => ".agents/policies/**",
          "why" => "an agent may not rewrite the policy that judges it"
        },
        # A test file is a judgement criterion. It is fenced here so that the
        # *scorer's own* deletion of the verifier would trip the fence if the
        # prepared state were not committed first — which is what calibrates
        # `prepared/7`, and which an earlier fixture could not do because its
        # policy protected nothing the preparation touches.
        %{"glob" => "apps/*/test/**", "why" => "an agent may not rewrite what judges it"},
        # Fenced and **not** exemptible: a scoring attempt may be exempted from
        # the harness's own modules and never from what says what passing means
        # outside the worktree it was given.
        %{
          "glob" => ".github/workflows/**",
          "why" => "what CI asks, and therefore what passing means"
        }
      ]
    })

    write.("runs/run-scoring.json", %{
      "id" => "run-scoring",
      "workflow" => "WF-010",
      "status" => "open",
      "steps" => [],
      "dispatches" => []
    })

    write.("evolution/candidates/cand-tiny.json", %{
      "id" => "cand-tiny",
      "target" => %{"kind" => "prompt", "ref" => "backend.engineer"},
      "hypothesis" => %{
        "weakness" => "w",
        "change" => "c",
        "disconfirming_evidence" => "d"
      },
      "created_by" => "evolution.evolution_director",
      "created_at" => "2026-09-21T00:00:00Z",
      "run" => "run-scoring",
      "family" => "prompt_policy",
      "application" => %{"kind" => "git_ref", "ref" => arm, "baseline" => baseline},
      "metrics" => %{"capability" => [], "efficiency" => ["solve_rate"]},
      "lineage" => %{"parents" => [], "generation" => 0},
      "stages" => %{},
      "fitness" => %{},
      "fitness_provenance" => %{},
      "status" => "proposed"
    })

    previous_root = Noetic.Harness.root_override()
    previous_path = System.get_env("PATH")
    Noetic.Harness.put_root(root)
    System.put_env("PATH", bin <> ":" <> previous_path)

    try do
      fun.(%{root: root, fix: fix, parent: parent, arm: arm, baseline: baseline, broken: broken})
    after
      if previous_root,
        do: Noetic.Harness.put_root(previous_root),
        else: Noetic.Harness.delete_root()

      System.put_env("PATH", previous_path)
      File.rm_rf!(root)
    end
  end

  defp candidate_path(root, id),
    do: Path.join([root, ".agents", "evolution", "candidates", "#{id}.json"])

  describe "the plan, which costs nothing" do
    test "it names the arms, the environments and what it would spend" do
      with_scoring_repo(fn %{arm: arm, baseline: baseline} ->
        {:ok, plan} = Scoring.plan("cand-tiny", "benchmark", run: "run-scoring")

        assert plan.arms == %{candidate: arm, baseline: baseline}
        assert plan.environments == ["env-tiny"]
        assert plan.dispatches == 2
        assert plan.refusals == []
      end)
    end

    test "a candidate with no application cannot be checked out, so it cannot be run" do
      with_scoring_repo(fn %{root: root} ->
        path = candidate_path(root, "cand-tiny")
        candidate = path |> File.read!() |> JSON.decode!() |> Map.delete("application")
        File.write!(path, JSON.encode!(candidate))

        {:ok, plan} = Scoring.plan("cand-tiny", "benchmark", run: "run-scoring")

        assert Enum.any?(plan.refusals, &(&1.rule == "application"))
        assert Enum.any?(plan.refusals, &(&1.why =~ "`target` is a label"))
      end)
    end

    test "an arm this repository cannot resolve is refused before anything is spent" do
      with_scoring_repo(fn %{root: root} ->
        path = candidate_path(root, "cand-tiny")

        candidate =
          path
          |> File.read!()
          |> JSON.decode!()
          |> put_in(["application", "baseline"], "no-such-commit")

        File.write!(path, JSON.encode!(candidate))

        {:ok, plan} = Scoring.plan("cand-tiny", "benchmark", run: "run-scoring")
        assert Enum.any?(plan.refusals, &(&1.why =~ "cannot resolve"))
      end)
    end

    test "a set with an unverified member cannot produce a number its own gate accepts" do
      with_scoring_repo(fn %{root: root} ->
        path =
          Path.join([root, ".agents", "evolution", "environments", "env-tiny.json"])

        environment =
          path
          |> File.read!()
          |> JSON.decode!()
          |> put_in(["verification", "state"], "unavailable")

        File.write!(path, JSON.encode!(environment))

        {:ok, plan} = Scoring.plan("cand-tiny", "benchmark", run: "run-scoring")
        assert Enum.any?(plan.refusals, &(&1.rule == "suite"))
      end)
    end

    test "an unknown set is not scored against" do
      with_scoring_repo(fn _ ->
        {:ok, plan} = Scoring.plan("cand-tiny", "holdouts", run: "run-scoring")
        assert Enum.any?(plan.refusals, &(&1.rule == "set"))
      end)
    end

    test "a budget that cannot cover the suite refuses before spending any of it" do
      with_scoring_repo(fn _ ->
        Application.put_env(:noetic_harness, :scoring_dispatch_usd, 100.0)
        on_exit(fn -> Application.delete_env(:noetic_harness, :scoring_dispatch_usd) end)

        {:ok, plan} = Scoring.plan("cand-tiny", "benchmark", run: "run-scoring")
        assert Enum.any?(plan.refusals, &(&1.rule == "budget"))
      end)
    end

    test "a measurement with no run to attribute it to is refused" do
      with_scoring_repo(fn %{root: root} ->
        # No `:run` option *and* no open run in the ledger. The first version
        # of this test passed only the first half and found the fixture's own
        # open run, which is `Run.current/0` working rather than the guard.
        File.rm!(Path.join([root, ".agents", "runs", "run-scoring.json"]))

        {:ok, plan} = Scoring.plan("cand-tiny", "benchmark", [])
        assert Enum.any?(plan.refusals, &(&1.rule == "run"))
      end)
    end
  end

  describe "the number measures solving and nothing else" do
    test "a candidate commit that weakens the verifier scores nothing for it" do
      with_scoring_repo(fn %{root: root, fix: fix} ->
        # The attack an independent review ran against the first version: the
        # candidate arm rewrites the environment's own test file, the verifier
        # is restored from *that arm*, and a solver that does nothing scores a
        # perfect benchmark gain with real provenance the gate accepts.
        git = fn args -> {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true) end

        git.(["checkout", "-q", "-b", "weakened", fix])
        File.write!(Path.join([root, "apps", "tiny", "test", "tiny_test.exs"]), "# nothing\n")
        git.(["add", "apps/tiny/test/tiny_test.exs"])
        git.(["commit", "-q", "-m", "a kinder oracle"])
        {weakened, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
        git.(["checkout", "-q", "main"])

        path = candidate_path(root, "cand-tiny")

        candidate =
          path
          |> File.read!()
          |> JSON.decode!()
          |> put_in(["application", "ref"], String.trim(weakened))

        File.write!(path, JSON.encode!(candidate))

        {:ok, result} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        # The oracle comes from the environment's fix commit, which is the same
        # for both arms, so weakening it in one arm buys nothing.
        assert result.delta == 0.0
      end)
    end

    test "a solver that makes the verifier pass without touching the task solves nothing" do
      with_scoring_repo(fn _ ->
        Application.put_env(:noetic_harness, :scoring_test_cheat, ["score:env-tiny:candidate"])

        {:ok, result} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        assert result.delta == 0.0

        # And it says what it took away rather than silently discarding it.
        candidate = Enum.find(result.attempts, &(&1.arm == :candidate))
        assert "apps/tiny/SHORTCUT" in candidate.reverted
      end)
    end

    test "an arm the environment's fix cannot be reached from is refused" do
      with_scoring_repo(fn %{root: root, parent: parent} ->
        # The guard that had no test at all: its own fixture was built so that
        # both arms descend from the fix, and nothing ever constructed the arm
        # that does not.
        path = candidate_path(root, "cand-tiny")

        candidate =
          path |> File.read!() |> JSON.decode!() |> put_in(["application", "baseline"], parent)

        File.write!(path, JSON.encode!(candidate))

        {:ok, plan} = Scoring.plan("cand-tiny", "benchmark", run: "run-scoring")

        assert Enum.any?(plan.refusals, &(&1.rule == "ancestry"))
        assert Enum.any?(plan.refusals, &(&1.why =~ "baseline arm"))
      end)
    end

    defp source_paths(root, paths) do
      path = Path.join([root, ".agents", "evolution", "environments", "env-tiny.json"])

      environment =
        path |> File.read!() |> JSON.decode!() |> put_in(["verifier", "source_paths"], paths)

      File.write!(path, JSON.encode!(environment))
    end

    test "a source path git would not spell that way cannot be an exemption" do
      # Not because a glob would widen anything — `paths -- task_paths` is
      # string subtraction, so it exempts nothing — but because
      # `Tree.confine/3`'s `keep` then matches nothing and reverts the
      # solver's correct fix, scoring `false` for both arms rather than
      # refusing. A wrong number is worse than a refusal.
      for bad <- ["apps/tiny/lib/**", "./apps/tiny/lib/tiny.ex", "apps/../etc/passwd"] do
        with_scoring_repo(fn %{root: root} ->
          source_paths(root, [bad])

          {:ok, plan} = Scoring.plan("cand-tiny", "benchmark", run: "run-scoring")

          assert Enum.any?(plan.refusals, &(&1.rule == "fence")),
                 "#{bad} was not refused"

          assert Enum.any?(plan.refusals, &(&1.why =~ "git does not spell a path that way"))
        end)
      end
    end

    test "a fenced source path the policy does not mark exemptible is refused early" do
      # The refusal an independent review showed the first narrowing had lost.
      # `Environments.derive/2` takes everything a commit changed except prose,
      # `.beads/` and `.agents/` — not `apps/*/lib/**.ex`, which is what the
      # first version's comment claimed — so a commit touching CI derives an
      # environment whose source paths are `.github/workflows/*.yml`, and the
      # exemption would have covered them.
      with_scoring_repo(fn %{root: root} ->
        source_paths(root, [".github/workflows/ci.yml"])

        {:ok, plan} = Scoring.plan("cand-tiny", "benchmark", run: "run-scoring")

        assert Enum.any?(plan.refusals, &(&1.rule == "fence"))
        assert Enum.any?(plan.refusals, &(&1.why =~ "does not mark exemptible"))
      end)
    end

    test "a run that is not in the ledger is refused, because the spend would vanish" do
      with_scoring_repo(fn _ ->
        {:ok, plan} = Scoring.plan("cand-tiny", "benchmark", run: "run-there-is-no-such-thing")

        assert Enum.any?(plan.refusals, &(&1.rule == "run"))
        assert Enum.any?(plan.refusals, &(&1.why =~ "never bind"))
      end)
    end
  end

  describe "an environment about a fenced file" do
    # The fixture's fence gains the file the task is about, which is the shape
    # of every environment derived from the harness's own history:
    # `environments.ex`, `evolution.ex`, `validation.ex`, `scoring.ex` and
    # `tree.ex` are all on the real fence, and before this the benchmark
    # silently excluded every environment about them.
    defp fence_the_source(root) do
      path = Path.join([root, ".agents", "policies", "evaluators.json"])
      policy = path |> File.read!() |> JSON.decode!()

      # `exemptible: true` is what the real policy carries on the ten harness
      # modules, and is what makes an environment about them scorable at all.
      rule = %{
        "glob" => "apps/tiny/lib/**",
        "why" => "an agent may not rewrite the thing that judges it",
        "exemptible" => true
      }

      File.write!(path, JSON.encode!(%{policy | "paths" => policy["paths"] ++ [rule]}))
    end

    test "is scored, rather than refused for the solver's own correct edit" do
      with_scoring_repo(fn %{root: root} ->
        fence_the_source(root)
        Application.put_env(:noetic_harness, :scoring_test_solve, ["score:env-tiny:candidate"])

        {:ok, result} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        assert result.outcome == "scored"
        assert result.delta == 1.0
      end)
    end

    test "and a solver that also edits the policy is still refused for that" do
      with_scoring_repo(fn %{root: root} ->
        fence_the_source(root)
        # The exemption is for the files the task named. This adapter solves
        # the task *and* rewrites the fence in the same diff, which is the
        # case an allow-list gets wrong if it is applied to the whole change
        # rather than subtracted from it.
        Application.put_env(:noetic_harness, :dispatch_adapter, PolicyEditingAdapter)

        {:ok, result} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        assert result.outcome == "partial"

        assert Enum.any?(result.attempts, fn attempt ->
                 attempt.solved == nil and attempt.why =~ "evaluator fence"
               end)
      end)
    end
  end

  describe "a solver that rewrites the oracle while it runs" do
    test "is unusable rather than solved" do
      # `mix test` compiles the solver's file before ExUnit loads the verifier,
      # so a module body in a source path is code the scoring host runs. An
      # independent review built this and scored `solved: true` on an untouched
      # defect. Detection, not containment: an earlier change.
      with_scoring_repo(fn _ ->
        Application.put_env(:noetic_harness, :dispatch_adapter, OracleRewritingAdapter)

        {:ok, result} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        # `partial` either way, and that is the invariant: an attempt whose
        # oracle was touched — or whose solver tried to touch it — is not a
        # measurement. What differs is *how* it was stopped, and the verdict
        # says which, because prevented and detected are different facts.
        assert result.outcome == "partial"

        expected =
          if Noetic.Harness.Tree.confined?(),
            do: "the sandbox refused it",
            else: "while it was being run"

        assert Enum.any?(result.attempts, fn attempt ->
                 attempt.solved == nil and attempt.why =~ expected
               end),
               "no attempt reported the rewrite. On this machine the boundary is " <>
                 "#{if Noetic.Harness.Tree.confined?(), do: "present", else: "absent"}, so the " <>
                 "expected reason was #{inspect(expected)}. Attempts: " <>
                 inspect(Enum.map(result.attempts, & &1.why))
      end)
    end
  end

  describe "a solver that asks git for the answer" do
    # Each a question whose answer is the fix or the verifier. The last three
    # are what a review of the first version found: the tree lived under the
    # host's `.git/`, and git, searching upward from `..`, found the host.
    @unanswered ~w(fix verifier_before verifier_blob answer parent_fix grandparent_fix
                   parent_git_dir)a

    test "finds neither the fix nor the verifier, in any commit or reflog entry" do
      with_scoring_repo(fn %{root: root, fix: fix, parent: parent, arm: arm, baseline: baseline} ->
        # The route an earlier change found and nothing closed: a worktree shares
        # its repository's objects, every arm has the fix in its history, and
        # this adapter, run against a worktree, scored both arms solved.
        {blob, 0} =
          System.cmd("git", ["rev-parse", "#{fix}:apps/tiny/test/tiny_test.exs"], cd: root)

        Application.put_env(:noetic_harness, :dispatch_adapter, HistoryReadingAdapter)

        Application.put_env(:noetic_harness, :scoring_test_history, %{
          onlooker: self(),
          fix: fix,
          blob: String.trim(blob)
        })

        solvers = fn ->
          Path.wildcard(Path.join(System.tmp_dir!(), "acme-solver-#{System.pid()}-*"))
        end

        before = solvers.()

        scoring_roots = fn ->
          Path.wildcard(Path.join(System.tmp_dir!(), "acme-score-#{System.pid()}-*"))
        end

        roots_before = scoring_roots.()

        {:ok, result} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        for arm_name <- [:candidate, :baseline] do
          label = "score:env-tiny:#{arm_name}"
          assert_received {:history, ^label, answers}

          for question <- @unanswered do
            assert {_, status} = answers[question]

            assert status != 0,
                   "#{arm_name}: git answered #{question}: #{inspect(answers[question])}"
          end

          for question <- [:log, :reflog] do
            {shas, 0} = answers[question]
            known = String.split(shas)

            assert length(known) == 1, "#{arm_name}: #{question} knows #{inspect(known)}"
            assert known -- [fix, parent, arm, baseline] == known
          end
        end

        # Asked for the answer and given none, it solves nothing — and the
        # number is still a measurement, not a refusal.
        assert result.outcome == "scored"
        assert result.rates.candidate == 0.0
        assert result.rates.baseline == 0.0

        # The solver's repository is deleted when the solver returns, and so
        # is the directory its tree was opened in.
        assert solvers.() -- before == []
        assert scoring_roots.() -- roots_before == []
      end)
    end

    test "inherits no GIT_DIR, GIT_WORK_TREE or GIT_OBJECT_DIRECTORY that names the host" do
      with_scoring_repo(fn %{root: root, fix: fix} ->
        {blob, 0} =
          System.cmd("git", ["rev-parse", "#{fix}:apps/tiny/test/tiny_test.exs"], cd: root)

        # What a git hook exports, or a person's shell: each alone points a
        # `git` in the solver's tree at the host's history. With
        # `GIT_OBJECT_DIRECTORY` the severed repository's own `cat-file`
        # reads the host's objects.
        host = %{
          "GIT_DIR" => Path.join(root, ".git"),
          "GIT_WORK_TREE" => root,
          "GIT_OBJECT_DIRECTORY" => Path.join([root, ".git", "objects"])
        }

        System.put_env(host)
        on_exit(fn -> Enum.each(Map.keys(host), &System.delete_env/1) end)

        Application.put_env(:noetic_harness, :dispatch_adapter, HistoryReadingAdapter)

        Application.put_env(:noetic_harness, :scoring_test_history, %{
          onlooker: self(),
          fix: fix,
          blob: String.trim(blob)
        })

        {:ok, result} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        for arm_name <- [:candidate, :baseline] do
          label = "score:env-tiny:#{arm_name}"
          assert_received {:history, ^label, answers}

          inherited = Enum.filter(answers.env, &String.starts_with?(&1, Map.keys(host)))
          assert inherited == [], "#{arm_name}: the solver inherited #{inspect(inherited)}"

          for question <- @unanswered do
            assert {_, status} = answers[question]

            assert status != 0,
                   "#{arm_name}: git answered #{question}: #{inspect(answers[question])}"
          end
        end

        assert result.outcome == "scored"
        assert result.rates.candidate == 0.0
        assert result.rates.baseline == 0.0

        # And the harness's own environment is what it was.
        assert Map.take(System.get_env(), Map.keys(host)) == host
      end)
    end

    test "inherits no GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM or GIT_CONFIG" do
      with_scoring_repo(fn %{root: root, fix: fix} ->
        {blob, 0} =
          System.cmd("git", ["rev-parse", "#{fix}:apps/tiny/test/tiny_test.exs"], cd: root)

        # Each names a file of configuration from outside the tree, as
        # `GIT_CONFIG_PARAMETERS` and `GIT_CONFIG_COUNT` carry it inline, and
        # git reads each alone. A file written next to the host's checkout
        # stands for the person's, or the host's own.
        host =
          for {var, origin} <- [
                {"GIT_CONFIG_GLOBAL", "global"},
                {"GIT_CONFIG_SYSTEM", "system"},
                {"GIT_CONFIG", "config"}
              ],
              into: %{} do
            path = Path.join(Path.dirname(root), "#{Path.basename(root)}-#{origin}.gitconfig")
            File.write!(path, "[harness \"test\"]\n\torigin = #{origin}\n")
            {var, path}
          end

        System.put_env(host)

        on_exit(fn ->
          Enum.each(Map.keys(host), &System.delete_env/1)
          Enum.each(Map.values(host), &File.rm/1)
        end)

        Application.put_env(:noetic_harness, :dispatch_adapter, HistoryReadingAdapter)

        Application.put_env(:noetic_harness, :scoring_test_history, %{
          onlooker: self(),
          fix: fix,
          blob: String.trim(blob)
        })

        {:ok, result} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        for arm_name <- [:candidate, :baseline] do
          label = "score:env-tiny:#{arm_name}"
          assert_received {:history, ^label, answers}

          inherited =
            Enum.filter(answers.env, fn line ->
              Enum.any?(Map.keys(host), &String.starts_with?(line, &1 <> "="))
            end)

          assert inherited == [], "#{arm_name}: the solver inherited #{inspect(inherited)}"

          assert {_, status} = answers.config
          assert status != 0, "#{arm_name}: git read #{inspect(answers.config)}"
        end

        assert result.outcome == "scored"

        # And the harness's own environment is what it was.
        assert Map.take(System.get_env(), Map.keys(host)) == host
      end)
    end
  end

  describe "a scoring run that is the candidate's own" do
    test "a held-out set it may not record still returns the numbers it measured" do
      with_scoring_repo(fn %{root: root} ->
        # The environment moves to the holdout set, and the scoring run IS the
        # run the candidate was proposed in. `record_stage/3` refuses; the
        # measurement still happened and is returned rather than thrown away.
        path = Path.join([root, ".agents", "evolution", "environments", "env-tiny.json"])
        environment = path |> File.read!() |> JSON.decode!() |> Map.put("set", "holdout")
        File.write!(path, JSON.encode!(environment))

        Application.put_env(:noetic_harness, :scoring_test_solve, ["score:env-tiny:candidate"])

        {:ok, result} = Scoring.score("cand-tiny", "holdout", run: "run-scoring")

        assert result.outcome == "measured"
        assert result.delta == 1.0
        assert result.why =~ "the ledger would not take them"
        assert result.why =~ "the candidate's own"

        {:ok, candidate} = Evolution.fetch("cand-tiny")
        assert candidate["fitness"] == %{}
      end)
    end

    test "an unrelated run may record the same held-out measurement" do
      with_scoring_repo(fn %{root: root} ->
        path = Path.join([root, ".agents", "evolution", "environments", "env-tiny.json"])
        environment = path |> File.read!() |> JSON.decode!() |> Map.put("set", "holdout")
        File.write!(path, JSON.encode!(environment))

        File.write!(
          Path.join([root, ".agents", "runs", "run-other.json"]),
          JSON.encode!(%{
            "id" => "run-other",
            "workflow" => "WF-010",
            "status" => "open",
            "steps" => [],
            "dispatches" => []
          })
        )

        Application.put_env(:noetic_harness, :scoring_test_solve, ["score:env-tiny:candidate"])

        {:ok, result} = Scoring.score("cand-tiny", "holdout", run: "run-other")

        assert result.outcome == "scored"

        {:ok, candidate} = Evolution.fetch("cand-tiny")
        assert candidate["fitness"]["holdout"] == 1.0
        assert Evolution.held_out_by_its_own_run(candidate) == []
      end)
    end
  end

  describe "an adapter that runs nothing" do
    test "is refused, because every arm would score zero and so would the delta" do
      with_scoring_repo(fn _ ->
        Application.delete_env(:noetic_harness, :dispatch_adapter)
        Application.put_env(:noetic_harness, :dispatch_adapter_id, "null")

        on_exit(fn -> Application.delete_env(:noetic_harness, :dispatch_adapter_id) end)

        {:ok, plan} = Scoring.plan("cand-tiny", "benchmark", run: "run-scoring")

        assert Enum.any?(plan.refusals, &(&1.rule == "adapter"))

        assert Enum.any?(
                 plan.refusals,
                 &(&1.why =~ "what a candidate that changed nothing scores")
               )
      end)
    end
  end

  describe "running it" do
    test "the solver never sees the verifier, and the verdict still uses it" do
      with_scoring_repo(fn _ ->
        # The fake `mix` exits 1 with a `** (Mix)` line when the verifier file
        # is absent, so if the restore did not happen every attempt would be
        # unusable and the run would be partial rather than scored.
        Application.put_env(:noetic_harness, :scoring_test_solve, ["score:env-tiny:candidate"])

        {:ok, result} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        assert result.outcome == "scored"
        assert result.rates.candidate == 1.0
        assert result.rates.baseline == 0.0
        assert result.delta == 1.0
      end)
    end

    test "a solver that solves neither arm scores a delta of zero, which is a real result" do
      with_scoring_repo(fn _ ->
        {:ok, result} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        assert result.outcome == "scored"
        assert result.delta == 0.0
      end)
    end

    test "the number is written with the run and the environments that produced it" do
      with_scoring_repo(fn %{root: root} ->
        Application.put_env(:noetic_harness, :scoring_test_solve, ["score:env-tiny:candidate"])

        {:ok, _} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        {:ok, candidate} = Evolution.fetch("cand-tiny")

        assert candidate["fitness"]["benchmark"] == 1.0
        assert candidate["fitness_provenance"]["benchmark"]["run"] == "run-scoring"
        assert candidate["fitness_provenance"]["benchmark"]["environments"] == ["env-tiny"]

        # And the gate that reads it accepts it — which is the whole point of
        # the two beads being built in this order.
        refute Enum.any?(Evolution.unmeasured(candidate), &(&1 =~ "benchmark"))

        _ = root
      end)
    end

    test "an attempt that produced no usable observation makes the run partial and writes nothing" do
      with_scoring_repo(fn %{root: root, broken: broken} ->
        # One arm whose build fails. `mix test` exits non-zero exactly as a
        # detected defect does, and reading that as "not solved" would make the
        # delta a measurement of the build rather than of the candidate.
        path = candidate_path(root, "cand-tiny")

        candidate =
          path |> File.read!() |> JSON.decode!() |> put_in(["application", "baseline"], broken)

        File.write!(path, JSON.encode!(candidate))

        {:ok, result} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        assert result.outcome == "partial"
        assert result.why =~ "no usable observation"
        assert result.why =~ "the build failed before the verifier ran"

        {:ok, candidate} = Evolution.fetch("cand-tiny")
        assert candidate["fitness"] == %{}
        assert candidate["fitness_provenance"] == %{}
      end)
    end

    test "the environments it scored are the set's verified members, not a subset" do
      with_scoring_repo(fn _ ->
        {:ok, result} = Scoring.score("cand-tiny", "benchmark", run: "run-scoring")

        assert result.provenance["environments"] ==
                 Environments.suite("benchmark") |> Enum.map(& &1["id"]) |> Enum.sort()
      end)
    end
  end
end
