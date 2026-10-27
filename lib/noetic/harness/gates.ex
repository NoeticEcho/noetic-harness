defmodule Noetic.Harness.Gates do
  @moduledoc """
  Running gate lanes, and reporting honestly what did not run.

  ## The whole point is the fourth outcome

  A gate reports `passed`, `failed`, `skipped` or **`unavailable`**, and the
  fourth is why this module exists. A scanner that is not installed, a service
  that is not running, a renderer with no browser — each of these is a hole in
  the lane, and a harness that reports the lane green with a hole in it has
  taught every agent downstream that the check happened. `run/2` therefore
  returns `:partial` for a lane containing an unavailable blocking gate, never
  `:passed`, and the summary names what is consequently unverified.

  `skipped` is different and benign: the gate's `applies_when` did not match the
  change. A TypeQL gate on a change that touches no TypeQL is not a hole.

  ## Lanes are floors

  A lane expands transitively — `release` contains `full`, which contains its
  own gates — and a caller may raise a lane but not lower one. `fast` exists for
  work in progress; it is not a way to land a change with fewer checks.

  ## What this module will not do

  It will not modify a gate, relax a threshold or add an exclusion. Gate
  definitions live in `.agents/policies/gates.json` and changing them is a T4
  action with its own review, because "the gate was in the way" is how a gate
  stops being one.
  """

  alias Noetic.Harness.{Git, Policy}

  @type outcome :: :passed | :failed | :skipped | :unavailable
  @type result :: %{
          id: String.t(),
          name: String.t(),
          kind: String.t(),
          severity: String.t(),
          outcome: outcome(),
          command: String.t() | nil,
          detail: String.t(),
          duration_ms: non_neg_integer()
        }

  @doc "Lane ids, in definition order."
  @spec lanes() :: {:ok, [String.t()]} | {:error, String.t()}
  def lanes do
    with {:ok, doc} <- Policy.gates(), do: {:ok, Enum.map(doc["lanes"], & &1["id"])}
  end

  @doc """
  Every gate in a lane, with nested lanes expanded.

  Expansion is transitive and cycle-safe: a lane that names itself, directly or
  through another lane, contributes its gates once instead of looping.
  """
  @spec expand(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def expand(lane_id) do
    with {:ok, doc} <- Policy.gates() do
      gate_ids = MapSet.new(doc["gates"], & &1["id"])

      case Enum.find(doc["lanes"], &(&1["id"] == lane_id)) do
        nil -> {:error, "no lane named #{lane_id}"}
        _lane -> {:ok, do_expand(lane_id, doc["lanes"], gate_ids, MapSet.new())}
      end
    end
  end

  @doc """
  Which gates in a lane apply to a set of changed paths.

  A gate with no `applies_when` always applies. A gate with one applies when any
  of its patterns matches any changed path — and when the caller supplies no
  paths at all, it also applies, because "we do not know what changed" is not a
  reason to skip a check.
  """
  @spec applicable(String.t(), [String.t()]) :: {:ok, [map()]} | {:error, String.t()}
  def applicable(lane_id, paths) do
    with {:ok, ids} <- expand(lane_id),
         {:ok, defs} <- Policy.gates_by_id() do
      {:ok,
       ids
       |> Enum.map(&Map.get(defs, &1))
       |> Enum.reject(&is_nil/1)
       |> Enum.filter(&applies?(&1, paths))}
    end
  end

  @doc """
  Run a lane.

  Options:

    * `:paths` — the changed paths. Defaults to the working tree's, via git.
    * `:dry_run` — resolve and report without executing (default `false`).
    * `:only` — run just these gate ids.

  Returns `{status, results}` where status is `:passed`, `:failed` or
  `:partial`.
  """
  @spec run(String.t(), keyword()) ::
          {:ok, {:passed | :failed | :partial, [result()]}} | {:error, String.t()}
  def run(lane_id, opts \\ []) do
    # `paths: nil` means the same as no `:paths` at all. A caller that builds
    # its options with `Keyword.take/2` hands over `[paths: nil]` without
    # meaning to, and `Keyword.get_lazy/3` treats that as an answer — which
    # reached `applies?/2` as a nil to enumerate and crashed the lane rather
    # than running it.
    paths =
      case Keyword.get(opts, :paths) do
        nil ->
          case Git.changed_paths() do
            {:ok, paths} -> paths
            :error -> []
          end

        paths ->
          paths
      end

    with {:ok, gates} <- applicable(lane_id, paths),
         {:ok, tool_defs} <- Policy.tools_by_id() do
      only = Keyword.get(opts, :only)
      gates = if only, do: Enum.filter(gates, &(&1["id"] in only)), else: gates

      results =
        Enum.map(gates, fn gate ->
          execute(gate, tool_defs, paths, Keyword.get(opts, :dry_run, false))
        end)

      {:ok, {status(results), results}}
    end
  end

  @doc """
  The overall status of a set of results.

  A failed blocking gate makes the lane `:failed`. An unavailable blocking gate
  makes it `:partial` — which is deliberately not `:passed` and deliberately not
  `:failed`, because the work is neither verified nor disproved.
  """
  @spec status([result()]) :: :passed | :failed | :partial
  def status(results) do
    blocking = Enum.filter(results, &(&1.severity == "blocking"))

    cond do
      Enum.any?(blocking, &(&1.outcome == :failed)) -> :failed
      Enum.any?(blocking, &(&1.outcome == :unavailable)) -> :partial
      true -> :passed
    end
  end

  @doc """
  The report an agent pastes into its completion evidence.

  In the constitution's shape: what was attempted, what failed, why, what is
  still valid and what is consequently unverified. A summary that lists only the
  passes is the report this format exists to prevent.
  """
  @spec summarise(String.t(), {:passed | :failed | :partial, [result()]}) :: String.t()
  def summarise(lane_id, {status, results}) do
    lines =
      Enum.map_join(results, "\n", fn result ->
        "  #{pad(result.outcome)} #{result.id}#{detail_suffix(result)}"
      end)

    unverified =
      results
      |> Enum.filter(&(&1.outcome == :unavailable))
      |> Enum.map(&"  - #{&1.id}: #{&1.detail}")

    unverified_block =
      case unverified do
        [] -> ""
        list -> "\nunverified:\n" <> Enum.join(list, "\n")
      end

    failed_block =
      case Enum.filter(results, &(&1.outcome == :failed)) do
        [] ->
          ""

        list ->
          "\nfailed:\n" <> Enum.map_join(list, "\n", &"  - #{&1.id}: #{excerpt(&1.detail)}")
      end

    "lane #{lane_id}: #{status}\n#{lines}#{failed_block}#{unverified_block}"
  end

  # A failing gate's *first* 400 characters are the least useful 400 characters
  # it has. `mix cmd --app <x> mix test` opened with a deprecation warning and a
  # six-line stack trace from `Mix.Tasks.Cmd`, and the head-truncated report
  # therefore said nothing at all about which test failed — measured twice
  # today, on a lane that had to be reproduced by hand to find out what it
  # meant. ExUnit prints its failures and its counts at the *end*, so the tail
  # is where the answer is, and the head is kept only because a gate that could
  # not start says so in its first line.
  @head 300
  @tail 2_000

  defp excerpt(detail) do
    if byte_size(detail) <= @head + @tail do
      detail
    else
      String.slice(detail, 0, @head) <>
        "\n    … #{byte_size(detail) - @head - @tail} bytes elided; the tail follows …\n" <>
        String.slice(detail, -@tail, @tail)
    end
  end

  # ---- execution -----------------------------------------------------------

  defp execute(gate, tool_defs, paths, dry_run) do
    base = %{
      id: gate["id"],
      name: gate["name"],
      kind: gate["kind"],
      severity: gate["severity"],
      command: gate["command"],
      outcome: :skipped,
      detail: "",
      duration_ms: 0
    }

    cond do
      gate["kind"] != "command" ->
        %{
          base
          | outcome: :unavailable,
            detail:
              "#{gate["kind"]} gate — it is satisfied by evidence or by a named holder" <>
                holder_suffix(gate) <> ", not by a command this runner can execute"
        }

      missing = missing_tools(gate, tool_defs) ->
        %{
          base
          | outcome: :unavailable,
            detail: "requires #{Enum.join(missing, ", ")}, not available here"
        }

      dry_run ->
        %{base | outcome: :skipped, detail: "dry run"}

      true ->
        run_command(base, gate, paths)
    end
  end

  defp run_command(base, gate, paths) do
    command = interpolate(gate["command"], paths)
    started = System.monotonic_time(:millisecond)

    {output, code} =
      try do
        System.cmd("sh", ["-c", command], cd: Noetic.Harness.root(), stderr_to_stdout: true)
      rescue
        error -> {Exception.message(error), 127}
      end

    elapsed = System.monotonic_time(:millisecond) - started

    %{
      base
      | command: command,
        outcome: if(code == 0, do: :passed, else: :failed),
        detail: String.trim(output),
        duration_ms: elapsed
    }
  end

  # A gate's tools must be *probed*, not trusted: `tools.json` records what we
  # expect, and the expectation is exactly the thing that goes stale.
  defp missing_tools(gate, tool_defs) do
    missing =
      (gate["requires"] || [])
      |> Enum.filter(fn id ->
        case Map.fetch(tool_defs, id) do
          {:ok, definition} -> Policy.probe(definition) == :absent
          :error -> true
        end
      end)

    if missing == [], do: nil, else: missing
  end

  defp interpolate(command, paths) do
    command
    |> String.replace("{{files}}", Enum.join(paths, " "))
    |> String.replace("{{app}}", "noetic_harness")
  end

  defp applies?(gate, paths) do
    case gate["applies_when"] do
      nil ->
        true

      [] ->
        true

      patterns ->
        paths == [] or
          Enum.any?(patterns, fn pattern ->
            regex = Regex.compile!(pattern, "i")
            Enum.any?(paths, &Regex.match?(regex, &1))
          end)
    end
  end

  defp do_expand(lane_id, lanes, gate_ids, seen) do
    if MapSet.member?(seen, lane_id) do
      []
    else
      seen = MapSet.put(seen, lane_id)

      case Enum.find(lanes, &(&1["id"] == lane_id)) do
        nil ->
          []

        lane ->
          lane["gates"]
          |> Enum.flat_map(fn id ->
            if MapSet.member?(gate_ids, id), do: [id], else: do_expand(id, lanes, gate_ids, seen)
          end)
          |> Enum.uniq()
      end
    end
  end

  defp holder_suffix(%{"holder" => holder}) when is_binary(holder), do: " (#{holder})"
  defp holder_suffix(_), do: ""

  defp pad(outcome), do: outcome |> to_string() |> String.pad_trailing(12)

  defp detail_suffix(%{outcome: :passed, duration_ms: ms}), do: " (#{ms}ms)"
  defp detail_suffix(%{outcome: :unavailable, detail: detail}), do: " — #{detail}"
  defp detail_suffix(%{outcome: :skipped, detail: ""}), do: " — does not apply to this change"
  defp detail_suffix(%{outcome: :skipped, detail: detail}), do: " — #{detail}"
  defp detail_suffix(_), do: ""
end
