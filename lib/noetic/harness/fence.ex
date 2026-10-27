defmodule Noetic.Harness.Fence do
  @moduledoc """
  What a dispatched run may not change.

  Constitution §4 and §23 say an agent may *propose* a change to an evaluator,
  benchmark, holdout or gate, and may not author and land that change in the
  same run as the work the evaluator judges. Until a design decision that held for a
  reason nobody built: the harness planned and never acted, so nothing it did
  could reach anything. Dispatch removes that, and this module is what replaces
  it.

  The list lives in `.agents/policies/evaluators.json` as data, because a rule
  compiled into a module is a rule an agent can change in the same commit as
  the work — and `dispatcher.ex` and this file are themselves on the list for
  exactly that reason.

  ## The shape of the rule, and why it is blunt

  `refuse/1` takes the paths a run changed and answers with the fenced ones. A
  dispatched run with a non-empty answer does not land; the refusal names the
  path and the reason recorded beside it. There is no severity, no override
  flag and no per-run exemption, because a rule with exceptions is a rule an
  agent will argue itself into an exception for. The way to change an evaluator
  is a run a human started, which is what "separate provenance" means.

  ## What this does not do

  It does not know whether the change was *good*. A dispatched agent fixing a
  genuinely broken gate is refused exactly like one hiding a failure behind an
  edited threshold, and that is the intended behaviour: telling them apart is a
  judgement, judgement is what the human-started run is for, and a fence that
  tried would be a fence with an argument in it.

  It also does not run. Nothing here executes a diff, a git command or an
  agent. `Dispatcher` calls it; `Conductor` may cite it; neither is this.
  """

  alias Noetic.Harness.Loader

  @doc """
  The fence policy as loaded.
  """
  @spec policy() :: {:ok, map()} | {:error, String.t()}
  def policy do
    Loader.cached_load(Path.join(Noetic.Harness.agents_path("policies"), "evaluators.json"))
  end

  @doc """
  Every fenced glob, with the reason it is fenced.
  """
  @spec entries() :: {:ok, [map()]} | {:error, String.t()}
  def entries do
    with {:ok, doc} <- policy() do
      {:ok, List.wrap(doc["paths"])}
    end
  end

  @doc """
  Whether one repository-relative path is fenced.

  Leading `./` is stripped, because a path that arrives from `git diff
  --name-only` and one typed by hand should not disagree.
  """
  @spec fenced?(String.t()) :: boolean()
  def fenced?(path) do
    case entries() do
      {:ok, rules} -> Enum.any?(rules, &matches?(normalise(path), &1["glob"]))
      {:error, _} -> true
    end
  end

  @doc """
  The fenced paths among those given, each with the reason.

  An empty list means the change is clear of the fence. It does **not** mean
  the change is safe; it means this particular rule has nothing to say.

  A policy that cannot be read refuses everything rather than nothing. A fence
  that fails open is not a fence, and §33 forbids silently weakening behaviour
  when a dependency is unavailable.
  """
  @spec refuse([String.t()]) :: {:ok, []} | {:refused, [%{path: String.t(), why: String.t()}]}
  def refuse(paths) do
    case entries() do
      {:error, message} ->
        {:refused,
         Enum.map(paths, fn path ->
           %{path: path, why: "the evaluator fence could not be read (#{message}), so it refuses"}
         end)}

      {:ok, rules} ->
        paths
        |> Enum.flat_map(fn path ->
          case Enum.find(rules, &matches?(normalise(path), &1["glob"])) do
            nil -> []
            rule -> [%{path: path, why: rule["why"]}]
          end
        end)
        |> case do
          [] -> {:ok, []}
          found -> {:refused, found}
        end
    end
  end

  @doc """
  Fenced paths among those given that a scoring exemption may **not** cover.

  `Dispatcher.attempt/3` narrows the fence by the files an environment's task
  named, so that an environment about the harness's own modules can be scored
  at all. This is the list of fenced paths that narrowing is not
  allowed to reach: `exemptible: true` in the policy says which entries it may.

  The distinction is between a file the harness *is* and a file that says what
  passing **means** outside the worktree the solver was given. The ten
  exemptible modules under `apps/noetic_harness/lib/` are the first (the two
  identity modules are fenced and never exemptible); `.agents/policies/**`,
  `.agents/roles/**`, `.agents/constitution.md`, `.agents/evolution/environments/**`,
  `.github/workflows/**` and `scripts/ci-local.sh` are the second.

  An independent review established that the distinction is load-bearing
  rather than tidy. `Environments.derive/2` takes **everything a commit
  changed** except prose, `.beads/` and `.agents/` — not the
  `apps/*/lib/**.ex` subset an earlier version took — so a real commit of
  the repository it was developed in derives an environment whose source paths include
  `.github/workflows/ci.yml` and `release.yml`. Without this the exemption
  covered both, silently.

  Unreadable policy refuses everything, like `refuse/1`.
  """
  @spec unexemptible([String.t()]) :: [%{path: String.t(), why: String.t()}]
  def unexemptible(paths) do
    case entries() do
      {:error, message} ->
        Enum.map(paths, fn path ->
          %{path: path, why: "the evaluator fence could not be read (#{message}), so it refuses"}
        end)

      {:ok, rules} ->
        Enum.flat_map(paths, fn path ->
          case Enum.find(rules, &matches?(normalise(path), &1["glob"])) do
            nil -> []
            %{"exemptible" => true} -> []
            rule -> [%{path: path, why: rule["why"]}]
          end
        end)
    end
  end

  @doc """
  The sentence a refusal is reported with.

  Every conductor refusal in this repository names the rule and the file the
  rule lives in, so that it can be argued with rather than worked around. This
  one does the same.
  """
  @spec explain([%{path: String.t(), why: String.t()}]) :: String.t()
  def explain(refusals) do
    subject =
      Enum.map_join(refusals, "\n", fn %{path: path, why: why} -> "  #{path} — #{why}" end)

    """
    This run changes #{length(refusals)} file(s) the evaluator fence protects:

    #{subject}

    A dispatched run may propose a change to an evaluator, a benchmark, a
    holdout or a gate, and may not land one — constitution §4 and §23, a design decision
    §4. The list is `.agents/policies/evaluators.json`. Land this from a run a
    human started; that is what separate provenance means.
    """
  end

  # `**` crosses directory separators, `*` does not, and everything else is
  # literal. Path.wildcard is not usable here: it answers what exists on disk,
  # and the question is about a path in a diff, which may have been deleted.
  defp matches?(path, glob) do
    Regex.match?(compile(glob), path)
  end

  defp compile(glob) do
    pattern =
      glob
      |> String.split("**")
      |> Enum.map_join(".*", fn segment ->
        segment
        |> String.split("*")
        |> Enum.map_join("[^/]*", &Regex.escape/1)
      end)

    Regex.compile!("^" <> pattern <> "$")
  end

  defp normalise("./" <> rest), do: normalise(rest)
  defp normalise(path), do: path
end
