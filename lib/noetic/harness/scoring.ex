defmodule Noetic.Harness.Scoring do
  @moduledoc """
  Run a candidate against an environment set, and produce the number from what
  happened.

  This is the joint. Thirteen environments were derived from this
  repository's own fix commits and eight verify; `Evolution`'s promotion gate
  reads three set-keyed fitness values; and until this module there was nothing
  in between, so those values were whatever somebody typed. `Evolution.
  unmeasured/1` refuses a typed one — that gate was written first on purpose —
  which means that until this ran, **no set-keyed number could legitimately be
  promoted at all**. That was the honest state, and this is what ends it.

  ## Two arms, and why a candidate has to be a commit

  A candidate's `target` is a label: `%{kind: "prompt", ref: "backend.engineer"}`.
  You cannot make a label present in a working tree. So scoring requires

      "application": {"kind": "git_ref", "ref": "<sha>", "baseline": "<sha>"}

  and runs the same environments through two worktrees, one at each. The
  fitness value for the set is `candidate_rate - baseline_rate`. A field an
  agent can write without doing anything is the one thing this must not rest
  on; a commit either exists or it does not.

  ## What a solver sees, and what it does not

  Per environment, per arm: open a worktree at that arm's commit **outside
  the repository**, reverse-apply the fix so the defect is present, **delete
  the verifier files**, commit that, **give the tree a history of its own**,
  prepare it (`Noetic.Harness.Tree`), and hand the agent
  `Environments.brief/1` and the tree. Then restore the verifier from the
  environment's fix commit and run it (`verdict/5` says why the fix and not
  the arm).

  Deleting the verifier is what an earlier change could only narrow. `brief/1` is an
  allow-list over what a solver is *handed*; the oracle was still on disk, one
  `cat` away. In a scoring tree it is not on disk.

  **And it was not out of the tree's history until an earlier change.** A worktree
  shares its repository's objects, and the arm must have the fix in its
  history (`ancestry_refusals/2`), so `git show <fix>` or
  `git show HEAD~1:<verifier>` handed the solver the answer. This moduledoc
  said "it is not there" all the same. Now `Tree.sever/2` points the tree's
  `.git` at a repository holding one commit, the prepared tree, and checks
  that neither the fix nor the verifier's content is an object in it before
  the agent is called. The host still reads the arm's history, through the
  admin directory it registered, and the tree goes back to it when the agent
  returns.

  **And the tree's parent still held it, which a review of that version
  found.** The tree lived under the host's `.git/`, git searches upward, and
  `git -C .. show <fix>` returned the verifier. The arm's worktree is now
  opened under `Tree.solver_root/0`, a private temporary directory that no
  repository encloses, and `Tree.sever/2` refuses a tree whose parent is
  inside one. The solver's process gets no `GIT_DIR`, `GIT_WORK_TREE` or
  `GIT_OBJECT_DIRECTORY` from this VM either, and no `GIT_CONFIG_GLOBAL`,
  `GIT_CONFIG_SYSTEM` or `GIT_CONFIG` (`Tree.without_git_env/1`).
  What that does not close is below: the host's repository is still on the
  same disk.

  ## What it refuses, which is most of this module

  - **The null adapter.** An agent that runs nothing solves nothing, every arm
    scores zero, and the delta is zero — a number indistinguishable from "the
    candidate changed nothing". §33.
  - **A set that is not wholly verified**, or is empty. `Evolution.unmeasured/1`
    requires the recorded environments to be *exactly* the set's verified
    members, so a run over anything else produces a number its own gate will
    refuse.
  - **A budget that cannot cover the whole set.** Scoring is per *set*: today
    that is three benchmark members, three holdout and two transfer, so six,
    six and four dispatches — about $1.02, $1.02 and $0.68 at the $0.17 a
    dispatch this repository has actually measured. (An earlier version of this
    sentence said "eight environments across two arms is sixteen dispatches",
    which is the total across all three sets and is never one run. The code was
    right and the sentence telling a reader what it costs was wrong by 2.7×.)
  - **An environment the fence will refuse anyway.** See below: it is checked
    before the money rather than discovered after it.
  - **Itself, half way.** If the budget, a stop, a refusal or a broken build
    ends the run mid-suite, the outcome is `partial` and **no fitness value is
    written**. A rate over a prefix of the suite is a different quantity
    wearing the same name, and `Evolution.unmeasured/1` would refuse it anyway
    — but a module that writes a number it knows is wrong and relies on a gate
    to catch it is a module that will eventually be read as authoritative.

  ## The fence, and what it costs here

  A scoring attempt is a dispatched run, so `Fence.refuse/1` judges what it
  changed. Two consequences, and the second is a real limitation rather than a
  detail.

  The tree is **committed after it is prepared** — the defect reintroduced, the
  verifier deleted — so the fence sees what the *solver* did and not what the
  scorer did to set the task up. Without that it refused every attempt for the
  scorer's own deletion of the oracle, which this module's tests caught before
  it had ever been run for real.

  `Tree.confine/3` reverts what the solver changed outside the task's paths —
  **tracked** files only. A `.beam` under `_build`, or anything else git
  ignores, is neither judged by the fence nor reverted, which an independent
  review demonstrated; an earlier change is that residual.

  And an environment whose `verifier.source_paths` are themselves on the fence
  — `environments.ex`, `evolution.ex`, `validation.ex`, `scoring.ex` and
  `tree.ex` all are — used to be **unscorable**, because the solver's own
  legitimate edit was refused after the money had been spent. That was
  An earlier change, and it excluded exactly the environments about the harness
  itself: the half a self-developing loop most needs to be measured on.

  The attempt now carries those paths as an exemption and the fence judges
  everything else, including when the two arrive in the same diff. The
  argument for why that is narrow enough is in `Dispatcher.attempt/3`.

  **A scoring worktree is not a containment boundary**, and this moduledoc
  said it was until an independent review built the counter-example. The
  verifier is deleted before the solver arrives and restored from the
  environment's own `source.fix`, which stops the *arm* from supplying its own
  oracle — but `mix test` compiles the solver's file before ExUnit loads the
  test, so a module body in a source path is code this host runs. The review's
  probe rewrote the restored verifier from the top of the file it was asked to
  fix and scored `solved: true` on an untouched defect, with `Tree.confine/3`
  reporting nothing reverted because the write went outside the tree.

  `verdict/5` now hashes the verifier before and after the run and calls a
  mismatch **unusable**. That catches the naive case; a solver that puts the
  bytes back before exiting defeats it, and what would not be defeated is a
  sandbox. The claim made here is the one that is true: this
  measures well when the thing being measured is trying to be measured, which
  is the ordinary case, and it is not adversarially safe.

  The same is true of the answer. Neither the tree's history nor anything
  above it holds it, but the host's repository is on the same disk, and
  `deps` is a symlink into the host's checkout: `git -C deps/.. show <fix>`
  finds it. A solver that goes looking for the repository it was cut from,
  through that link, by its path or through `/proc/$PPID/cwd`, finds the fix
  there, and only a sandbox that hides the host stops it (`Tree.sever/2`).

  ## A broken build is not a solver that failed

  `Tree.environmental?/1` again, and for the same reason it was needed in
  verification: `mix test` exits non-zero when the verifier detects something
  *and* when `mix` never reached it. An arm whose worktree fails to compile a
  dependency would otherwise score zero and the delta would be a measurement of
  the build. Those attempts are `nil` — unusable — and one of them makes the
  whole run partial.
  """

  alias Noetic.Harness.{Dispatcher, Environments, Evolution, Fence, Run, Tree, Workspace}

  # What one dispatch is assumed to cost when planning. Not a guess: the first
  # dispatch this repository ran against a real model — WF-002's `context`
  # step, T0, haiku, `--restricted` — was 13 turns and **$0.17**. It is an
  # estimate for a *refusal before spending*, never for a record of what was
  # spent; that comes from the adapter through `Run.spend/2`.
  @observed_usd 0.17

  @type arm :: :candidate | :baseline

  @doc """
  Resolve a scoring run without running it.

  Every refusal `score/3` can make is computed here, so "would this be allowed,
  and what would it cost" is answerable for free. `noetic-harness evolution
  --score <id> --set benchmark --plan` is this.
  """
  @spec plan(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def plan(candidate_id, set, opts \\ []) do
    with {:ok, candidate} <- fetch(candidate_id) do
      environments = Environments.suite(set)
      dispatches = 2 * length(environments)

      {:ok,
       %{
         candidate: candidate_id,
         set: set,
         arms: arms(candidate),
         environments: Enum.map(environments, & &1["id"]),
         dispatches: dispatches,
         estimated_usd: Float.round(dispatches * per_dispatch_usd(), 2),
         ceiling_usd: Dispatcher.cost_ceiling(),
         adapter: Dispatcher.adapter() || Application.get_env(:noetic_harness, :dispatch_adapter),
         refusals: refusals(candidate, set, environments, opts)
       }}
    end
  end

  @doc """
  Run it, and write the number only if the whole suite was scored.

  Returns `{:ok, result}` where `result.outcome` is `"scored"` or `"partial"`,
  or `{:refused, reasons}`. A `"partial"` result carries every attempt it did
  make — the evidence is not discarded along with the number — and writes no
  fitness.
  """
  @spec score(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:refused, [map()]} | {:error, String.t()}
  def score(candidate_id, set, opts \\ []) do
    with {:ok, plan} <- plan(candidate_id, set, opts) do
      case plan.refusals do
        [] -> run(plan, opts)
        refusals -> {:refused, refusals}
      end
    end
  end

  # ---- refusals --------------------------------------------------------------

  defp refusals(candidate, set, environments, opts) do
    List.flatten([
      set_refusal(set),
      suite_refusals(set, environments),
      application_refusals(candidate),
      adapter_refusal(),
      ancestry_refusals(candidate, environments),
      fence_refusals(environments),
      budget_refusals(environments),
      run_refusal(opts)
    ])
  end

  defp set_refusal(set) do
    if set in Environments.sets() do
      []
    else
      [
        %{
          rule: "set",
          why: "#{inspect(set)} is not a set: #{Enum.join(Environments.sets(), ", ")}"
        }
      ]
    end
  end

  # `Evolution.unmeasured/1` requires the recorded environments to be exactly
  # the set's currently verified members. A set holding an `unavailable` member
  # therefore cannot be scored into a number its own gate will accept, and
  # saying so here is better than producing one and watching it be refused.
  defp suite_refusals(set, environments) do
    assigned = Environments.list(set: set, kind: "reverse_patch")
    unverified = Enum.reject(assigned, &(Environments.state(&1) == "verified"))

    cond do
      environments == [] ->
        [
          %{
            rule: "suite",
            why:
              "the #{set} set has no currently verified members, so there is nothing to score " <>
                "against. `noetic-harness environments --verify <id>` is how a member comes back"
          }
        ]

      unverified != [] ->
        [
          %{
            rule: "suite",
            why:
              "#{Enum.map_join(unverified, ", ", & &1["id"])} #{verb(unverified)} in the " <>
                "#{set} set and not verified. A number measured over the rest is a rate over " <>
                "part of a suite, which `Evolution.unmeasured/1` refuses"
          }
        ]

      true ->
        []
    end
  end

  defp application_refusals(candidate) do
    case candidate["application"] do
      %{"kind" => "git_ref", "ref" => ref, "baseline" => baseline}
      when is_binary(ref) and is_binary(baseline) ->
        Enum.flat_map([{"ref", ref}, {"baseline", baseline}], fn {name, value} ->
          case Workspace.resolvable?(value) do
            true ->
              []

            false ->
              [
                %{
                  rule: "application",
                  why:
                    "application.#{name} is #{inspect(value)}, which this repository cannot " <>
                      "resolve to a commit. A candidate is scored by checking it out, so it " <>
                      "has to be something git can find"
                }
              ]
          end
        end)

      nil ->
        [
          %{
            rule: "application",
            why:
              "this candidate has no `application`, so there is nothing to check out. " <>
                "`target` is a label; scoring needs " <>
                ~s|`{"kind": "git_ref", "ref": "<sha>", "baseline": "<sha>"}`|
          }
        ]

      other ->
        [
          %{
            rule: "application",
            why: "application is #{inspect(other)}; only `kind: \"git_ref\"` can be run"
          }
        ]
    end
  end

  # §33, and the refusal that would otherwise produce the most convincing lie:
  # the null adapter returns without calling anything, so every arm scores
  # zero, the delta is zero, and zero is exactly what a candidate that changed
  # nothing would score.
  defp adapter_refusal do
    module = Dispatcher.adapter()

    if module in [nil, Dispatcher.NullAdapter] and null_configured?() do
      [
        %{
          rule: "adapter",
          why:
            "the dispatch adapter runs nothing, so every arm would score zero and the delta " <>
              "would be zero — which is also what a candidate that changed nothing scores. " <>
              "Configure an adapter that calls a model"
        }
      ]
    else
      []
    end
  end

  defp null_configured? do
    Dispatcher.adapter() == Dispatcher.NullAdapter or
      (is_nil(Dispatcher.adapter()) and
         Application.get_env(:noetic_harness, :dispatch_adapter_id) in [nil, "null"])
  end

  # An arm from which an environment's fix commit is not reachable cannot have
  # that defect reintroduced: `git apply --reverse` has nothing to reverse.
  # Both arms are versions of the *harness*, and the environments are drawn
  # from this same repository's history, so this is a real possibility rather
  # than a theoretical one — a candidate branched before a fix landed is
  # exactly the shape. Asked here, so it costs nothing to find out.
  defp ancestry_refusals(candidate, environments) do
    arms = arms(candidate)

    for {arm, ref} <- arms,
        environment <- environments,
        fix = environment["source"]["fix"],
        not Tree.ancestor?(fix, ref) do
      %{
        rule: "ancestry",
        why:
          "#{environment["id"]}'s fix #{String.slice(fix, 0, 8)} is not reachable from the " <>
            "#{arm} arm, so its defect cannot be reintroduced there and the two arms would " <>
            "not be answering the same question"
      }
    end
  end

  # The fence still has something to say about an environment, and it is no
  # longer "every fenced source path cannot be scored".
  #
  # `Dispatcher.attempt/3` is given the environment's own `source_paths` as an
  # exemption, so a solver editing the file it was asked to fix
  # is not refused for it. Two things are still refused here, before anything
  # is spent, and an independent review supplied both:
  #
  # **A fenced path the policy has not marked `exemptible`.** The first version
  # of this narrowing refused only a pattern, on the stated grounds that
  # `Environments.derive/2` takes `apps/*/lib/**.ex`. It does not —
  # `commit_paths/1` takes everything the commit changed except prose,
  # `.beads/` and `.agents/` — and a commit of the repository it was developed
  # in derives an environment whose source paths are `.github/workflows/ci.yml`
  # and `release.yml`. The old refusal caught it; the narrowed one did not.
  #
  # **A source path git would never emit in a diff.** A pattern, a `./`
  # prefix, a `..`, an absolute path. It exempts nothing, and worse,
  # `Tree.confine/3`'s `keep` then matches nothing and reverts the solver's
  # correct fix — scoring `false` for both arms rather than refusing.
  #
  # Both were discovered late once before: `env-evolution-one-way-rejection`
  # is a verified benchmark member, and before any of this `--plan` printed
  # "refusals: []" and "$1.02" for a run that could not produce a number.
  defp fence_refusals(environments) do
    Enum.flat_map(environments, fn environment ->
      paths = environment["verifier"]["source_paths"] || []

      unexemptible =
        Enum.map(Fence.unexemptible(paths), fn %{path: path, why: why} ->
          %{
            rule: "fence",
            why:
              "#{environment["id"]} is solved by editing #{path}, which the evaluator fence " <>
                "protects and does not mark exemptible: #{why}. A scoring attempt may be " <>
                "exempted from the harness's own modules and never from what says what " <>
                "passing means outside the worktree"
          }
        end)

      misspelt =
        case Enum.filter(paths, &unspellable?/1) do
          [] ->
            []

          bad ->
            [
              %{
                rule: "fence",
                why:
                  "#{environment["id"]} names #{Enum.join(bad, ", ")} as a source path, and " <>
                    "git does not spell a path that way in a diff — the exemption would cover " <>
                    "nothing and the solver's own fix would be reverted, scoring false for " <>
                    "both arms rather than refusing"
              }
            ]
        end

      unexemptible ++ misspelt
    end)
  end

  defp unspellable?(path) do
    path == "" or String.contains?(path, "*") or String.starts_with?(path, "./") or
      ".." in Path.split(path) or String.starts_with?(path, "/")
  end

  defp budget_refusals(environments) do
    dispatches = 2 * length(environments)
    estimated = dispatches * per_dispatch_usd()

    if estimated > Dispatcher.cost_ceiling() do
      [
        %{
          rule: "budget",
          why:
            "#{length(environments)} environments across two arms is #{dispatches} dispatches, " <>
              "about $#{Float.round(estimated, 2)} at the $#{per_dispatch_usd()} a dispatch " <>
              "this repository has actually measured — over the $#{Dispatcher.cost_ceiling()} " <>
              "ceiling in .agents/policies/dispatch.json. A run that cannot finish the suite " <>
              "produces no number, so it is refused before it spends anything"
        }
      ]
    else
      []
    end
  end

  defp run_refusal(opts) do
    case run_id(opts) do
      {:ok, _} ->
        []

      :error ->
        [
          %{
            rule: "run",
            why:
              "a measurement has to be attributable to a run that exists, and this one does " <>
                "not — `Run.spend/2` would discard every cost silently and the ceiling would " <>
                "never bind. `noetic-harness run --start` first, or pass an id from the ledger"
          }
        ]
    end
  end

  # `Run.exists?/1`, not merely "a non-empty string". `Evolution.unmeasured/1`
  # already asks this of the provenance it reads, and the two modules
  # disagreeing about the same string is what an independent review found:
  # a run id that does not resolve made `Run.spend/2` fail silently inside
  # `landed/6`, so the recorded spend stayed at zero and the in-flight cost
  # ceiling could never bind. The cheap check was the one left out, and it was
  # on the wrong side of the money.
  defp run_id(opts) do
    case Keyword.fetch(opts, :run) do
      {:ok, id} when is_binary(id) ->
        if Run.exists?(id), do: {:ok, id}, else: :error

      _ ->
        case Run.current() do
          {:ok, run} -> {:ok, run["id"]}
          _ -> :error
        end
    end
  end

  # ---- running ---------------------------------------------------------------

  defp run(plan, opts) do
    {:ok, run} = run_id(opts)
    {:ok, candidate} = fetch(plan.candidate)
    environments = Enum.map(plan.environments, &Environments.fetch/1)

    attempts =
      for {:ok, environment} <- environments,
          {arm, ref} <- Enum.to_list(plan.arms),
          do: attempt(environment, arm, ref, run, opts)

    settle(plan, candidate, attempts, run, opts)
  end

  # The arm's worktree is opened outside the repository, not under
  # `Workspace.root/0`: that is the host's `.git/`, and from a tree there
  # `git -C .. show <fix>` read the answer (`Tree.solver_root/0`).
  defp attempt(environment, arm, ref, run, opts) do
    label = "score:#{environment["id"]}:#{arm}"
    id = "#{label}-#{System.pid()}-#{:erlang.unique_integer([:positive])}"

    case Tree.solver_root() do
      {:error, reason} ->
        unusable(environment, arm, "could not isolate the arm: #{reason}")

      {:ok, root} ->
        try do
          opened(environment, arm, ref, run, opts, String.replace(id, ":", "-"), root)
        after
          File.rm_rf(root)
        end
    end
  end

  defp opened(environment, arm, ref, run, opts, id, root) do
    case Workspace.open(id, base: ref, root: root) do
      {:error, reason} ->
        unusable(environment, arm, "could not isolate the arm: #{reason}")

      {:ok, workspace} ->
        try do
          solve(environment, arm, ref, workspace, run, opts)
        after
          Workspace.close(workspace, discard: true)
        end
    end
  end

  # The verifier's files are under the app's directory, which is the
  # project's layout to say (`Noetic.Harness.Project.layout/0`).
  defp solve(environment, arm, ref, workspace, run, opts) do
    case Noetic.Harness.Project.layout() do
      nil -> unusable(environment, arm, Noetic.Harness.Project.no_layout())
      layout -> solve(environment, arm, ref, workspace, run, opts, layout)
    end
  end

  defp solve(environment, arm, ref, workspace, run, opts, layout) do
    verifier = environment["verifier"]
    app_dir = Path.join(layout.apps, verifier["app"])
    files = Enum.map(verifier["files"], &Path.join(app_dir, &1))

    case Tree.reverse_patch(
           workspace.path,
           environment["source"]["fix"],
           verifier["source_paths"]
         ) do
      {:error, reason} ->
        unusable(environment, arm, "the defect could not be reintroduced: #{reason}")

      :ok ->
        # The oracle leaves the tree before the solver arrives, and comes back
        # from the *environment's* fix commit before the verdict is taken.
        Tree.remove(workspace.path, files)
        prepared(environment, arm, ref, workspace, files, run, opts)
    end
  end

  # The prepared state is committed, so that the evaluator fence judges what
  # the *solver* did and not what the scorer did to set the task up. Without
  # this the fence refused every attempt, correctly, for the scorer's own
  # deletion of the verifier — found by this module's own tests before it had
  # ever been run for real.
  defp prepared(environment, arm, _ref, workspace, files, run, _opts) do
    case Tree.commit(workspace.path, "scoring: the defect, without its verifier") do
      {:error, reason} ->
        unusable(environment, arm, "the prepared tree could not be committed: #{reason}")

      {:ok, sha} ->
        # The solver gets a history of its own before anything else is put in
        # the tree: one commit, this one's files, and not the fix or the
        # verifier (`Tree.sever/2`).
        case Tree.sever(workspace.path, hidden(environment, files)) do
          {:error, reason} ->
            unusable(
              environment,
              arm,
              "the solver's tree could not be given a history of its own: #{reason}"
            )

          {:ok, severed} ->
            # `deps` and `_build` arrive *after* the commit, and this order is
            # not cosmetic. `Tree.commit/2` uses `git add -A`, `.gitignore`
            # says `/deps/` — a directory pattern — and `prepare/1` makes
            # `deps` a symlink, so a prepared commit taken afterwards contained
            # a symlink holding the caller's absolute path. A home directory
            # and a username in a git object is exactly the leak
            # `Environments.squeeze/1` exists to prevent. Found by an
            # independent review; no test could see it, because the fixture
            # repository has no `deps/`.
            Tree.prepare(workspace)

            dispatch_then_verify(
              environment,
              arm,
              %{workspace | base: sha},
              files,
              run,
              severed
            )
        end
    end
  end

  # What the solver's repository must not hold: the fix, and each verifier
  # file as the fix has it, which is the oracle `verdict/5` restores.
  defp hidden(environment, files) do
    fix = environment["source"]["fix"]
    [fix | Enum.map(files, &"#{fix}:#{&1}")]
  end

  # The options reaching the dispatcher are built here, not forwarded. An
  # independent review pointed out that passing the caller's `opts` through
  # let a caller hand a scoring attempt a trust of its choosing, which is
  # `Policy.derive_trust/3`'s whole job — "there is no path by which a parent
  # hands a child more than it holds" — routed around. A solver in a throwaway
  # tree is T2, and that is not a parameter.
  #
  # The tree goes back to the host's history the moment the solver returns,
  # whatever it returned. Its result is not read: the host never reads a
  # tree's `.git` (`Workspace.tree_git/1`), and `Workspace.close/2` repairs a
  # `.git` that does not point home, so a tree that could not be rejoined is
  # still measured and still removed.
  #
  # The solver's process starts without a `GIT_DIR`, `GIT_WORK_TREE` or
  # `GIT_OBJECT_DIRECTORY` of this VM's (`Tree.without_git_env/1`): any of
  # them naming the host gives a severed tree the host's history back. Nor
  # does it get the VM's `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM` or
  # `GIT_CONFIG`, each a file of configuration from outside the tree.
  defp dispatch_then_verify(environment, arm, workspace, files, run, severed) do
    label = "score:#{environment["id"]}:#{arm}"

    dispatched =
      try do
        Tree.without_git_env(fn ->
          Dispatcher.attempt(run, prompt(environment, workspace.path),
            workspace: workspace,
            label: label,
            trust: "T2",
            # The files the task named. Everything else the solver touched is
            # still judged by the evaluator fence, and `Tree.confine/3` reverts
            # it a moment later regardless.
            task_paths: environment["verifier"]["source_paths"] || []
          )
        end)
      after
        Tree.rejoin(severed)
      end

    case dispatched do
      {:refused, refusals} ->
        unusable(environment, arm, "the dispatch was refused: #{explain(refusals)}")

      {:error, reason} ->
        unusable(environment, arm, "the agent could not be called: #{inspect(reason)}")

      {:ok, _result} ->
        confined(environment, arm, workspace, files)
    end
  end

  # Everything the solver changed outside the paths the task named goes back.
  # See `Tree.confine/3`: without it, rewriting `test_helper.exs` to exclude
  # the failing test made `mix` exit 0 and scored as a solve.
  defp confined(environment, arm, workspace, files) do
    keep = environment["verifier"]["source_paths"]

    case Tree.confine(workspace.path, workspace.base, keep) do
      {:error, reason} ->
        unusable(environment, arm, "the change could not be confined: #{reason}")

      {:ok, reverted} ->
        verdict(environment, arm, workspace, files, reverted)
    end
  end

  # **The oracle belongs to the environment, not to the arm.** It used to be
  # restored from each arm's own commit, and an independent review showed what
  # that meant: a candidate commit that weakens the environment's test file
  # scores a perfect benchmark gain — real run id, exact verified member list,
  # `Evolution.unmeasured/1` satisfied — having solved nothing. Everything
  # about the number was genuine except what it measured.
  #
  # `source.fix` is reachable from both arms by construction
  # (`ancestry_refusals/2`), so restoring from it gives the two arms the same
  # oracle and pins it to the environment's definition rather than to the thing
  # under measurement.
  defp verdict(environment, arm, workspace, files, reverted) do
    verifier = environment["verifier"]

    case Tree.restore(workspace.path, environment["source"]["fix"], files) do
      {:error, reason} ->
        unusable(environment, arm, "the verifier could not be put back: #{reason}")

      :ok ->
        # What the oracle says *now*, so that what it says after the run can be
        # compared with it. See `tampered/4`.
        before = digest(workspace.path, files)

        # The oracle is bound **read-only** for the duration of
        # the run, so a compile-time `File.write!` to it fails with `EROFS`
        # rather than succeeding and being noticed afterwards. `confined?`
        # travels on the verdict because a run without the boundary is a run
        # where only the detection below applies, and §5 is that a check which
        # could not run is `unavailable` rather than `passed`.
        confined = Tree.confined?()

        case Tree.run_tests(verifier["app"], verifier["files"], workspace.path, files) do
          {_output, 0} ->
            tampered(environment, arm, before, workspace, files, reverted) ||
              %{
                environment: environment["id"],
                arm: arm,
                solved: true,
                why: "the verifier passes",
                reverted: reverted,
                confined: confined
              }

          {output, _} ->
            cond do
              # Containment without visibility is a downgrade:
              # before the read-only bind, a solver that rewrote the oracle was
              # caught by the hash check and the run went `partial`. With the
              # bind the write *fails*, the build fails, and the attempt would
              # otherwise be indistinguishable from a solver that simply did
              # not fix the defect. It is not the same fact, so it does not get
              # the same verdict. Found by an earlier change's own test going green
              # for the wrong reason.
              refused_write?(output) ->
                unusable(
                  environment,
                  arm,
                  "the solver tried to write to the oracle while it compiled, and the " <>
                    "sandbox refused it. Prevented rather than detected, and " <>
                    "reported here because an attempt is not the same fact as a defect that " <>
                    "was not fixed."
                )

              Tree.environmental?(output) ->
                unusable(environment, arm, "the build failed before the verifier ran")

              true ->
                %{
                  environment: environment["id"],
                  arm: arm,
                  solved: false,
                  why: "the verifier still fails",
                  reverted: reverted,
                  confined: confined
                }
            end
        end
    end
  end

  # A write the sandbox refused, as the BEAM reports it. `File.write!` to a
  # read-only bind raises with `:erofs`, and a compile-time raise puts the
  # message in the build output. Matched on both spellings because `File.Error`
  # renders the reason as prose and a raw `:file.write` returns the atom.
  defp refused_write?(output) do
    String.contains?(output, "read-only file system") or String.contains?(output, ":erofs")
  end

  # Did the oracle change while it was being run?
  #
  # It can. `mix test` **compiles the solver's file before ExUnit loads the
  # test**, and a module body is code: a solver that writes
  # `File.write!("../test/x_test.exs", "assert true")` at the top of the file
  # it was asked to fix rewrites the restored verifier and passes. An
  # independent review built exactly that and ran it through this sequence:
  # `solved: true`, on a defect it had not touched, with `confine` reporting
  # nothing reverted because the write was outside the tree.
  #
  # **This was detection and not containment, and an earlier change closed the gap
  # where the machine allows it.** The oracle is now bound read-only with
  # `bwrap` for the duration of the run, so the write fails rather than
  # succeeding and being caught afterwards — which matters because a solver
  # that restored the original bytes at `System.at_exit` defeated the check
  # below. The bead priced three containments (a container, a separate user, a
  # second tree); bubblewrap is a fourth it did not list, costs 7–12 ms, and
  # needs no root, no daemon and no image.
  #
  # This check stays, and it is not redundant. It is what runs where `bwrap`
  # is absent, and `Tree.confined?/0` says which of the two applied — because
  # a run without the boundary is not the same evidence as a run with it, and
  # `Environments.brief/1` still says the prompt is not a security boundary.
  #
  # An attempt whose oracle moved is `unusable` rather than `solved: false`:
  # "the verifier was rewritten" and "the defect is still there" are different
  # facts, and one unusable attempt makes the whole run `partial` (§32).
  defp tampered(environment, arm, before, workspace, files, _reverted) do
    if digest(workspace.path, files) == before do
      nil
    else
      unusable(
        environment,
        arm,
        "the verifier's own files changed while it was being run — a module body in a source " <>
          "path is compiled before ExUnit loads the test, so this measured the solver rather " <>
          "than the defect"
      )
    end
  end

  defp digest(tree, files) do
    Map.new(files, fn file ->
      path = Path.join(tree, file)
      {file, if(File.regular?(path), do: :crypto.hash(:sha256, File.read!(path)))}
    end)
  end

  defp unusable(environment, arm, why) do
    %{environment: environment["id"], arm: arm, solved: nil, why: why, reverted: []}
  end

  # ---- the number ------------------------------------------------------------

  defp settle(plan, candidate, attempts, run, opts) do
    expected = 2 * length(plan.environments)
    unusable = Enum.filter(attempts, &is_nil(&1.solved))

    if length(attempts) != expected or unusable != [] do
      {:ok,
       %{
         outcome: "partial",
         candidate: plan.candidate,
         set: plan.set,
         attempts: attempts,
         why:
           "#{length(unusable)} of #{expected} attempts produced no usable observation, so " <>
             "there is no rate over this suite and no number is written. " <>
             Enum.map_join(unusable, "; ", &"#{&1.environment}/#{&1.arm}: #{&1.why}")
       }}
    else
      write(plan, candidate, attempts, run, opts)
    end
  end

  defp write(plan, candidate, attempts, run, opts) do
    rates = Map.new([:candidate, :baseline], &{&1, rate(attempts, &1)})
    delta = Float.round(rates.candidate - rates.baseline, 4)

    result = %{
      outcome: "scored",
      candidate: plan.candidate,
      set: plan.set,
      attempts: attempts,
      rates: rates,
      delta: delta,
      provenance: %{
        "run" => run,
        "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "environments" => Enum.sort(plan.environments),
        "scored_by" => %{
          "adapter" => to_string(plan.adapter),
          "arms" => Map.new(plan.arms, fn {arm, ref} -> {to_string(arm), ref} end)
        }
      }
    }

    if Keyword.get(opts, :record, true) do
      record(result, plan, candidate, rates, run)
    else
      {:ok, result}
    end
  end

  # `by` is the **scoring run**, not the candidate's author. That is not
  # bookkeeping: `Evolution.record_stage/3` refuses a `holdout` or
  # `anti_goodhart` recorded by the author, so passing the author through would
  # have meant a scoring run could never write a held-out number — and passing
  # a different *name* while the same run did the work is the laundering
  # An earlier change exists to stop. What is recorded is the run, and independence is
  # whether that run is the candidate's own or was dispatched by it.
  #
  # A refused recording is not a failed measurement, and the two are kept
  # apart: the numbers are returned with `outcome: "measured"` and a reason
  # saying why the ledger would not take them. §32 — a measurement nobody may
  # write down is not a measurement that did not happen.
  defp record(result, plan, candidate, rates, run) do
    independent = not Run.ancestor?(to_string(candidate["run"]), run)

    attrs = %{
      by: "scoring:#{run}",
      outcome: "passed",
      independent: independent,
      evidence: ["scored #{plan.set}: #{rates.candidate} against #{rates.baseline}"],
      fitness: %{plan.set => result.delta},
      fitness_provenance: %{plan.set => result.provenance}
    }

    case Evolution.record_stage(plan.candidate, plan.set, attrs) do
      {:ok, _path} ->
        {:ok, result}

      {:error, reason} ->
        {:ok,
         Map.merge(result, %{
           outcome: "measured",
           why:
             "the numbers are real and the ledger would not take them: #{reason}. " <>
               "This run is #{if independent, do: "independent of", else: "the candidate's own"} " <>
               "#{candidate["run"] || "(no run recorded at proposal)"}"
         })}
    end
  end

  defp rate(attempts, arm) do
    of_arm = Enum.filter(attempts, &(&1.arm == arm))
    solved = Enum.count(of_arm, & &1.solved)
    if of_arm == [], do: 0.0, else: solved / length(of_arm)
  end

  # ---- the task a solver is handed -------------------------------------------

  defp prompt(environment, path) do
    brief = Environments.brief(environment)

    """
    You are working in a git repository at #{path}. Everything you do stays there.

    #{brief["statement"]}

    The application is `#{brief["app"]}`. These are the files you may change:

    #{Enum.map_join(brief["source_paths"], "\n", &"  - #{&1}")}

    There is no test for this in the tree. Something else will check your work,
    and you cannot see it — so make the behaviour right rather than making a
    particular assertion pass. Do not add dependencies. Do not change anything
    outside the paths above.
    """
  end

  defp arms(candidate) do
    case candidate["application"] do
      %{"ref" => ref, "baseline" => baseline} -> %{candidate: ref, baseline: baseline}
      _ -> %{}
    end
  end

  defp fetch(candidate_id) do
    case Evolution.fetch(candidate_id) do
      {:ok, candidate} -> {:ok, candidate}
      :error -> {:error, "no candidate #{candidate_id}"}
    end
  end

  defp per_dispatch_usd do
    Application.get_env(:noetic_harness, :scoring_dispatch_usd, @observed_usd)
  end

  defp explain(refusals), do: Enum.map_join(refusals, "; ", & &1.why)

  defp verb([_]), do: "is"
  defp verb(_), do: "are"
end
