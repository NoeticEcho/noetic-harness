defmodule Mix.Tasks.Harness.Workflows do
  @moduledoc """
  Workflow and pipeline definitions.

      noetic-harness workflows                  the catalogue
      noetic-harness workflows --show WF-002    one workflow, step by step
      noetic-harness workflows --pipelines      the pipeline catalogue

  `--show` prints each step with the capabilities it needs, the role the router
  would pick for it, the trust it is granted and the gates it must pass — which
  is the closest thing to watching the workflow run without running it.

  A runtime workflow is listed and shown, marked as one, with the runtime roles
  that hold each step's capabilities: the development engine never staffs or
  starts it, and the router would pick nobody.
  """
  @shortdoc "List and inspect workflows"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]
  alias Noetic.Harness.{Plane, Registry, Router, Workflow}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [show: :string, pipelines: :boolean])
    shell = Mix.shell()

    cond do
      opts[:pipelines] -> pipelines(shell)
      id = opts[:show] -> show(shell, id)
      true -> catalogue(shell)
    end
  end

  defp catalogue(shell) do
    workflows = Workflow.list!()

    Enum.each(workflows, fn workflow ->
      shell.info(
        "#{workflow["id"]}  #{String.pad_trailing(workflow["name"], 32)} " <>
          "#{String.pad_trailing(workflow["family"], 12)} " <>
          "#{String.pad_trailing(workflow["default_lane"], 9)} #{length(workflow["steps"])} steps" <>
          if(Plane.runtime?(workflow), do: "  runtime", else: "")
      )
    end)

    shell.info("")
    shell.info("#{length(workflows)} workflows. `--show <id>` for the steps.")
  end

  defp show(shell, id) do
    case Workflow.fetch(id, :any) do
      :error ->
        Mix.raise("no workflow #{id}")

      {:ok, workflow} ->
        registry = Registry.load!()
        runtime = Plane.runtime?(workflow)

        shell.info("#{workflow["id"]} — #{workflow["name"]}")
        shell.info(workflow["intent"])

        if runtime do
          shell.info("")

          shell.info(
            "A runtime workflow: a product runs it from `harness export`, and the " <>
              "development engine never starts, staffs or dispatches it."
          )
        end

        shell.info("")

        shell.info(
          "family #{workflow["family"]}   lane #{workflow["default_lane"]}   retries #{workflow["retry_budget"]}"
        )

        shell.info("")

        workflow
        |> Workflow.waves()
        |> Enum.with_index(1)
        |> Enum.each(fn {wave, index} ->
          # "(in parallel)" was a claim nothing made true: the dispatcher runs
          # one step at a time and always has. A declared group says these
          # steps do not depend on each other, which is a fact about the
          # workflow; it does not say anything schedules them. 
          parallel =
            if length(wave) > 1, do: "  (independent of each other; run in order)", else: ""

          shell.info("#{index}.#{parallel}")

          Enum.each(wave, fn step ->
            {team, uncovered} = staff(registry, step["capabilities"], runtime)
            who = team |> Enum.map(& &1["id"]) |> Enum.join(" + ")

            who =
              case uncovered do
                [] -> who
                missing -> who <> "  [UNCOVERED: #{Enum.join(missing, ", ")}]"
              end

            shell.info("   #{step["id"]} — #{step["name"]}")
            shell.info("     needs  #{Enum.join(step["capabilities"], ", ")}")
            shell.info("     who    #{who}")
            shell.info("     trust  #{step["trust"]}#{gates(step)}#{independence(step)}")

            if step["optional"],
              do: shell.info("     optional: #{step["applies_when"] || "when it applies"}")
          end)
        end)

        shell.info("")
        shell.info("escalations:")
        Enum.each(workflow["escalations"], &shell.info("  #{&1["when"]} → #{&1["to"]}"))
        shell.info("")
        shell.info("done when:")
        Enum.each(workflow["completion"], &shell.info("  - #{&1}"))
    end
  end

  # A runtime step is shown with the runtime roles holding its capabilities,
  # one per capability: the router's team never includes one.
  defp staff(registry, capabilities, false), do: Router.compose_team(registry, capabilities, 2)

  defp staff(registry, capabilities, true) do
    Enum.reduce(capabilities, {[], []}, fn capability, {team, uncovered} ->
      case Registry.supplying(registry, [capability], "runtime") do
        [] -> {team, uncovered ++ [capability]}
        [role | _] -> {Enum.uniq_by(team ++ [role], & &1["id"]), uncovered}
      end
    end)
  end

  defp gates(%{"gates" => [_ | _] = gates}), do: "   gates  #{Enum.join(gates, ", ")}"
  defp gates(_), do: ""

  defp independence(%{"independent_of" => [_ | _] = steps}),
    do: "   must not be the agent from: #{Enum.join(steps, ", ")}"

  defp independence(_), do: ""

  defp pipelines(shell) do
    {:ok, pipelines} = Workflow.pipelines()

    Enum.each(pipelines, fn pipeline ->
      shell.info("#{pipeline["id"]}  #{pipeline["name"]}")
      shell.info("     #{Enum.join(pipeline["stages"], " → ")}")

      case pipeline["gates"] do
        empty when empty in [nil, %{}] ->
          :ok

        gates ->
          shell.info(
            "     gates: " <>
              Enum.map_join(gates, ", ", fn {stage, gate} -> "#{stage}=#{gate}" end)
          )
      end
    end)
  end
end
