defmodule Noetic.Harness.Environments do
  @moduledoc """
  Executable environments: the tasks the evolution gates are actually scored on.

  `Noetic.Harness.Evolution` enforces two acceptance gates over a candidate's
  fitness map — every capability metric within its declared tolerance, at least
  one efficiency metric improved — and nothing produced those numbers. This
  module is the other half: a set of tasks with executable verifiers, drawn from
  this repository's own history, that a candidate harness can be run against.

  ## An environment is a commit read backwards

  SoL-Pi (arXiv:2609.20519 §2.3) built 535 environments, 495 of them from
  issue/PR pairs, keeping one **only when its test fails before the patch and
  passes after**. That criterion is the whole value of the construction, and it
  is not a formality: the first environment derived here, a fix for
  a failed unblock being counted as a quest that moved — was *rejected* by it.
  The test that commit added exercises the success path of `unblock_quest/1`
  only, so it passes against the pre-fix source. It is a good test of the
  feature and no test at all of the defect, and nothing but running it both ways
  would have said so.

  So: an environment that has not been shown to fail before and pass after is in
  **no set** and contributes to **no gate**. `suite/1` returns only verified
  environments. There is no flag to relax this.

  ## How a verification runs

  `kind: "reverse_patch"`, **in a git worktree of its own, at HEAD, which is
  then thrown away**. The verifier runs first at HEAD and must pass; the fix
  commit's diff, restricted to its *source* paths, is reverse-applied there;
  the verifier runs again and must fail. Nothing is restored, because the tree
  that was patched is deleted.

  This used to happen in whatever working tree the caller was standing in, and
  An earlier change is the three things that followed. More than one agent session
  shares this directory, so a verification rewrote shared source under another
  session and that session's next compile failed for a reason neither could
  explain. `git apply` put the files back and could not put back what
  `mix test` had done to `_build`, which was left compiled from reversed
  source. And a verification could not run at the same time as anything,
  including a second verification.

  The worktree isolates the filesystem and **not Postgres**: the verifier's
  `mix test` uses the same `my_app_test` database every other run uses, and two
  verifications of database-touching environments rely on the Ecto sandbox the
  way the ordinary suite does. `MIX_TEST_PARTITION` is the lever if that is
  ever not enough, and it is not pulled here because nothing has yet needed it.

  A fix whose source no longer reverse-applies is `unavailable`, never
  `rejected`. The distinction matters: `rejected` is a statement about the test,
  `unavailable` is a statement about our ability to ask. Verifying those would
  need the worktree checked out at the fix's *parent* rather than at HEAD,
  which is an earlier change and a second verifier kind.

  ## Two ways the criterion is weaker than it looks

  Both were found by an independent review of the first version, and both are
  recorded rather than papered over.

  **A patch that does not cover the whole commit proves nothing.** `derive/2`
  takes `apps/*/lib/**.ex` as the source paths, and a commit that also changed
  `mix.exs`, a config file, a `.heex` template or an asset has a load-bearing
  half outside the patch. Reverse-applying it leaves the fix half in place, the
  test passes, and the environment looks like a test that does not discriminate
  when it is really a patch that does not revert. `uncovered_paths/1` refuses
  those: `unavailable`, naming the paths. `env-smg-components-render` was
  rejected by the first version for exactly this reason — the commit's real
  content was an `elixirc_paths` line in `mix.exs`.

  **A tree that does not compile fails every test in it.** For a commit that
  *created* a module, reverse-applying deletes it, and the verifier fails with
  a `CompileError` rather than an assertion. That satisfies "fails before"
  without saying anything about whether the test can detect the defect, so the
  criterion has no teeth on commits that add code. It is recorded as
  `discrimination: "compile"` against `"assertion"`, and `validate/0` warns:
  those environments are real tasks, but they are not evidence that their test
  discriminates anything.

  ## Set assignment is one-way

  `assign/2` refuses to move an environment that already has a set. A holdout
  that can be moved out of the holdout after a candidate fails on it is not a
  holdout, and the move would not look like cheating at the time — it would look
  like curation. This is the same rule as the one-way rejection in
  `.agents/policies/evolution.md`, applied to the tasks instead of the stages.

  The three sets are not a random split:

  | Set | What it is for | Rule |
  |---|---|---|
  | `benchmark` | the suite a candidate was allowed to see | may motivate a change |
  | `holdout` | tasks that did not select the candidate | never shown during generation |
  | `transfer` | a different app, a different task family | tests that the gain was not a trick |

  `transfer` in particular cannot be assigned by shuffling: an environment in
  the transfer set must come from a different app than the benchmark ones, or it
  is measuring the same thing twice.
  """

  alias Noetic.Harness.{Identity, Loader, Project, Tree, Workspace}
  alias Noetic.Harness.Environments.Decision

  @sets ~w(benchmark holdout transfer)

  # An id becomes a filename and, through it, a shell-free but still
  # path-forming argument. Constraining it here rather than only in the schema
  # is the difference between a check that runs on `derive` and one that runs
  # if somebody remembers to run `noetic-harness validate`.
  @id_pattern ~r/^env-[a-z0-9-]+$/
  @sha_pattern ~r/^[0-9a-f]{40}$/

  # Paths a commit may change without the reverse patch being incomplete:
  # nothing here can alter what a test observes. Prose is inert whatever it
  # says; `.agents/` and `.beads/` are the development system's own bookkeeping
  # and the product's tests cannot read them.
  @inert_paths [~r{\.md$}, ~r{^\.beads/}, ~r{^\.agents/}]

  @states ~w(unverified verified rejected unavailable)
  @verifier_kinds ~w(reverse_patch decision)

  @type environment :: map()

  @doc "The three set names, in pipeline order."
  @spec sets() :: [String.t()]
  def sets, do: @sets

  @doc """
  The set a candidate was allowed to see, and so may have been fitted to.

  Named here rather than spelled `"benchmark"` at each use. An independent
  review pointed out that `Evolution` still carried the literal in the one
  function whose documentation claimed the coincidence had been removed —
  rename this set and `goodhart_signature?/1` would have gone on running,
  subtracting nothing and finding nothing, returning `false` for every
  candidate.
  """
  @spec motivating_set() :: String.t()
  def motivating_set, do: "benchmark"

  @doc """
  The sets a candidate was not allowed to see. A flat one of these beside a
  benchmark gain is the Goodhart signature.
  """
  @spec held_out_sets() :: [String.t()]
  def held_out_sets, do: @sets -- [motivating_set()]

  @doc "The verification states an environment can be in."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc """
  Environments, by id.

  `:set` filters to one set (`nil` for the unassigned), `:state` to one
  verification state, `:kind` to one verifier kind.
  """
  @spec list(keyword()) :: [environment()]
  def list(opts \\ []) do
    dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Loader.load(path) do
        {:ok, environment} -> [environment]
        {:error, _} -> []
      end
    end)
    |> filter(opts)
    |> Enum.sort_by(& &1["id"])
  end

  defp filter(environments, opts) do
    environments
    |> then(fn list ->
      # Retired is not deleted — the ordinary reads show what is
      # current, and `--retired` shows the rest with their reasons. The same
      # shape a knowledge store's facts use, for the same reason: a suite's value is its
      # provenance, and a member that quietly vanished is a member nobody can
      # ask about.
      if Keyword.get(opts, :retired, false),
        do: Enum.filter(list, &retired?/1),
        else: Enum.reject(list, &retired?/1)
    end)
    |> then(fn list ->
      if Keyword.has_key?(opts, :set),
        do: Enum.filter(list, &(&1["set"] == Keyword.get(opts, :set))),
        else: list
    end)
    |> then(fn list ->
      case Keyword.get(opts, :state) do
        nil -> list
        state -> Enum.filter(list, &(state(&1) == state))
      end
    end)
    |> then(fn list ->
      case Keyword.get(opts, :kind) do
        nil -> list
        kind -> Enum.filter(list, &(kind(&1) == kind))
      end
    end)
  end

  @doc "An environment's verifier kind."
  @spec kind(environment()) :: String.t() | nil
  def kind(environment), do: get_in(environment, ["verifier", "kind"])

  @doc """
  One environment by id, retired or not.

  A listing shows what is current; a fetch by id is a direct question about a
  named thing, and it must answer. An earlier change found this the hard way: with
  `fetch/1` reading the filtered listing, `retire/2` could not tell a second
  retirement from a missing environment ("no environment env-a"), and
  `restore/2` — whose whole subject is a retired environment — could never find
  one. Retirement made a file un-addressable, which is deletion with the bytes
  left on disk.
  """
  @spec fetch(String.t()) :: {:ok, environment()} | :error
  def fetch(id) do
    case Enum.find(list() ++ list(retired: true), &(&1["id"] == id)) do
      nil -> :error
      environment -> {:ok, environment}
    end
  end

  @doc """
  The verified environments in a set, of one verifier kind.

  Unverified, rejected and unavailable environments are excluded whatever their
  `set` says. An environment that stopped discriminating its defect stops
  scoring candidates on the run that discovers it, not on the run after.

  The kind defaults to `reverse_patch`, the suite a *harness candidate* is
  scored on: `Scoring` poses each member by reverse-applying a fix, and the
  evolution gates' floor is a count of those. A decision environment
  (`Environments.Decision`) is scored from a file of answers instead, and
  counting one toward a floor it cannot be posed against would satisfy the
  gate without measuring anything.
  """
  @spec suite(String.t(), String.t()) :: [environment()]
  def suite(set, kind \\ "reverse_patch"), do: list(set: set, state: "verified", kind: kind)

  @doc """
  Whether this environment has been retired.

  A suite derived from history decays: the repository moves, a fix
  stops reverse-applying, and a set that quietly stops discriminating scores
  everything the same while looking like it is working. An environment that
  has stopped discriminating is **retired** in this repository's sense —
  dated, with a reason, pointing at what replaced it — and is not deleted.
  """
  @spec retired?(environment()) :: boolean()
  def retired?(environment), do: is_map(environment["retired"])

  @doc """
  Retire an environment: dated, with a reason, naming what replaced it.

  One-way in the same sense `assign/2` is. An environment retired because a
  candidate failed on it and then un-retired is curation, and a suite somebody
  curates is not a measurement. `restore/1` exists for the case that it was
  retired **in error** — which is a different claim, and it says so on the
  file.
  """
  @spec retire(String.t(), keyword()) :: :ok | {:error, String.t()}
  def retire(id, opts) do
    reason = Keyword.get(opts, :reason)

    with {:ok, environment} <- fetch_or_error(id),
         :ok <- check_reason(reason) do
      if retired?(environment) do
        {:error, "#{id} was already retired on #{environment["retired"]["at"]}"}
      else
        claim = Keyword.merge(attribution(), Keyword.take(opts, [:by, :by_from]))

        environment
        |> Map.put("retired", %{
          "at" => DateTime.to_iso8601(DateTime.utc_now()),
          "by" => claim[:by],
          "by_from" => claim[:by_from],
          "reason" => reason,
          "replaced_by" => Keyword.get(opts, :replaced_by)
        })
        |> write()

        :ok
      end
    end
  end

  @doc """
  Un-retire an environment that was retired in error.

  The retirement stays on the file, in `retired_history`, because "this was
  retired and then brought back" is exactly the kind of fact a later reader
  needs in order to trust a number taken over the set.
  """
  @spec restore(String.t(), keyword()) :: :ok | {:error, String.t()}
  def restore(id, opts \\ []) do
    reason = Keyword.get(opts, :reason)

    with {:ok, environment} <- fetch_or_error(id),
         :ok <- check_reason(reason) do
      if retired?(environment) do
        history = environment["retired_history"] || []

        claim = Keyword.merge(attribution(), Keyword.take(opts, [:by, :by_from]))

        entry =
          Map.merge(environment["retired"], %{
            "restored_at" => DateTime.to_iso8601(DateTime.utc_now()),
            "restored_by" => claim[:by],
            "restored_by_from" => claim[:by_from],
            "restored_because" => reason
          })

        environment
        |> Map.delete("retired")
        |> Map.put("retired_history", history ++ [entry])
        |> write()

        :ok
      else
        {:error, "#{id} is not retired"}
      end
    end
  end

  defp check_reason(reason) when is_binary(reason) and byte_size(reason) > 20, do: :ok

  defp check_reason(_reason),
    do:
      {:error,
       "a reason of at least twenty characters is required. \"stale\" is not a reason; " <>
         "what stopped discriminating, and how you know, is."}

  @doc """
  Environments whose verdict was taken at a commit that is no longer HEAD.

  `stamp/1` records the sha a verdict was taken at, so staleness is a fact on
  the file rather than a guess. This is the list `--refresh` re-runs.
  """
  @spec stale(String.t() | nil) :: [environment()]
  def stale(head \\ nil) do
    head = head || current_head()

    case head do
      nil -> []
      head -> Enum.reject(list(), &(get_in(&1, ["verification", "head"]) == head))
    end
  end

  @doc "This repository's HEAD, or `nil` when git cannot say."
  @spec current_head() :: String.t() | nil
  def current_head do
    case System.cmd("git", ["rev-parse", "HEAD"],
           cd: Noetic.Harness.root(),
           stderr_to_stdout: true
         ) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @floor 3

  @doc "How many verified members a set needs before a number taken over it means anything."
  @spec floor() :: pos_integer()
  def floor, do: @floor

  # An **error**, not a note, and the bead is explicit about why:
  # a scoring run over two environments is not a measurement, and an earlier change's
  # refusal to score a partially verified suite is the same rule from the
  # other end.
  #
  # Distinct from the `unavailable` warning above on purpose. That one is
  # about *one* member and about our ability to ask, so making it an error
  # would punish the honest act of re-verifying. This one is about the set
  # having too few members to mean anything, which no amount of honesty fixes
  # — it is fixed by replenishing, which is the other half of this bead.
  defp floor_errors do
    for {set, stats} <- coverage(), list() != [], stats["verified"] < @floor do
      "the #{set} set has #{stats["verified"]} verified member(s) and needs #{@floor}. " <>
        "A number taken over #{stats["verified"]} environment(s) is not a measurement. " <>
        "`noetic-harness environments --derivable` lists commits that would yield new ones; " <>
        "`--derive <sha>` then `--verify <id>` adds one."
    end
  end

  @doc """
  Commits since the newest environment that would yield a new one.

  An earlier change's first verb. `derive/2` already turns *one* commit into an
  environment; this is the loop, plus the bookkeeping that stops it
  re-deriving what it already has.

  The shape it looks for is the same one the suite is made of: a commit that
  touches `apps/*/lib/**` **and** adds or changes an ExUnit file — a fix with
  a test. A commit with neither is not an environment, and a commit with only
  a test is a test, not a defect that was fixed.

  Returns shas, newest last, excluding any commit an existing environment
  already names as its `source.fix`. It does **not** derive them: deriving
  writes files, and a function that lists and a function that writes should
  not be the same function when the list is what a person reads first.
  """
  @spec derivable(keyword()) :: [String.t()]
  def derivable(opts \\ []) do
    known = MapSet.new(list(), &get_in(&1, ["source", "fix"]))
    limit = Keyword.get(opts, :limit, 50)

    case {since_newest(), Project.layout()} do
      {nil, _} ->
        []

      {_, nil} ->
        []

      {since, layout} ->
        case System.cmd(
               "git",
               ["log", "--format=%H", "--reverse", "#{since}..HEAD", "--", layout.apps],
               cd: Noetic.Harness.root(),
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            output
            |> String.split("\n", trim: true)
            |> Enum.reject(&MapSet.member?(known, &1))
            |> Enum.filter(&fix_with_test?/1)
            |> Enum.take(limit)

          _ ->
            []
        end
    end
  rescue
    _ -> []
  end

  defp since_newest do
    list()
    |> Enum.map(&get_in(&1, ["source", "fix"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.max_by(&commit_time/1, fn -> nil end)
  end

  defp commit_time(sha) do
    case System.cmd("git", ["show", "-s", "--format=%ct", sha],
           cd: Noetic.Harness.root(),
           stderr_to_stdout: true
         ) do
      {output, 0} -> output |> String.trim() |> String.to_integer()
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp fix_with_test?(sha), do: fix_with_test?(sha, Project.layout())

  defp fix_with_test?(_sha, nil), do: false

  defp fix_with_test?(sha, layout) do
    case System.cmd("git", ["show", "--name-only", "--format=", sha],
           cd: Noetic.Harness.root(),
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        paths = String.split(output, "\n", trim: true)

        Enum.any?(paths, &lib_source?(layout, &1)) and
          Enum.any?(paths, &String.ends_with?(&1, layout.test_suffix))

      _ ->
        false
    end
  rescue
    _ -> false
  end

  @doc """
  What each set actually contains, as a line the gates can read.

  An earlier change, and this is what makes the bead more than hygiene: in an
  autonomous loop nobody re-reads the suite. A set that quietly stops
  discriminating is a fitness function drifting toward measuring nothing, and
  the loop optimising against it looks like it is improving.

  `discriminating` counts members whose verification established that the
  verifier **fails on an assertion** before the fix. A member that failed to
  compile proves the file was broken, not that the test discriminates — the
  validator already warns about that and this counts it.
  """
  @spec coverage() :: %{String.t() => map()}
  def coverage do
    head = current_head()

    Map.new(sets(), fn set ->
      members = list(set: set, kind: "reverse_patch")
      verified = Enum.filter(members, &(state(&1) == "verified"))

      {set,
       %{
         "members" => length(members),
         "verified" => length(verified),
         "fresh" => Enum.count(verified, &(get_in(&1, ["verification", "head"]) == head)),
         "discriminating" =>
           Enum.count(verified, &(get_in(&1, ["verification", "discrimination"]) == "assertion")),
         "rejected" => Enum.count(members, &(state(&1) == "rejected")),
         "unavailable" => Enum.count(members, &(state(&1) == "unavailable")),
         "retired" => length(list(set: set, retired: true, kind: "reverse_patch"))
       }}
    end)
  end

  @doc "An environment's current verification state."
  @spec state(environment()) :: String.t()
  def state(environment), do: get_in(environment, ["verification", "state"]) || "unverified"

  @doc """
  The environment as a **solver** may see it.

  The whole suite rests on the verifier being hidden from the agent solving
  the task — it is why two environments in different sets may not share a test
  file — and until now nothing implemented that. One JSON file carried the
  statement *and* `source.subject` (annotated in the schema as "the answer
  sheet; not shown to a solver"), `source.fix`, `verifier.files` and
  `verifier.source_paths`; `noetic-harness environments` printed the subject in
  its own listing, and any agent could read the file.

  This is the allow-list, and it is an allow-list rather than a deny-list on
  purpose: a field added to the schema tomorrow is hidden by default, and the
  failure mode of forgetting to add it here is that a solver sees too little.

  What a solver gets:

    * `id` — so it can say what it worked on
    * `statement` — the symptom, which is the task
    * `app` — which umbrella app to work in
    * `source_paths` — the files it may edit

  What it never gets: `source.subject` (the commit message, which names the
  fix), `source.fix` and `source.parent` (the shas, from which the diff is one
  command away), `verifier.files` (the oracle), `set`, and the verification
  record.

  **This is not a security boundary.** The file is on disk and an agent with a
  shell can read it. It is the difference between a solver that was *shown*
  the answer and one that had to go looking, which is the difference between a
  measurement and a transcription — and `Noetic.Harness.Dispatcher` is what
  makes it enforceable, because a dispatched solver gets this map as its
  prompt rather than the file.
  """
  @spec brief(environment()) :: map()
  def brief(%{"verifier" => %{"kind" => "decision"}} = environment) do
    # The question and the evidence, never the label: the label is the
    # answer, and the rows are read from the corpus rather than the file so
    # that the brief cannot carry anything the corpus row does not.
    %{
      "id" => environment["id"],
      "statement" => environment["statement"],
      "question" => get_in(environment, ["verifier", "question"]),
      "rows" => Decision.brief_rows(environment)
    }
  end

  def brief(environment) do
    %{
      "id" => environment["id"],
      "statement" => environment["statement"],
      "app" => get_in(environment, ["verifier", "app"]),
      "source_paths" => get_in(environment, ["verifier", "source_paths"]) || []
    }
  end

  @doc "`brief/1` by id."
  @spec brief_by_id(String.t()) :: {:ok, map()} | :error
  def brief_by_id(id) do
    with {:ok, environment} <- fetch(id), do: {:ok, brief(environment)}
  end

  # ---- writing -------------------------------------------------------------

  @doc """
  Write a new environment.

  Refuses a duplicate id: an environment file is provenance, and overwriting one
  loses the verification history that made it worth having.
  """
  @spec put(environment()) :: {:ok, environment()} | {:error, String.t()}
  def put(environment) do
    with :ok <- validate_shape(environment),
         :ok <- refuse_duplicate(environment["id"]) do
      write(environment)
      {:ok, environment}
    end
  end

  defp refuse_duplicate(id) do
    case fetch(id) do
      :error ->
        :ok

      {:ok, _} ->
        {:error, "environment #{id} already exists; verification history is not rewritten"}
    end
  end

  defp validate_shape(environment) do
    cond do
      not is_map(environment) ->
        {:error, "an environment is a map"}

      environment["id"] in [nil, ""] ->
        {:error, "id is required"}

      not Regex.match?(@id_pattern, environment["id"]) ->
        {:error,
         "id must match #{inspect(@id_pattern.source)} — it becomes a filename, and a filename " <>
           "built from free text is a path this module did not choose"}

      not is_map(environment["verifier"]) ->
        {:error, "verifier is required"}

      environment["verifier"]["kind"] not in @verifier_kinds ->
        {:error, "verifier.kind must be one of: #{Enum.join(@verifier_kinds, ", ")}"}

      environment["verifier"]["kind"] == "decision" ->
        Decision.validate_verifier(environment["verifier"])

      environment["verifier"]["files"] in [nil, []] ->
        {:error, "verifier.files is required — an environment with no test verifies nothing"}

      # The schema required these until it had to describe a second kind, and
      # its language has no `oneOf`; the requirement moved here rather than
      # lapsing.
      environment["verifier"]["app"] in [nil, ""] or
          environment["verifier"]["source_paths"] in [nil, []] ->
        {:error, "a reverse_patch verifier needs app and source_paths"}

      not (is_map(environment["source"]) and
             Regex.match?(@sha_pattern, to_string(environment["source"]["fix"])) and
               Regex.match?(@sha_pattern, to_string(environment["source"]["parent"]))) ->
        {:error,
         "a reverse_patch environment needs source.fix and source.parent as 40-character shas"}

      true ->
        :ok
    end
  end

  @doc """
  Record the result of a verification.

  The previous record is kept in `verification_history`, newest last. History is
  append-only here for the same reason it is everywhere else: an environment
  that verified in March and stopped verifying in September is a fact about the
  test suite, and it is only visible if both records survive.
  """
  @spec record_verification(String.t(), map()) :: {:ok, environment()} | {:error, String.t()}
  def record_verification(id, result) do
    with {:ok, environment} <- fetch_or_error(id),
         :ok <- validate_result(result) do
      previous = environment["verification"]

      # The `unverified` stub `derive/2` writes is a *state*, not a
      # verification that happened — it says `"reason": "never run"` and
      # carries none of `at`, `head`, `by_attested`, `by_from`, `evidence` or
      # `discrimination`. Pushing it into `verification_history` produced a
      # record the schema rejects, and the validator caught it on the first
      # environment ever derived and verified through this path.
      #
      # A history of verifications should contain verifications.
      history =
        case previous do
          nil -> List.wrap(environment["verification_history"])
          %{"state" => "unverified"} -> List.wrap(environment["verification_history"])
          record -> List.wrap(environment["verification_history"]) ++ [record]
        end

      updated =
        environment
        |> Map.put("verification", result |> stamp() |> stringify())
        |> Map.put("verification_history", history)

      write(updated)
      {:ok, updated}
    end
  end

  defp validate_result(result) do
    state = result[:state] || result["state"]

    if state in @states,
      do: :ok,
      else: {:error, "verification state must be one of: #{Enum.join(@states, ", ")}"}
  end

  @doc """
  Put an environment into a set. One-way.

  Refuses if the environment is not verified, and refuses if it already has a
  different set. Moving an environment out of the holdout after a candidate
  failed on it is the leak the one-way rule exists to prevent, and it never
  looks like cheating from the inside — it looks like curation.
  """
  @spec assign(String.t(), String.t()) :: {:ok, environment()} | {:error, String.t()}
  def assign(id, set) do
    with {:ok, environment} <- fetch_or_error(id),
         :ok <- validate_set(set),
         :ok <- refuse_unverified(environment),
         :ok <- refuse_reassignment(environment, set) do
      updated = Map.put(environment, "set", set)
      write(updated)
      {:ok, updated}
    end
  end

  defp validate_set(set) do
    if set in @sets, do: :ok, else: {:error, "set must be one of: #{Enum.join(@sets, ", ")}"}
  end

  defp refuse_unverified(environment) do
    case state(environment) do
      "verified" ->
        :ok

      other ->
        {:error,
         "#{environment["id"]} is #{other}, not verified — an environment that has not been " <>
           "shown to fail before the fix and pass after it scores nothing"}
    end
  end

  defp refuse_reassignment(environment, set) do
    case environment["set"] do
      nil ->
        :ok

      ^set ->
        :ok

      existing ->
        {:error, "#{environment["id"]} is already in the #{existing} set; assignment is one-way"}
    end
  end

  defp fetch_or_error(id) do
    case fetch(id) do
      {:ok, environment} -> {:ok, environment}
      :error -> {:error, "no environment #{id}"}
    end
  end

  # ---- derivation ----------------------------------------------------------

  @doc """
  Build an unverified environment from a fix commit.

  The source paths are the commit's `apps/*/lib/**.ex`, the verifier files its
  `apps/*/test/**.exs`. `statement` is left `nil` on purpose: what the agent is
  told cannot be derived from the commit, because the commit message says what
  the fix was. Authoring it is a human step, and `validate/0` says so until it
  has been done.
  """
  @spec derive(String.t(), keyword()) :: {:ok, environment()} | {:error, String.t()}
  def derive(sha, opts \\ []) do
    with {:ok, fix} <- rev_parse(sha),
         {:ok, parent} <- rev_parse(sha <> "^"),
         {:ok, subject} <- subject(fix),
         {:ok, layout} <- layout(),
         {:ok, source_paths, files} <- commit_paths(fix, layout),
         {:ok, app} <- app_of(files, layout) do
      {:ok,
       %{
         "id" => Keyword.get(opts, :id, "env-" <> String.slice(fix, 0, 8)),
         "title" => subject,
         "source" => %{
           "kind" => "fix_commit",
           "repository" => "self",
           "fix" => fix,
           "parent" => parent,
           "subject" => subject,
           "bead" => Keyword.get(opts, :bead)
         },
         "statement" => nil,
         "verifier" => %{
           "kind" => "reverse_patch",
           "app" => app,
           "files" => Enum.map(files, &Path.relative_to(&1, app_dir(layout, app))),
           "source_paths" => source_paths
         },
         "set" => nil,
         # `unverified` is a state, not an absence. A null here would make the
         # schema need `anyOf`, which the subset evaluator cannot check and
         # says so — and an unchecked constraint reads as a checked one.
         "verification" => %{
           "state" => "unverified",
           "failed_before" => nil,
           "passed_after" => nil,
           "by" => "nobody",
           "reason" => "never run"
         },
         "verification_history" => []
       }}
    end
  end

  # The source paths are **everything the commit changed** except its ExUnit
  # files and inert prose — not the `apps/*/lib/**.ex` subset the first version
  # took. A commit's load-bearing half is regularly somewhere else: one
  # `elixirc_paths` line in `mix.exs`, a TypeScript module, a CSS token file, a
  # `test/support` helper that ends in `.ex`. Reverting a subset leaves the fix
  # in place and the verifier passes, which reads as "this test does not
  # discriminate" and is really "this patch does not revert".
  defp commit_paths(sha, layout) do
    with {:ok, names} <- git(["show", "--name-only", "--format=", sha]) do
      paths = names |> String.split("\n", trim: true)
      files = Enum.filter(paths, &test_file?(layout, &1))
      source = paths |> Kernel.--(files) |> Enum.reject(&inert?/1)

      cond do
        source == [] ->
          {:error, "#{sha} changes nothing a test could observe"}

        files == [] ->
          {:error, "#{sha} adds no test under #{Path.join([layout.apps, "*", layout.test])}"}

        true ->
          {:ok, source, files}
      end
    end
  end

  defp app_of(files, layout) do
    files
    |> Enum.map(&app_named(layout, &1))
    |> Enum.uniq()
    |> case do
      [app] -> {:ok, app}
      apps -> {:error, "tests span #{Enum.join(apps, ", ")}; one environment is one app's suite"}
    end
  end

  # ---- verification --------------------------------------------------------

  @doc """
  Run an environment's verifier both ways and record the result.

  Returns the recorded environment. The states are not interchangeable:

  - `verified` — failed before the fix, passed after. It may be assigned a set.
  - `rejected` — passed before the fix. The test does not discriminate the
    defect; this is a finding about the test, not about the environment.
  - `unavailable` — the question could not be asked: the patch no longer
    reverse-applies, it does not cover the whole commit, a worktree could not
    be opened, HEAD itself does not pass, or the pre-fix run failed without
    reaching the tests. Never reported as either of the other two.

  A dirty working tree is **not** in that list any more. It was, while the
  verification rewrote the caller's files; it runs in a worktree of its own
  now, so the verdict is about HEAD by construction and uncommitted work is
  recorded as a `note` rather than refused.
  """
  @spec verify(String.t(), keyword()) :: {:ok, environment()} | {:error, String.t()}
  def verify(id, opts \\ []) do
    with {:ok, environment} <- fetch_or_error(id) do
      environment
      |> run_verification(opts)
      |> attribute(opts)
      |> then(&record_verification(id, &1))
    end
  end

  @doc """
  Run the same two passes in a worktree **at the fix commit** instead of at
  HEAD, and record the verdict as `verification_at_fix`.

  This answers one question: *did this test discriminate this fix when it was
  written?* — the regression-test check `CLAUDE.md` §5b asks for, and the one
  a later edit to the same file makes unaskable at HEAD. At its own commit a
  fix's diff always reverse-applies.

  It deliberately does **not** touch `verification`, `set` or anything a gate
  reads. `Scoring` poses an environment by reverse-applying its fix at the
  *candidate's* commit, so a fix that no longer reverse-applies at HEAD cannot
  be posed to a solver there, however it was verified. Recording this verdict
  as `verified` would refill a set's floor with environments that cannot be
  measured — satisfying the gate without restoring what it guards. A suite
  that decays is replenished by deriving new environments, not by
  relabelling old ones.
  """
  @spec verify_at_fix(String.t(), keyword()) :: {:ok, environment()} | {:error, String.t()}
  def verify_at_fix(id, opts \\ []) do
    with {:ok, environment} <- fetch_or_error(id) do
      result =
        environment
        |> run_verification(Keyword.put(opts, :at, :fix))
        |> attribute(opts)
        |> stringify()
        |> Map.put("at", DateTime.utc_now() |> DateTime.to_iso8601())
        |> Map.put("head", environment["source"]["fix"])

      updated = Map.put(environment, "verification_at_fix", result)
      write(updated)
      {:ok, updated}
    end
  end

  @doc """
  Who this process would claim to be, and where the claim comes from.

  Pass it straight into `verify/2`. It is a **claim**: an environment variable
  the runner sets, about itself, checked against nothing.

  What the records actually show is the point rather than a footnote. Most say
  `claude-opus-5` from `HARNESS_AGENT`; several say a person's login, because
  `HARNESS_AGENT` was unset and this fell through to `USER` — so an agent's
  verification is recorded under a human's login name, and the only reason
  anybody can tell is `by_from`. That is the design working and the field
  being worth having.
  """
  @spec attribution() :: keyword()
  def attribution do
    cond do
      value = System.get_env("HARNESS_AGENT") -> [by: value, by_from: "HARNESS_AGENT"]
      value = System.get_env("USER") -> [by: value, by_from: "USER"]
      true -> [by: "unattributed", by_from: "nothing said"]
    end
  end

  # `by_attested` was a constant, and writing the constant down was the point.
  # The anti-Goodhart policy asks for an evaluator the candidate's author did
  # not write and cannot modify; a check that compared `by` against anything
  # would be comparing two strings the same process set. Recording `false`
  # beside the name means a later gate cannot read the name without reading
  # that nothing stands behind it. The day something does — an attested agent
  # identity, an earlier change — this is the line that stops being a constant.
  #
  # A design decision put the identity behind it in `Noetic.Harness.Identity`: `actor`
  # is recorded beside `by`, and `by_attested` is read from it — still `false`
  # for every record, because nothing here signs yet, but no longer a literal.
  # `by` and `by_from` are taken from the actor, so the three cannot disagree:
  # a direct caller that passed no `:by` used to get `by: "unattributed"`
  # beside an actor named from the environment.
  defp attribute(result, opts) do
    actor =
      Identity.actor(
        by: Keyword.get(opts, :by),
        by_from: Keyword.get(opts, :by_from, "the caller's :by option")
      )

    result
    |> Map.put(:by, actor["name"])
    |> Map.put(:by_from, actor["name_from"])
    |> Map.put(:actor, actor)
    |> Map.put(:by_attested, Identity.attested?(actor))
  end

  defp run_verification(environment, opts) do
    by = Keyword.get(opts, :by, "unattributed")
    verifier = environment["verifier"]
    fix = environment["source"]["fix"]

    cond do
      verifier["kind"] == "decision" and Keyword.get(opts, :at) == :fix ->
        unavailable(by, "a decision environment has no fix commit to check out")

      verifier["kind"] == "decision" ->
        environment |> Decision.verify() |> Map.put(:by, by)

      verifier["kind"] != "reverse_patch" ->
        unavailable(by, "verifier kind #{verifier["kind"]} has no runner here")

      not Regex.match?(@sha_pattern, to_string(fix)) ->
        unavailable(by, "source.fix is not a 40-character sha: #{inspect(fix)}")

      is_nil(Project.layout()) ->
        unavailable(by, Project.no_layout())

      true ->
        layout = Project.layout()

        case uncovered_paths(environment, layout) do
          {:error, reason} ->
            unavailable(by, reason)

          {:ok, []} ->
            environment |> in_workspace(by, Keyword.get(opts, :at, :head)) |> note(environment)

          {:ok, uncovered} ->
            unavailable(
              by,
              "the reverse patch does not cover the whole commit: it also changed " <>
                "#{Enum.join(uncovered, ", ")}. Reverting only the " <>
                "`#{Path.join([layout.apps, "*", layout.lib, "**.ex"])}` half " <>
                "leaves the fix in place, so a passing test here would say nothing."
            )
        end
    end
  end

  # Every path the commit touched that the patch does not revert and that could
  # change what a test observes. `mix.exs` is the case that made this necessary:
  # one `elixirc_paths` line was the whole content of a commit whose environment
  # was rejected for having a test that "did not discriminate".
  defp uncovered_paths(environment, layout) do
    covered = MapSet.new(environment["verifier"]["source_paths"])

    case git(["show", "--name-only", "--format=", environment["source"]["fix"]]) do
      {:error, reason} ->
        {:error, "cannot read the fix commit: #{reason}"}

      {:ok, names} ->
        uncovered =
          names
          |> String.split("\n", trim: true)
          |> Enum.reject(&MapSet.member?(covered, &1))
          |> Enum.reject(&test_file?(layout, &1))
          |> Enum.reject(&inert?/1)

        {:ok, uncovered}
    end
  end

  defp inert?(path), do: Enum.any?(@inert_paths, &Regex.match?(&1, path))

  defp repo_relative(verifier) do
    case Project.layout() do
      nil -> []
      layout -> Enum.map(verifier["files"], &Path.join(app_dir(layout, verifier["app"]), &1))
    end
  end

  # ---- the app layout ------------------------------------------
  #
  # Where an app's source and tests are is the project's to say
  # (`Noetic.Harness.Project.layout/0`): `apps/<app>/lib/**.ex` and
  # `apps/<app>/test/**.exs` here, as these patterns were written before they
  # were read from it.

  defp layout do
    case Project.layout() do
      nil -> {:error, Project.no_layout()}
      layout -> {:ok, layout}
    end
  end

  defp app_dir(layout, app), do: Path.join(layout.apps, app)

  # `<apps>/<app>/<lib>/….ex`: the Elixir source of an app.
  defp lib_source?(layout, path) do
    case app_relative(layout, path) do
      [_app, lib | [_ | _] = rest] ->
        lib == layout.lib and String.ends_with?(List.last(rest), ".ex")

      _ ->
        false
    end
  end

  # `<apps>/<app>/<test>/…<ext>`, the extension the test suffix ends in:
  # every script under an app's tests, `test_helper.exs` and support included.
  defp test_file?(layout, path) do
    case app_relative(layout, path) do
      [_app, test | [_ | _] = rest] ->
        test == layout.test and
          String.ends_with?(List.last(rest), Path.extname(layout.test_suffix))

      _ ->
        false
    end
  end

  defp app_named(layout, path) do
    case app_relative(layout, path) do
      [app | _] -> app
      [] -> nil
    end
  end

  # A path's segments after `<apps>/`, or `[]` when it is not under it.
  defp app_relative(layout, path) do
    prefix = Path.split(layout.apps)
    parts = Path.split(path)

    if Enum.take(parts, length(prefix)) == prefix,
      do: Enum.drop(parts, length(prefix)),
      else: []
  end

  # The verification happens in a worktree of its own, at HEAD, and that
  # worktree is thrown away.
  #
  # It used to happen here, in whatever tree the caller was standing in. Three
  # things followed and none of them were handled. More than one agent session
  # shares this working directory, so a `--verify` reverse-patched shared files
  # under another session's feet and that session's next
  # `mix compile --warnings-as-errors` failed for a reason neither could
  # explain. `git apply` restored the files and could not restore what
  # `mix test` had done to `_build`, which was left compiled from reversed
  # source — the stale-build class that has already cost this repository a
  # session. And verification could not run concurrently with anything,
  # including itself.
  defp in_workspace(environment, by, at) do
    # The OS pid is in the name, not only `unique_integer/1`. That counter is
    # per BEAM node and restarts low — three fresh starts measured 659, 659 and
    # 658 — and `Workspace.open/1` treats an existing directory as *reuse*,
    # while `close(discard: true)` removes it. Two `--verify` runs of the same
    # environment in two processes therefore shared one worktree and the first
    # to finish deleted it under the second. Found by an independent review.
    id = "verify-#{environment["id"]}-#{System.pid()}-#{:erlang.unique_integer([:positive])}"

    base = if at == :fix, do: [base: environment["source"]["fix"]], else: []

    case Workspace.open(id, base) do
      {:error, reason} ->
        unavailable(
          by,
          "could not open an isolated worktree to verify in, and verification does not " <>
            "fall back to rewriting the shared tree: #{reason}"
        )

      {:ok, workspace} ->
        try do
          Tree.prepare(workspace)
          scrub(workspace.path)
          at_head(environment, by, workspace, at)
        after
          Workspace.close(workspace, discard: true)
        end
    end
  end

  # HEAD first, then the reverse patch — the opposite of the order this ran in
  # before, and for two reasons. The expensive pass is the one that compiles a
  # cold `_build`, and doing it on unmodified source is what makes the second
  # pass cheap. And a verifier that does not pass at HEAD establishes nothing
  # about the defect, so finding that out first saves the second run entirely.
  defp at_head(environment, by, workspace, at) do
    case run_tests(environment, workspace.path) do
      {output, code} when code != 0 ->
        unavailable(
          by,
          "the verifier does not pass at #{where(at)}, so nothing could be established " <>
            "about the defect: #{squeeze(output)}"
        )

      {_, 0} ->
        reverse_patch(environment, by, workspace, at)
    end
  end

  defp where(:head), do: "HEAD"
  defp where(:fix), do: "the fix commit"

  defp reverse_patch(environment, by, workspace, at) do
    case Tree.reverse_patch(
           workspace.path,
           environment["source"]["fix"],
           environment["verifier"]["source_paths"]
         ) do
      :ok ->
        classify(environment, by, run_tests(environment, workspace.path), at)

      {:error, reason} ->
        unavailable(by, "the fix no longer reverse-applies to #{where(at)}: #{reason}")
    end
  end

  defp classify(_environment, by, {output, 127}, _at) do
    unavailable(
      by,
      "the verifier could not be run against the pre-fix source at all: #{squeeze(output)}"
    )
  end

  defp classify(_environment, by, {output, _}, at) do
    if environmental?(output) do
      # Found by an independent review of this change, and it is the review's
      # own finding that an earlier change created the opening: the second pass used to
      # run in the caller's already-built tree, where "mix could not get to the
      # tests" was nearly unreachable. A fresh worktree with a seeded `_build`
      # can fail to compile a dependency, and *every* non-zero exit was being
      # read as "the verifier detected the defect". A broken build is not
      # evidence about a test. §32.
      unavailable(
        by,
        "the verifier failed against the pre-fix source for a reason that is not the defect: " <>
          "the build did not get as far as running it. #{squeeze(output)}"
      )
    else
      %{
        state: "verified",
        failed_before: true,
        passed_after: true,
        discrimination: discrimination(output),
        by: by,
        reason: "failed at the parent source, passes at #{where(at)}",
        evidence: squeeze(output)
      }
    end
  end

  defp environmental?(output), do: Tree.environmental?(output)

  # The dirty-tree guard used to be a refusal, because verification rewrote the
  # shared source and read the shared test files: a verdict taken over somebody
  # else's unsaved work was a verdict about a tree nobody could reconstruct.
  # In a worktree at HEAD both of those are true by construction, so the
  # refusal has nothing left to protect and removing it is not a gate being
  # weakened — it is a guard whose job the structure now does.
  #
  # What replaces it is a fact rather than a refusal. A verdict is about HEAD;
  # if the caller has uncommitted changes in the paths this verifier reads,
  # the record says so, so that nobody reads it as a verdict about their work.
  defp note(result, environment) do
    guarded =
      environment["verifier"]["source_paths"] ++ repo_relative(environment["verifier"])

    case dirty_paths(guarded) do
      {:ok, []} ->
        result

      {:ok, dirty} ->
        Map.put(
          result,
          :note,
          "the working tree has uncommitted changes in #{Enum.join(dirty, ", ")}; this " <>
            "verdict was taken at HEAD in a worktree of its own and is not about them"
        )

      {:error, reason} ->
        Map.put(
          result,
          :note,
          "could not tell whether the working tree has uncommitted changes (#{reason}); " <>
            "this verdict was taken at HEAD in a worktree of its own either way"
        )
    end
  end

  defp discrimination(output) do
    cond do
      # What this repository's ExUnit actually prints. The first version looked
      # for "N failures", which this formatter never writes, so every verified
      # environment was classified `compile` — including four whose evidence is
      # a plain failed assertion. A classifier nobody checked against real
      # output is a classifier that returns a constant.
      Regex.match?(~r/^Failed: \d+ test/m, output) -> "assertion"
      Regex.match?(~r/,\s*\d+ failures?/, output) -> "assertion"
      true -> "compile"
    end
  end

  defp run_tests(environment, tree) do
    verifier = environment["verifier"]
    Tree.run_tests(verifier["app"], verifier["files"], tree)
  end

  defp unavailable(by, reason) do
    %{state: "unavailable", failed_before: nil, passed_after: nil, by: by, reason: reason}
  end

  # ---- validation ----------------------------------------------------------

  @doc """
  Invariants, for `noetic-harness validate`.

  Errors are states that make a number wrong; warnings are states that make the
  suite smaller than it looks.
  """
  @spec validate() :: %{errors: [String.t()], warnings: [String.t()]}
  def validate do
    everything = list()
    # The checks below read a reverse-patch verifier's files and source
    # paths; a decision environment has neither and has its own (`Decision`).
    environments = Enum.filter(everything, &(kind(&1) == "reverse_patch"))
    decisions = Enum.filter(everything, &(kind(&1) == "decision"))
    decision_findings = Decision.validate(decisions)

    errors =
      Enum.flat_map(everything, fn environment ->
        cond do
          environment["set"] not in [nil | @sets] ->
            ["#{environment["id"]}: unknown set #{inspect(environment["set"])}"]

          environment["set"] != nil and state(environment) == "rejected" ->
            [
              "#{environment["id"]} is in the #{environment["set"]} set and its verifier no " <>
                "longer discriminates the defect. It scores nothing, and a suite that silently " <>
                "shrinks is how a gate comes to be passed by three tasks."
            ]

          true ->
            []
        end
      end) ++
        shared_verifier_errors(environments) ++
        decision_findings.errors ++
        shape_errors(everything) ++
        unreadable_errors() ++
        filename_errors() ++
        floor_errors()

    warnings =
      Enum.flat_map(everything, fn environment ->
        cond do
          # `unavailable` is not `rejected`, and treating it as an error would
          # make the honest action — re-verifying after HEAD moved past a
          # commit — the one that turns a blocking gate red with no legal way
          # to clear it. The suite still loses the environment: `suite/1`
          # excludes it the same run.
          environment["set"] != nil and state(environment) != "verified" ->
            [
              "#{environment["id"]} is in the #{environment["set"]} set and is " <>
                "#{state(environment)}; it is not scoring anything until it verifies again"
            ]

          state(environment) == "unverified" ->
            [
              "#{environment["id"]}: never verified — run " <>
                "`noetic-harness environments --verify #{environment["id"]}`"
            ]

          state(environment) == "verified" and environment["set"] == nil ->
            ["#{environment["id"]}: verified and in no set, so it is not yet scoring anything"]

          state(environment) == "verified" and environment["statement"] in [nil, ""] ->
            ["#{environment["id"]}: no statement — there is nothing to hand an agent"]

          true ->
            []
        end
      end) ++
        compile_discrimination_warnings(environments) ++
        shared_source_warnings(environments) ++
        answer_sheet_warnings(environments) ++
        suite_warnings(environments) ++
        decision_findings.warnings

    %{errors: errors, warnings: warnings}
  end

  # The schema can only require what every kind has, so the per-kind shape is
  # checked here, with the same function `put/1` refuses a write with.
  defp shape_errors(environments) do
    for environment <- environments,
        {:error, reason} <- [validate_shape(environment)],
        do: "#{environment["id"]}: #{reason}"
  end

  # A statement is what an agent is handed and must carry the **symptom**. The
  # discipline was asserted in four places and checked nowhere, and five of
  # thirteen statements read as work orders — "Make the table a contract",
  # "Move the form to the design system's components". A candidate
  # scored on a suite where half the tasks hand over the solution measures
  # transcription, not capability.
  #
  # This flags a sentence that opens with an instruction verb. It is a
  # heuristic and its numbers are known, because a check whose accuracy nobody
  # measured is a check nobody should trust: against the five statements
  # An earlier change identified it catches **four**, and it misses
  # `env-dsl-evaluator`, whose instruction ("interpret exactly two things and
  # nothing else") is not at the start of a sentence. Against the thirteen it
  # flags two more.
  #
  # Those two are judgement calls rather than false alarms, and the message
  # says so. "Make the crossing happen while it is happening" names an
  # *outcome* and is right; "Compile a parsed canon to a TypeDB schema, a set
  # of deletes and a set of inserts" names a *mechanism* and is the fix. No
  # regular expression separates those, so this asks the question and a person
  # answers it — which is why it is a warning and not an error.
  #
  # An objective version was tried first and measured before being kept: a
  # run of words shared with `source.subject`, the annotated answer sheet. At
  # every run length from four to seven it caught at most two of the five and
  # fired on statements that were fine, because a statement and a commit
  # subject necessarily name the same thing. It is not here, and the
  # measurement is why.
  @instruction_verbs ~w(make move compile close implement add write build create
                        replace introduce extract refactor give)

  defp answer_sheet_warnings(environments) do
    Enum.flat_map(environments, fn environment ->
      case instruction_sentences(environment["statement"]) do
        [] ->
          []

        [sentence | _] ->
          [
            "#{environment["id"]}: the statement tells the solver what to do — " <>
              "#{inspect(String.slice(sentence, 0, 70))}. A statement carries the symptom " <>
              ". If that sentence names an outcome rather than a mechanism it is " <>
              "right and this warning is the wrong one; say so on the bead rather than " <>
              "rewording it to go quiet"
          ]
      end
    end)
  end

  defp instruction_sentences(nil), do: []

  defp instruction_sentences(statement) do
    statement
    |> String.replace("\n", " ")
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.filter(fn sentence ->
      case String.split(String.trim(sentence), ~r/\s+/, parts: 2) do
        [first | _] -> String.downcase(String.trim(first, ",")) in @instruction_verbs
        [] -> false
      end
    end)
  end

  # `list/1` keys on the JSON `id`; `write/1` names the file after it. Nothing
  # made the two agree, so a hand-placed file whose `id` disagrees with its
  # name gives two environments one id and one of them silently wins — and the
  # one that wins is whichever `Path.wildcard/1` returns second. A file that
  # could claim a holdout member's id is a file that could replace it.
  defp filename_errors do
    dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Loader.load(path) do
        {:ok, %{"id" => id}} when is_binary(id) ->
          if Path.basename(path) == "#{id}.json" do
            []
          else
            [
              "#{Path.basename(path)} declares id #{inspect(id)}, so it is read under an id " <>
                "its filename does not carry. Two files can then hold one id and the second " <>
                "one read wins."
            ]
          end

        _ ->
          []
      end
    end)
  end

  # An environment's verifier is hidden from the agent solving it. Two
  # environments sharing a test file therefore share a secret: solving the
  # benchmark one puts the holdout one's verifier on screen, and the holdout
  # stops being held out without anybody deciding that it should.
  defp shared_verifier_errors(environments) do
    environments
    |> assigned_by(& &1["verifier"]["files"])
    |> Enum.flat_map(fn {file, sharing} ->
      case sharing |> Enum.map(& &1["set"]) |> Enum.uniq() do
        [_single] ->
          []

        sets ->
          [
            "#{file} is the verifier for environments in #{Enum.join(Enum.sort(sets), " and ")} " <>
              "(#{Enum.map_join(sharing, ", ", & &1["id"])}). A verifier is hidden from the agent " <>
              "solving its environment, so a shared file shows one set's answers while working on " <>
              "another's."
          ]
      end
    end)
  end

  # The weaker sibling of the rule above, and a warning rather than an error
  # because what leaks is smaller and the remedy is not obvious. An agent
  # solving a benchmark environment edits a source file that also carries a
  # holdout environment's fix — it does not see the holdout's test, but it sees
  # the answer in the file it is editing. Recorded rather than fixed by moving
  # environments between sets: assignment is one-way, and re-cutting the sets
  # to satisfy a rule discovered afterwards is the move the one-way rule exists
  # to make impossible.
  defp shared_source_warnings(environments) do
    environments
    |> assigned_by(& &1["verifier"]["source_paths"])
    |> Enum.flat_map(fn {path, sharing} ->
      case sharing |> Enum.map(& &1["set"]) |> Enum.uniq() do
        [_single] ->
          []

        sets ->
          [
            "#{path} is reverse-patched by environments in #{Enum.join(Enum.sort(sets), " and ")} " <>
              "(#{Enum.map_join(sharing, ", ", & &1["id"])}). The verifiers are separate; the " <>
              "source file an agent edits is not. The holdout property here rests on the one-way " <>
              "assignment, not on source isolation."
          ]
      end
    end)
  end

  defp assigned_by(environments, extract) do
    environments
    |> Enum.filter(&(&1["set"] != nil))
    |> Enum.flat_map(fn environment ->
      Enum.map(extract.(environment), &{&1, environment})
    end)
    |> Enum.group_by(fn {key, _} -> key end, fn {_, environment} -> environment end)
  end

  # "Failed before the fix" is satisfied by a tree that does not compile, which
  # is what reverse-applying a commit that *created* a module produces. The
  # environment is a real task; it is just not evidence that its test can
  # detect anything.
  defp compile_discrimination_warnings(environments) do
    environments
    |> Enum.filter(&(state(&1) == "verified"))
    |> Enum.filter(&(get_in(&1, ["verification", "discrimination"]) == "compile"))
    |> Enum.map(fn environment ->
      "#{environment["id"]}: failed before the fix with a compile error, not a failing " <>
        "assertion — the criterion did not establish that its verifier discriminates anything"
    end)
  end

  # `list/1` drops a file it cannot parse, and a suite that quietly shrinks is
  # the thing this module's own error text warns about. The directory is walked
  # again here so that a broken file is named rather than absent.
  defp unreadable_errors do
    dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Loader.load(path) do
        {:ok, _} ->
          []

        {:error, reason} ->
          ["#{Path.basename(path)} cannot be read, so it is in no suite: #{reason}"]
      end
    end)
  end

  defp suite_warnings(environments) do
    verified = Enum.filter(environments, &(state(&1) == "verified"))

    Enum.flat_map(@sets, fn set ->
      case Enum.filter(verified, &(&1["set"] == set)) do
        [] -> ["the #{set} set is empty; any gate reading it is reading nothing"]
        _ -> []
      end
    end) ++ transfer_warning(verified)
  end

  # The transfer set answers "did the gain survive a different task family".
  # Drawn from the same app as the benchmark, it answers nothing. The app is
  # taken from the *source paths*, not from where the test file lives: an
  # environment whose test is in `my_app_web` and whose fix is in `my_app` is a
  # `my_app` task with a web-shaped verifier.
  defp transfer_warning(verified) do
    apps = fn set ->
      verified
      |> Enum.filter(&(&1["set"] == set))
      |> Enum.flat_map(&source_apps/1)
      |> MapSet.new()
    end

    benchmark = apps.("benchmark")
    transfer = apps.("transfer")

    if MapSet.size(transfer) > 0 and MapSet.subset?(transfer, benchmark) do
      [
        "every transfer environment patches an app the benchmark also patches " <>
          "(#{Enum.join(Enum.sort(MapSet.to_list(transfer)), ", ")}) — the transfer set is " <>
          "measuring the benchmark's task family twice"
      ]
    else
      []
    end
  end

  # Only `apps/<name>/…` names an app. `mix.lock` splits to one element and
  # `config/config.exs` to two, so the naive `Enum.at(1)` put `nil` and
  # `"config.exs"` into a set of app names.
  defp source_apps(environment) do
    case Project.layout() do
      nil ->
        []

      layout ->
        environment["verifier"]["source_paths"]
        |> Enum.flat_map(fn path ->
          case app_relative(layout, path) do
            [app | _] -> [app]
            [] -> []
          end
        end)
        |> Enum.uniq()
    end
  end

  # ---- plumbing ------------------------------------------------------------

  defp dirty_paths([]), do: {:ok, []}

  defp dirty_paths(paths) do
    case git(["status", "--porcelain", "--"] ++ paths) do
      {:ok, ""} ->
        {:ok, []}

      {:ok, output} ->
        {:ok, output |> String.split("\n", trim: true) |> Enum.map(&String.slice(&1, 3..-1//1))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rev_parse(rev) do
    case git(["rev-parse", rev]) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, reason} -> {:error, "cannot resolve #{rev}: #{reason}"}
    end
  end

  defp subject(sha) do
    case git(["log", "-1", "--format=%s", sha]) do
      {:ok, line} -> {:ok, String.trim(line)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git(args) do
    case System.cmd("git", args, cd: Noetic.Harness.root(), stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, String.trim(output)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Captured output is written into a committed artifact, so the absolute paths
  # in a stack trace would put somebody's home directory and username in git.
  # A home directory and a username is exactly what leaked from
  # `env-voice-instrument-composer` before this existed.
  #
  # Paths were the confirmed leak; they are not the whole risk. ExUnit failure
  # output carries whatever the failing code printed or inspected, so a
  # connection string inside a `DBConnection` error or an inspected config map
  # would be committed too. Two answers, in order:
  #
  # **Redact by value.** Every environment variable whose *name* looks like a
  # credential and whose value is long enough to be one is replaced wherever it
  # appears. That covers the population that can actually leak from here — the
  # secrets this process is holding — rather than a guess at what a secret
  # looks like.
  #
  # **Then withhold.** A secret this process never had is not in that
  # population, so a credential-shaped run that survives redaction is not
  # filtered quietly: the evidence is replaced by a sentence saying it was
  # withheld and why. §33 — the weakening is stated, not silent. Evidence is
  # still committed rather than moved out of the tree, because a verdict
  # nobody can check is worth less than a bounded risk.
  # The worktree's own path, which `Noetic.Harness.root()` does not cover: when
  # the caller is itself a linked worktree the verification tree lives under the
  # *common* git directory, which does not start with the caller's root, and
  # only the `HOME` replacement was scrubbing it — by luck, and not at all for a
  # repository outside `$HOME`. Process state rather than a parameter because
  # `squeeze/1` is called from six places and five of them have no workspace.
  defp scrub(path), do: Process.put(:noetic_env_scrub, path)

  defp squeeze(output) do
    output
    # The worktree first: it is longer than the root or `$HOME` it may sit in.
    |> then(fn text ->
      case Process.get(:noetic_env_scrub) do
        nil -> text
        path -> String.replace(text, path, "<the verification worktree>")
      end
    end)
    |> Noetic.Harness.Redact.scrub()
    |> String.trim()
    |> String.slice(-1_200..-1//1)
    |> String.trim()
    |> withhold_credentials()
  end

  defp withhold_credentials(text) do
    if Noetic.Harness.Redact.credential_url?(text) do
      "evidence withheld: after redaction it still contained a `scheme://user:password@host` " <>
        "run, and this file is committed. The verdict stands on the verifier's exit " <>
        "status; re-run the verification to see the output."
    else
      text
    end
  end

  # When, and against which tree. Without the second, a record that says
  # `verified` goes on saying it after HEAD has moved past the commit it
  # reverse-applies, and nothing can ask how stale the suite is.
  defp stamp(result) do
    head =
      case git(["rev-parse", "HEAD"]) do
        {:ok, sha} -> String.trim(sha)
        {:error, _} -> nil
      end

    result
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put_new("at", DateTime.utc_now() |> DateTime.to_iso8601())
    |> Map.put_new("head", head)
  end

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp write(environment) do
    File.mkdir_p!(dir())
    File.write!(Path.join(dir(), "#{environment["id"]}.json"), Loader.pretty!(environment))
  end

  defp dir, do: Path.join(Noetic.Harness.agents_path("evolution"), "environments")
end
