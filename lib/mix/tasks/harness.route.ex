defmodule Mix.Tasks.Harness.Route do
  @moduledoc """
  What a work item would route to, and why.

      noetic-harness route --title "add a TypeDB relation for motif authorship"
      noetic-harness route --bead bd-1234
      noetic-harness route --paths lib/my_app/parser.ex --kind bug
      noetic-harness route --title "..." --explain

  This is a dry run. It reads; it changes nothing and it starts nothing.

  `--explain` prints the signals that fired. When a route looks wrong, that
  output says whether the problem is the work item's description or a line in
  `.agents/registry/signals.json` — which is the difference between fixing it
  and arguing with it.
  """
  @shortdoc "Show the workflow, team, lane and gates a work item routes to"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]
  alias Noetic.Harness.{Beads, Router}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          title: :string,
          body: :string,
          bead: :string,
          kind: :string,
          risk: :string,
          paths: :string,
          workflow: :string,
          explain: :boolean,
          max_team: :integer
        ]
      )

    shell = Mix.shell()
    work = work_item(opts)

    if work[:title] in [nil, ""] and work[:paths] in [nil, []] do
      Mix.raise("give me something to route: --title, --bead or --paths")
    end

    case Router.route(work, max_team: opts[:max_team] || 5) do
      {:error, message} ->
        Mix.raise(message)

      {:ok, route} ->
        shell.info("work    #{work[:title] || "(paths only)"}")
        shell.info("")

        shell.info("capabilities  (#{route.confidence} confidence#{score_note(route, opts)})")
        Enum.each(route.capabilities, &shell.info("  #{&1}"))

        if opts[:explain] do
          shell.info("")
          shell.info("kind          #{kind_line(route.kind)}")
          shell.info("")
          shell.info("signals that fired")

          case route.signals do
            [] ->
              shell.info("  (none — the fallback capability set was used)")

            signals ->
              Enum.each(
                signals,
                &shell.info("  #{&1["id"]} on #{Enum.join(&1["matched_on"], "+")}")
              )
          end
        end

        shell.info("")

        case route.workflow do
          nil ->
            shell.info("workflow      none — #{route.workflow_reason}")

          workflow ->
            shell.info("workflow      #{workflow["id"]} #{workflow["name"]}")
            shell.info("              #{route.workflow_reason}")

            if opts[:explain], do: candidates(shell, route.candidates)
        end

        # Printed only on a disagreement, and `nil` for every way
        # of not getting an opinion — unconfigured, unloaded, raised, too slow,
        # or agreeing. The route above has already been computed and would be
        # identical with this line deleted; that is the property, and it is
        # tested rather than asserted.
        case Noetic.Harness.SecondOpinion.on(route) do
          nil -> :ok
          text -> shell.info("              #{text}")
        end

        shell.info("lane          #{route.lane}")
        shell.info("highest trust #{route.trust}")
        shell.info("")
        shell.info("team (smallest set covering the capabilities)")

        Enum.each(route.team, fn agent ->
          shell.info("  #{String.pad_trailing(agent["id"], 42)} #{agent["name"]}")
        end)

        case route.uncovered do
          [] ->
            :ok

          uncovered ->
            shell.info("")
            shell.info("NOT COVERED by any role — this repository has nobody for:")
            Enum.each(uncovered, &shell.info("  #{&1}"))
        end

        shell.info("")
        shell.info("skills  #{Enum.join(route.skills, ", ")}")
        shell.info("tools   #{Enum.join(route.tools, ", ")}")
        shell.info("gates   #{Enum.join(route.gates, ", ")}")

        if route.confidence == :low do
          shell.info("")
          shell.info("Low confidence. The work item is probably too thin to route; say what")
          shell.info("it touches, or run `noetic-harness route --paths ...` once files exist.")
        end
    end
  end

  # The winner's four parts and the runner-up's: a route is
  # arguable when a reader can see what it beat and by how much.
  defp candidates(_shell, []), do: :ok

  defp candidates(shell, [winner | rest]) do
    shell.info("              #{parts(winner)}")

    case rest do
      [] ->
        shell.info("              runner-up     none — no other workflow scored")

      [runner_up | _] ->
        shell.info(
          "              runner-up     #{runner_up.id} at #{runner_up.total} (#{parts(runner_up)})"
        )
    end
  end

  defp parts(c) do
    "family #{c.family} + kind #{c.kind} + keyword #{c.keyword} + " <>
      "capability #{c.capability} = #{c.total}"
  end

  defp score_note(route, opts) do
    if opts[:explain] do
      %{high: high, medium: medium} = route.confidence_thresholds
      ": score #{route.confidence_score}, high at #{high}, medium at #{medium}"
    else
      ""
    end
  end

  defp kind_line(%{value: nil}), do: "none — no kind declared and no family fired"
  defp kind_line(%{value: kind, source: :declared}), do: "#{kind} (declared)"

  defp kind_line(%{value: kind, source: :inferred}),
    do: "#{kind} (inferred from the signals' families)"

  defp work_item(opts) do
    base =
      case opts[:bead] do
        nil ->
          %{}

        id ->
          case Beads.work_item(id) do
            {:ok, item} ->
              item

            :timeout ->
              Mix.raise(
                "`bd show #{id}` did not answer within " <>
                  "#{div(Beads.timeout(), 1000)}s. The tracker is stuck rather than absent, " <>
                  "usually on a Dolt lock held by another session in this working directory."
              )

            :error ->
              Mix.raise("could not read bead #{id} — is `bd` available and the database open?")

            :off ->
              Mix.raise(
                Noetic.Harness.Integrations.off("beads") <>
                  ", so --bead #{id} cannot be read; route on --title instead"
              )
          end
      end

    base
    |> Map.merge(
      compact(%{
        title: opts[:title],
        body: opts[:body],
        kind: opts[:kind],
        risk: opts[:risk],
        workflow: opts[:workflow]
      })
    )
    |> Map.put(:paths, split(opts[:paths]))
  end

  defp compact(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp split(nil), do: []
  defp split(value), do: value |> String.split([",", " "], trim: true)
end
