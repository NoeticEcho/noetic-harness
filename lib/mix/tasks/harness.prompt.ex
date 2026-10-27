defmodule Mix.Tasks.Harness.Prompt do
  @moduledoc """
  The prompt an agent would actually receive.

      noetic-harness prompt backend.typedb_engineer
      noetic-harness prompt backend.typedb_engineer --workflow WF-002 --step implement
      noetic-harness prompt qa.qa_architect --task bd-1234 --render-context
      noetic-harness prompt --all --check    compose all 270 and report any that fail

  With no workflow this is the role's *standing* prompt: what it is, what it
  owns, how it works. With a workflow step and a task it is the runtime prompt,
  context bundle included.

  `--all --check` is what the validator runs. Composing every prompt is the only
  way "every registered agent has a usable prompt" stays a fact rather than an
  intention.
  """
  @shortdoc "Render an agent's composed prompt"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]
  alias Noetic.Harness.{Beads, Context, Prompt, Registry, Router}

  @impl Mix.Task
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(args,
        strict: [
          workflow: :string,
          step: :string,
          task: :string,
          title: :string,
          lane: :string,
          trust: :string,
          all: :boolean,
          check: :boolean,
          render_context: :boolean
        ]
      )

    shell = Mix.shell()

    cond do
      opts[:all] -> check_all(shell)
      rest == [] -> Mix.raise("which agent? `noetic-harness agents` lists them.")
      true -> one(shell, hd(rest), opts)
    end
  end

  defp one(shell, agent_id, opts) do
    task = task_for(opts)

    context =
      if opts[:render_context] do
        case Router.route(task) do
          {:ok, route} ->
            case Context.build(task, capabilities: route.capabilities, paths: task[:paths] || []) do
              {:ok, bundle} -> bundle
              {:error, _} -> nil
            end

          {:error, _} ->
            nil
        end
      end

    compose_opts =
      [
        workflow: opts[:workflow],
        step: opts[:step],
        task: task,
        context: context,
        lane: opts[:lane],
        trust: opts[:trust]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Prompt.compose(agent_id, compose_opts) do
      {:ok, prompt} -> shell.info(prompt)
      {:error, message} -> Mix.raise(message)
    end
  end

  defp check_all(shell) do
    registry = Registry.load!()

    failures =
      registry.agents
      |> Enum.map(fn agent -> {agent["id"], Prompt.compose(agent["id"])} end)
      |> Enum.filter(&match?({_id, {:error, _}}, &1))

    Enum.each(failures, fn {id, {:error, message}} -> shell.error("#{id}: #{message}") end)

    shell.info("")

    shell.info(
      "#{length(registry.agents) - length(failures)}/#{length(registry.agents)} roles compose a prompt"
    )

    if failures != [], do: exit({:shutdown, 1})
  end

  defp task_for(opts) do
    base =
      case opts[:task] do
        nil ->
          %{}

        id ->
          case Beads.work_item(id) do
            {:ok, item} ->
              item

            :timeout ->
              %{id: id, title: "(bead #{id}: `bd` did not answer in time)", body: ""}

            :error ->
              %{id: id, title: "(bead #{id} could not be read)", body: ""}

            :off ->
              %{
                id: id,
                title: "(bead #{id}: #{Noetic.Harness.Integrations.off("beads")})",
                body: ""
              }
          end
      end

    if opts[:title], do: Map.put(base, :title, opts[:title]), else: base
  end
end
