defmodule Noetic.Harness.Artifact do
  @moduledoc """
  The artifact envelope: how one agent hands work to the next.

  Conversation is not state. If a fact or a decision could matter to another
  agent or to a later session, it is written down as an artifact before the run
  ends — the next agent will not have this one's context window.

  ## `unverified` is required

  `provenance.unverified` has no default and cannot be omitted. An empty list is
  a *claim*: everything in this artifact was checked. That is deliberately
  uncomfortable to write, because the alternative — an artifact that is silent
  about what it did not establish — is how an unverified assumption travels
  three steps downstream and becomes a premise.

  ## Evidence is a command and its result

  `evidence` entries carry `what`, optionally `command`, and `result`. "Tests
  pass" is not an entry; `mix test` and its output are.
  """

  alias Noetic.Harness.{Git, Loader}

  @kinds ~w(Requirement RFC ADR ArchitectureMap TaskGraph CodePatch SchemaChange
            Migration AgentSpec SkillSpec WorkflowSpec WorldSpec TrajectorySpec
            SceneRecipe AssetManifest DatasetManifest Experiment EvaluationRun
            RenderEvidence VisualCritique ReleaseCandidate IncidentReport Postmortem
            ResearchNote Hypothesis Benchmark HoldoutResult TransferTest ProvenanceRecord
            CalibrationReport)

  @doc "The artifact kinds this harness knows."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Build an envelope.

  Required: `:kind`, `:created_by`, `:unverified`. `:unverified` must be given
  explicitly, including as `[]`.
  """
  @spec new(map()) :: {:ok, map()} | {:error, String.t()}
  def new(attrs) do
    cond do
      attrs[:kind] not in @kinds ->
        {:error, "kind must be one of: #{Enum.join(@kinds, ", ")}"}

      attrs[:created_by] in [nil, ""] ->
        {:error, "created_by is required — an artifact with no author cannot be evaluated"}

      not is_list(attrs[:unverified]) ->
        {:error,
         "provenance.unverified is required and must be a list. An empty list is a claim that " <>
           "everything here was checked; omitting it is not the same thing."}

      true ->
        now = DateTime.utc_now()

        {:ok,
         %{
           "id" => attrs[:id] || build_id(now, attrs[:kind]),
           "kind" => attrs[:kind],
           "version" => attrs[:version] || 1,
           "parent_ids" => attrs[:parent_ids] || [],
           "created_by" => attrs[:created_by],
           "created_at" => DateTime.to_iso8601(now),
           "workflow" => attrs[:workflow],
           "step" => attrs[:step],
           "task" => attrs[:task],
           "inputs" => attrs[:inputs] || [],
           "outputs" => attrs[:outputs] || [],
           "status" => attrs[:status] || "draft",
           "evidence" => Enum.map(attrs[:evidence] || [], &normalise_evidence/1),
           "provenance" => %{
             "source" => attrs[:source] || "run",
             "commit" => attrs[:commit] || current_commit(),
             "tool_versions" => attrs[:tool_versions] || %{},
             "unverified" => attrs[:unverified]
           }
         }
         # A `CalibrationReport` carries its measurement here
         # (`Environments.Decision.score/3`). Absent rather than null for
         # every other kind: the schema says an evaluation is an object.
         |> then(
           &if(attrs[:evaluation], do: Map.put(&1, "evaluation", attrs[:evaluation]), else: &1)
         )
         # Test litter says which VM wrote it, so a broom in another VM leaves
         # it alone until that VM is gone (`Noetic.Harness.Owner`).
         |> then(
           &if(attrs[:created_by] == "test",
             do: Map.put(&1, "owner_vm", Noetic.Harness.Owner.current()),
             else: &1
           )
         )}
    end
  end

  @doc "Write an artifact under `.agents/artifacts/<kind>/`."
  @spec write(map()) :: {:ok, Path.t()} | {:error, String.t()}
  def write(artifact) do
    dir = Path.join([Noetic.Harness.agents_path("artifacts"), artifact["kind"]])
    path = Path.join(dir, artifact["id"] <> ".json")

    if File.exists?(path) do
      {:error, "#{artifact["id"]} already exists — bump the version and give it a new id"}
    else
      File.mkdir_p!(dir)
      File.write!(path, Loader.pretty!(artifact))
      {:ok, path}
    end
  end

  @doc """
  Remove the artifacts a test suite wrote into the committed registry.

  The runs had a broom (`Run.prune_ephemeral/0`) and the artifacts had none,
  which is an earlier change: a suite run leaves `.agents/artifacts/<kind>/*.json`
  with `created_by: "test"` behind, and nothing removed them or complained.

  Keyed on `created_by` rather than on a separate flag because that field is
  already **required** — `new/1` refuses an artifact without one, on the
  grounds that an artifact with no author cannot be evaluated — so there is no
  second thing to keep in sync. The consequence is worth stating: an artifact
  a person deliberately authored as `"test"` would be removed by this. Nothing
  in the registry does that today; the five committed artifacts are
  `created_by: "claude-opus-5"`.

  **A tracked file is never removed, whatever it says about its author.** That
  guard is not belt-and-braces; it was earned. This function is called from
  `ExUnit.after_suite/1`, which runs *after* the callbacks that restore
  `NOETIC_HARNESS_ROOT` — so it always resolves to the **real** repository,
  even for a suite whose every test pointed the harness at a fixture tree. A
  calibration mutation that widened the filter by one clause therefore deleted
  all five committed artifacts in one run, and `git checkout` was the only
  reason that cost nothing. Litter is untracked by definition; anything git
  knows about is somebody's work.

  Only artifacts this VM may sweep go (`Noetic.Harness.Owner.sweepable?/1`):
  its own, and those of a VM that no longer exists. A suite running beside
  this one in the same checkout keeps what it wrote until it finishes.

  Returns the ids it removed.
  """
  @spec prune_test() :: [String.t()]
  def prune_test do
    test_output()
    |> Enum.filter(fn {_path, artifact} ->
      Noetic.Harness.Owner.sweepable?(artifact["owner_vm"])
    end)
    |> Enum.map(fn {path, _artifact} -> path end)
    |> Enum.reject(&tracked?/1)
    |> Enum.filter(&(File.rm(&1) == :ok))
    |> Enum.map(&Path.basename(&1, ".json"))
  end

  @doc """
  Every artifact on disk that says `created_by: "test"`, with its path.

  What `prune_test/0` chooses from, and what `noetic-harness run
  --prune-ephemeral` reports as kept when it chose not to remove one. A file
  that is not readable JSON is not in the list.
  """
  @spec test_output() :: [{Path.t(), map()}]
  def test_output do
    Noetic.Harness.agents_path("artifacts")
    |> Path.join("*/*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Loader.load(path) do
        {:ok, %{"created_by" => "test"} = artifact} -> [{path, artifact}]
        _ -> []
      end
    end)
  end

  @doc """
  Whether git knows about this path.

  A separate function because two brooms need it and because it is the one
  sentence standing between a cleanup and a deletion. It fails **closed**: if
  git cannot be asked — not a repository, not installed, an error — the answer
  is "tracked", so nothing is removed. A broom that deletes when it cannot
  tell is not a broom.
  """
  @spec tracked?(Path.t()) :: boolean()
  def tracked?(path) do
    case System.cmd("git", ["ls-files", "--error-unmatch", "--", path],
           cd: Noetic.Harness.root(),
           stderr_to_stdout: true
         ) do
      # 0 is "git knows this file". 1 is `--error-unmatch` saying it does not,
      # which is the only answer that permits a delete. Everything else — 128
      # for "not a git repository", 127 for no git at all — is an *unanswered*
      # question, and an unanswered question is not a licence.
      {_output, 0} -> true
      {_output, 1} -> false
      {_output, _other} -> true
    end
  rescue
    _ -> true
  end

  @doc "Every artifact on disk, newest first."
  @spec list() :: [map()]
  def list do
    Noetic.Harness.agents_path("artifacts")
    |> Path.join("*/*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Loader.load(path) do
        {:ok, artifact} -> [artifact]
        {:error, _} -> []
      end
    end)
    |> Enum.sort_by(& &1["created_at"], :desc)
  end

  defp normalise_evidence(%{} = entry) do
    Map.new(entry, fn {k, v} -> {to_string(k), redact(v)} end)
  end

  defp normalise_evidence(other) do
    %{"what" => redact(to_string(other)), "result" => "(not recorded)"}
  end

  # An artifact is committed, and evidence is whatever a command printed or an
  # agent pasted. Both have already put an operator's home directory into this
  # repository's history — once through a captured stack trace, once through a
  # `command -v` result copied verbatim into a `result` field. The repository
  # root and `$HOME` are replaced before the envelope is written, because the
  # alternative is remembering every time.
  # Paths and held secrets, through the one redaction all three committed
  # writers share (`Noetic.Harness.Redact`).
  defp redact(value), do: Noetic.Harness.Redact.scrub(value)

  defp build_id(now, kind) do
    stamp = now |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9TZ]/, "")
    "#{String.downcase(kind)}-#{stamp}-#{:erlang.unique_integer([:positive])}"
  end

  defp current_commit do
    case Git.head() do
      {:ok, sha} -> sha
      :error -> nil
    end
  end
end
