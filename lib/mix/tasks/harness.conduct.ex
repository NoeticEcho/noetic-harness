defmodule Mix.Tasks.Harness.Conduct do
  @shortdoc "What happens next in a run, and what will not be advised"

  @moduledoc """
  The conductor: budgets, stalls, loops, failure routing and owed artifacts.

      noetic-harness conduct                       # the current run
      noetic-harness conduct --run <id>
      noetic-harness conduct --classify "<evidence>"
      noetic-harness conduct --json

  It reads a run and its workflow and says what to do next. **It never calls an
  agent and never records anything** — a design decision is the decision and the reason.
  The step it suggests is a suggestion; the refusals are the product, and each
  one names the rule and the file the rule lives in so that it can be argued
  with.

  Three exit codes, so that a script driving a run stops for the same reasons a
  person would: **0** there is a step to take, **1** a state the workflow does
  not continue from (stalled, exhausted, looping, blocked), **2** nothing is
  left to do (complete, closed). A driver that treated "complete" as "keep
  going" would spin.

  ## Options

    * `--run <id>` — a run other than the current one
    * `--classify "<text>"` — which failure class this evidence looks like, and
      where that routes, without touching a run
    * `--json`
  """

  use Mix.Task

  alias Noetic.Harness.{Conductor, Loader, Run}

  @requirements ["app.config"]

  @halting ~w(stalled exhausted looping blocked)
  @finished ~w(complete closed)

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [run: :string, classify: :string, json: :boolean])

    shell = Mix.shell()

    cond do
      opts[:classify] -> classify(shell, opts[:classify], opts)
      true -> conduct(shell, opts)
    end
  end

  defp conduct(shell, opts) do
    case resolve(opts[:run]) do
      {:error, message} ->
        shell.error(message)
        exit({:shutdown, 1})

      {:ok, run_id} ->
        case Conductor.next(run_id) do
          {:error, message} ->
            shell.error(message)
            exit({:shutdown, 1})

          {:ok, advice} ->
            if opts[:json], do: shell.info(Loader.pretty!(advice)), else: render(shell, advice)
            if advice.state in @halting, do: exit({:shutdown, 1})
            if advice.state in @finished, do: exit({:shutdown, 2})
        end
    end
  end

  defp resolve(nil) do
    case Run.current() do
      {:ok, run} -> {:ok, run["id"]}
      {:error, message} -> {:error, message}
      :error -> {:error, ~s|no open run. `noetic-harness run --start <workflow> --title "..."`|}
    end
  end

  # A run id becomes a path, so it has to look like one this module wrote.
  defp resolve(id) do
    if Regex.match?(~r|^[A-Za-z0-9._-]+$|, id) and not String.contains?(id, ".."),
      do: {:ok, id},
      else: {:error, "#{inspect(id)} is not a run id"}
  end

  defp render(shell, advice) do
    shell.info("#{advice.run}  #{advice.workflow}  lane #{advice.lane}")
    shell.info("state #{advice.state}")
    shell.info("")

    if advice.reason, do: Enum.each(wrap(advice.reason), &shell.info("  " <> &1))

    if step = advice.step do
      shell.info("")
      shell.info("next  #{step["id"]}  #{step["name"]}")

      shell.info(
        "      trust #{step["trust"]}  capabilities #{Enum.join(step["capabilities"], ", ")}"
      )

      if step["gates"] != nil and step["gates"] != [] do
        shell.info("      gates #{Enum.join(step["gates"], ", ")}")
      end

      case Conductor.who(step) do
        {:ok, agent} ->
          shell.info("      role  #{agent["id"]} — `noetic-harness prompt #{agent["id"]}`")

        {:partial, agent, missing} ->
          shell.info(
            "      role  #{agent["id"]}, which does not cover #{Enum.join(missing, ", ")}"
          )

          shell.info(
            "            `noetic-harness route` composes a team; no one role holds all of this"
          )

        :none ->
          shell.info("      role  nothing in the registry supplies these capabilities")
      end
    end

    routing(shell, advice.routing)

    if advice.refusals != [] do
      shell.info("")
      shell.info("refused")

      Enum.each(advice.refusals, fn refusal ->
        # The marker goes on the first line only; repeating it down a wrapped
        # paragraph reads as four refusals instead of one.
        refusal
        |> wrap()
        |> Enum.with_index()
        |> Enum.each(fn
          {line, 0} -> shell.info("  ✗ " <> line)
          {line, _} -> shell.info("    " <> line)
        end)
      end)
    end
  end

  defp routing(_shell, nil), do: :ok
  defp routing(_shell, routing) when routing == %{}, do: :ok

  defp routing(shell, routing) do
    shell.info("")
    shell.info("routing")
    shell.info("  #{routing["class"]}")
    if routing["route"], do: shell.info("  → #{routing["route"]}")
    if routing["then"], do: shell.info("  → then #{routing["then"]}")
    if routing["why"], do: Enum.each(wrap(routing["why"]), &shell.info("  " <> &1))
    if routing["note"], do: Enum.each(wrap(routing["note"]), &shell.info("  " <> &1))
    if routing["stop"], do: shell.info("  the policy stops here rather than continuing")
  end

  defp classify(shell, text, opts) do
    case Conductor.classify(text) do
      :none ->
        shell.info("no class in .agents/policies/failure.json matches this.")
        shell.info("")
        shell.info("That is an answer, not a gap to paper over: an unclassified failure routes")
        shell.info("nowhere, which beats routing it to whichever role sounded closest. If this")
        shell.info("shape recurs, add a class — the Markdown table and the JSON are checked")
        shell.info("against each other by `noetic-harness validate`.")

      {:ok, class} ->
        if opts[:json] do
          shell.info(Loader.pretty!(class))
        else
          shell.info("#{class["id"]}  —  #{class["observed"]}")
          shell.info("  → #{class["route"]}")
          if class["then"], do: shell.info("  → then #{class["then"]}")
          Enum.each(wrap(class["why"]), &shell.info("  " <> &1))
          if class["stop"], do: shell.info("  the policy stops here rather than continuing")
        end
    end
  end

  # The refusals are paragraphs on purpose — a refusal that does not say which
  # rule it comes from cannot be argued with — and a terminal is 80 columns.
  defp wrap(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce([[]], fn word, [line | rest] ->
      if IO.iodata_length([Enum.intersperse(line, " "), " ", word]) > 76,
        do: [[word], line | rest],
        else: [line ++ [word] | rest]
    end)
    |> Enum.reverse()
    |> Enum.map(&Enum.join(&1, " "))
  end
end
