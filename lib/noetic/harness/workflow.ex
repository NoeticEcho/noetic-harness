defmodule Noetic.Harness.Workflow do
  @moduledoc """
  Workflow definitions, and the checks that make a workflow graph more than a
  list of intentions.

  A workflow says what has to happen, in what order, with which capabilities,
  under which gates, and when to stop. It does **not** name roles: naming a role
  in a workflow would make routing a lookup table and would break the moment the
  registry gained a better-suited role. Steps declare capabilities; the router
  resolves them (`Noetic.Harness.Router`).

  ## What `validate/1` actually catches

  - a step whose `inputs` name an output no earlier step produces and that the
    workflow does not declare as an input — the most common real defect, and
    invisible to a reader because the prose reads fine;
  - `independent_of` naming a step that does not exist, which silently disables
    the review-fabric rule it was written to enforce;
  - a `parallel_group` whose members depend on each other, which is a sequence
    wearing a group's name;
  - an unknown capability, gate or lane;
  - an empty completion list — a workflow that cannot say when it is done.

  Cycles are handled explicitly rather than by assuming a DAG: the step order in
  the file *is* the execution order, and a step that consumes a later step's
  output is reported as a backward reference rather than silently tolerated.
  """

  alias Noetic.Harness.{Loader, Plane}

  @type t :: map()

  @doc """
  Every workflow of both planes, ordered by id.

  What `validate` reads, because its checks are about both. The development
  engine reads `list/1` with `"development"`, or `fetch/1`.
  """
  @spec list() :: {:ok, [t()]} | {:error, String.t()}
  def list do
    with {:ok, entries} <- Loader.load_dir(Noetic.Harness.agents_path("workflows")) do
      {:ok, entries |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1["id"])}
    end
  end

  @doc "The workflows of one plane (`Noetic.Harness.Plane`), ordered by id."
  @spec list(Plane.t() | :any) :: {:ok, [t()]} | {:error, String.t()}
  def list(plane) do
    with {:ok, workflows} <- list() do
      {:ok, Enum.filter(workflows, &Plane.in?(&1, plane))}
    end
  end

  @doc "Load or raise."
  @spec list!() :: [t()]
  def list! do
    case list() do
      {:ok, workflows} -> workflows
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  One development workflow by id (`WF-002`).

  **The development engine's door, so a runtime workflow answers `:error`.**
  `Run.start/1`, the conductor and the dispatcher reach a workflow through
  here and nowhere else, and none of them may start, conduct or dispatch a
  runtime one. Their own message for `:error` is "no workflow", which
  does not name that rule; `noetic-harness run --start` and `Router.route/2` check
  first and do. `fetch/2` takes the plane explicitly.
  """
  @spec fetch(String.t()) :: {:ok, t()} | :error
  def fetch(id), do: fetch(id, "development")

  @doc "One workflow by id, of `plane` (`:any` for either)."
  @spec fetch(String.t(), Plane.t() | :any) :: {:ok, t()} | :error
  def fetch(id, plane) do
    case list() do
      {:ok, workflows} ->
        case Enum.find(workflows, &(&1["id"] == id)) do
          nil -> :error
          workflow -> if Plane.in?(workflow, plane), do: {:ok, workflow}, else: :error
        end

      {:error, _} ->
        :error
    end
  end

  @doc """
  Why the development engine refuses workflow `id`, or `:ok`.

  The message names the rule, which `fetch/1`'s `:error` cannot. An unknown id
  is `:ok` here: saying it does not exist is the caller's.
  """
  @spec development_refusal(String.t() | nil, String.t()) :: :ok | {:error, String.t()}
  def development_refusal(nil, _doing), do: :ok

  def development_refusal(id, doing) do
    case fetch(id, :any) do
      {:ok, workflow} ->
        if Plane.runtime?(workflow) do
          {:error,
           "#{id} is a runtime workflow, and the development engine never #{doing} one: " <>
             "a product runs it from `harness export`"}
        else
          :ok
        end

      :error ->
        :ok
    end
  end

  @doc "The pipeline catalogue."
  @spec pipelines() :: {:ok, [map()]} | {:error, String.t()}
  def pipelines do
    with {:ok, doc} <-
           Loader.load(Path.join(Noetic.Harness.agents_path("pipelines"), "pipelines.json")) do
      {:ok, doc["pipelines"]}
    end
  end

  @doc """
  Every capability any step of this workflow requires.
  """
  @spec capabilities(t()) :: [String.t()]
  def capabilities(workflow) do
    workflow["steps"] |> Enum.flat_map(& &1["capabilities"]) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  The steps, grouped into execution waves.

  Consecutive steps sharing a `parallel_group` form one wave; everything else is
  its own wave.

  **A wave says these steps do not depend on each other. It does not say
  anything runs them together, and nothing does.** `Noetic.Harness.Dispatcher`
  advises and dispatches exactly one step at a time, and always has; `waves/1`
  is a statement about the *workflow's* shape, not about execution. That
  distinction was not written down anywhere and the CLI printed "(in
  parallel)", which is how a description becomes a claim.

  The decision not to build a scheduler is deliberate and is the kind that
  should carry its numbers: **4 of 154 steps across 2 of 21 workflows declare
  a group**, and all four are read-only research steps. `.agents/constitution.md`
  §25 — do not wire a capability merely because it exists. The three things a
  scheduler would need now all exist (a worktree per run from an earlier change, a
  shared budget from an earlier change, a stop that reaches every branch from
  An earlier change), so this is a choice rather than a limitation, and reversing it
  is a day's work whenever those four steps become forty.

  The grouping key is read with `Access`, which answers `nil` for a key that is
  absent as readily as for one that is present and null — and the decision is
  then made on that value rather than on the shape of the map. It used to be
  made by matching `%{"parallel_group" => nil}`, which requires the key to
  exist; no step in `.agents/workflows/` carries it unless it is in a group, so
  `--show` raised `CaseClauseError` for all twenty workflows. The
  fixtures were more regular than the data, which is the only reason a test
  suite agreed with it.
  """
  @spec waves(t()) :: [[map()]]
  def waves(workflow) do
    (workflow["steps"] || [])
    |> Enum.chunk_by(& &1["parallel_group"])
    |> Enum.flat_map(fn
      [step | _] = chunk ->
        if step["parallel_group"], do: [chunk], else: Enum.map(chunk, &[&1])

      [] ->
        []
    end)
  end

  @doc """
  Structural problems in one workflow, as a list of messages.

  An empty list means the graph is well formed. It does not mean the workflow is
  a good idea.
  """
  @spec validate(t(), %{capabilities: %{String.t() => map()}}, MapSet.t(), MapSet.t()) :: [
          String.t()
        ]
  def validate(workflow, registry, gate_ids, lane_ids) do
    id = workflow["id"] || "(workflow with no id)"
    steps = workflow["steps"] || []
    step_ids = MapSet.new(steps, & &1["id"])

    Enum.concat([
      unknown_capabilities(id, steps, registry),
      unknown_gates(id, workflow, steps, gate_ids, lane_ids),
      dangling_independence(id, steps, step_ids),
      backward_inputs(id, workflow, steps),
      unsupplied_capabilities(id, workflow, steps, registry),
      empty_completion(id, workflow),
      duplicate_step_ids(id, steps)
    ])
  end

  defp unknown_capabilities(id, steps, registry) do
    for step <- steps,
        capability <- step["capabilities"] || [],
        not Map.has_key?(registry.capabilities, capability) do
      "#{id}/#{step["id"]}: unknown capability #{capability}"
    end
  end

  defp unknown_gates(id, workflow, steps, gate_ids, lane_ids) do
    lane = workflow["default_lane"]

    lane_problem =
      if lane && not MapSet.member?(lane_ids, lane),
        do: ["#{id}: unknown default_lane #{lane}"],
        else: []

    step_problems =
      for step <- steps,
          gate <- step["gates"] || [],
          not MapSet.member?(gate_ids, gate) and not MapSet.member?(lane_ids, gate) do
        "#{id}/#{step["id"]}: unknown gate or lane #{gate}"
      end

    lane_problem ++ step_problems
  end

  defp dangling_independence(id, steps, step_ids) do
    for step <- steps,
        other <- step["independent_of"] || [],
        not MapSet.member?(step_ids, other) do
      "#{id}/#{step["id"]}: independent_of names step #{other}, which does not exist — " <>
        "the review-fabric constraint this expresses is silently inactive"
    end
  end

  # A step's declared inputs should be produced by an earlier step or declared
  # as a workflow input. Free-text inputs like "repository" or "logs" are
  # environment, not artifacts, so only inputs that exactly match some step's
  # output name are position-checked.
  defp backward_inputs(id, workflow, steps) do
    outputs_by_index =
      steps
      |> Enum.with_index()
      |> Enum.flat_map(fn {step, index} -> Enum.map(step["outputs"] || [], &{&1, index}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    declared = MapSet.new(get_in(workflow, ["artifacts", "in"]) || [])

    for {step, index} <- Enum.with_index(steps),
        input <- step["inputs"] || [],
        not MapSet.member?(declared, input),
        producers = Map.get(outputs_by_index, input, []),
        producers != [],
        Enum.min(producers) > index do
      "#{id}/#{step["id"]}: consumes #{inspect(input)}, which is only produced by a later step"
    end
  end

  # Per capability, not per step. A step needing two capabilities is covered by a
  # two-role team — that is what the router's set cover is for, and requiring one
  # role to hold both would forbid every genuinely cross-domain step. What must
  # not happen is a capability nobody at all supplies: that step can never run.
  #
  # Supplied on the workflow's own plane: a runtime role never staffs a
  # development step, so it does not count as a supplier for one either.
  defp unsupplied_capabilities(id, workflow, steps, registry) do
    plane = Plane.of(workflow)

    for step <- steps,
        capability <- step["capabilities"] || [],
        Map.has_key?(registry.capabilities, capability),
        Noetic.Harness.Registry.supplying(registry, [capability], plane) == [] do
      "#{id}/#{step["id"]}: no active role supplies #{capability}"
    end
  end

  defp empty_completion(id, workflow) do
    case workflow["completion"] do
      [_ | _] -> []
      _ -> ["#{id}: no completion criteria — a workflow that cannot say when it is done"]
    end
  end

  defp duplicate_step_ids(id, steps) do
    steps
    |> Enum.frequencies_by(& &1["id"])
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {step_id, count} -> "#{id}: step id #{step_id} appears #{count} times" end)
  end
end
