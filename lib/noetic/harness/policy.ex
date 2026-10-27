defmodule Noetic.Harness.Policy do
  @moduledoc """
  Trust levels, tool permissions and gate definitions — the three policies that
  decide what an agent is allowed to do.

  ## Trust is scoped, and the effective level is the minimum

  A role declares the highest trust it may ever be granted; a workflow step
  grants a level for that step. The effective level is `min(role, step)`, and
  nothing in a task prompt raises it. `resolve_trust/2` is that rule, in one
  place, so that it cannot be re-implemented differently by the router and the
  prompt renderer.

  ## Tools report what they are, not what we hoped

  `.agents/policies/tools.json` records each tool's expected presence and a
  probe command. `probe/1` runs the probe. Where the record and reality
  disagree, `noetic-harness inspect` says so — a tool marked present that is
  missing is the setup for a gate that silently does not run.
  """

  alias Noetic.Harness.Loader

  @levels ~w(T0 T1 T2 T3 T4 T5)

  @doc "The trust-level policy."
  @spec trust_levels() :: {:ok, map()} | {:error, String.t()}
  def trust_levels, do: Loader.cached_load(path("trust_levels.json"))

  @doc "The tool policy."
  @spec tools() :: {:ok, map()} | {:error, String.t()}
  def tools, do: Loader.cached_load(path("tools.json"))

  @doc "The gate and lane definitions."
  @spec gates() :: {:ok, map()} | {:error, String.t()}
  def gates, do: Loader.cached_load(path("gates.json"))

  @doc """
  What bounds a dispatching run: depth, wall-clock and cost.

  Inside the evaluator fence, because a run that can raise its own ceiling has
  none. `Noetic.Harness.Dispatcher` reads it; nothing writes it.
  """
  @spec dispatch() :: {:ok, map()} | {:error, String.t()}
  def dispatch, do: Loader.cached_load(path("dispatch.json"))

  @doc "Tool definitions indexed by id."
  @spec tools_by_id() :: {:ok, %{String.t() => map()}} | {:error, String.t()}
  def tools_by_id do
    with {:ok, doc} <- tools() do
      {:ok, Map.new(doc["tools"], &{&1["id"], &1})}
    end
  end

  @doc "Gate definitions indexed by id."
  @spec gates_by_id() :: {:ok, %{String.t() => map()}} | {:error, String.t()}
  def gates_by_id do
    with {:ok, doc} <- gates() do
      {:ok, Map.new(doc["gates"], &{&1["id"], &1})}
    end
  end

  @doc "The ordered trust level ids."
  @spec levels() :: [String.t()]
  def levels, do: @levels

  @doc """
  The effective trust level: the stricter of what the role may hold and what the
  step grants.

  Both arguments are advisory in different directions and the minimum is the
  only safe combination — a step that grants T4 does not promote a T1 role, and
  a T4 role does not carry T4 into a step that only needs T1.
  """
  @spec resolve_trust(String.t() | nil, String.t() | nil) :: String.t()
  def resolve_trust(role_max, step_grant) do
    a = rank(role_max)
    b = rank(step_grant)

    cond do
      is_nil(a) and is_nil(b) -> "T0"
      is_nil(a) -> step_grant
      is_nil(b) -> role_max
      a <= b -> role_max
      true -> step_grant
    end
  end

  @doc """
  The effective trust of a **dispatched** run: the stricter of what its parent
  already holds, what the child's role may hold, and what the step grants.

  A parent that can set its child's trust can launder its own, so
  there is no argument, flag, environment variable or configuration key that
  raises the result — this function takes the parent's effective trust as an
  argument and is the only place a dispatched agent's trust is decided, which
  is what makes "where could this be raised?" a question with one place to
  look.

  A root run — one a human started — passes `nil` for the parent and gets
  `resolve_trust/2`'s answer. Depth zero is not the case that grants more; it
  is the case that grants least, because nothing above it has already been
  narrowed.

      iex> Noetic.Harness.Policy.derive_trust("T3", "T4", "T4")
      "T3"

      iex> Noetic.Harness.Policy.derive_trust("T1", "T4", "T4")
      "T1"

      iex> Noetic.Harness.Policy.derive_trust(nil, "T2", "T4")
      "T2"
  """
  @spec derive_trust(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def derive_trust(parent_effective, role_max, step_grant) do
    own = resolve_trust(role_max, step_grant)

    case rank(parent_effective) do
      nil -> own
      parent -> if parent <= rank(own), do: parent_effective, else: own
    end
  end

  @doc "True when `level` is at least `required`."
  @spec at_least?(String.t(), String.t()) :: boolean()
  def at_least?(level, required) do
    case {rank(level), rank(required)} do
      {nil, _} -> false
      {_, nil} -> false
      {a, b} -> a >= b
    end
  end

  @doc """
  The tools a role may actually hold at a trust level.

  Returns `{granted, withheld}`. A tool the role lists but whose `min_trust` is
  above the effective level is withheld — and the prompt says so, because an
  agent that believes it holds a tool it cannot use will plan around having it.
  """
  @spec grant_tools([String.t()], String.t(), %{String.t() => map()}) ::
          {[String.t()], [{String.t(), String.t()}]}
  def grant_tools(wanted, trust, tool_defs) do
    Enum.reduce(wanted, {[], []}, fn id, {granted, withheld} ->
      case Map.fetch(tool_defs, id) do
        {:ok, %{"min_trust" => min}} ->
          if at_least?(trust, min),
            do: {[id | granted], withheld},
            else: {granted, [{id, "requires #{min}, this run holds #{trust}"} | withheld]}

        :error ->
          {granted, [{id, "not defined in .agents/policies/tools.json"} | withheld]}
      end
    end)
    |> then(fn {granted, withheld} -> {Enum.sort(granted), Enum.sort(withheld)} end)
  end

  @doc """
  Run a tool's probe.

  Returns `:present`, `:absent` or `:unprobeable` — the last for a tool with no
  probe command, such as an MCP server whose availability the harness cannot
  test from a shell. `:unprobeable` is reported as itself and never rounded to
  `:present`.
  """
  @spec probe(map()) :: :present | :absent | :unprobeable
  def probe(%{"probe" => command}) when is_binary(command) and command != "" do
    case run(command) do
      {_output, 0} -> :present
      _ -> :absent
    end
  end

  def probe(_tool), do: :unprobeable

  defp run(command) do
    System.cmd("sh", ["-c", command], stderr_to_stdout: true, cd: Noetic.Harness.root())
  rescue
    _ -> {"", 127}
  end

  defp rank(nil), do: nil
  defp rank(level), do: Enum.find_index(@levels, &(&1 == level))

  defp path(file), do: Path.join(Noetic.Harness.agents_path("policies"), file)
end
