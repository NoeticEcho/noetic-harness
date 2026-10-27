defmodule Mix.Tasks.Harness.Skills do
  @moduledoc """
  Repository-local skills, discovered from disk.

      noetic-harness skills                every skill, both roots
      noetic-harness skills --show <name>  print one

  There is no index file. Discovery is a directory walk, because an index is a
  second place for the truth to live and it goes stale the first time somebody
  adds a skill without updating it.
  """
  @shortdoc "List repository-local skills"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]
  alias Noetic.Harness.Skills

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [show: :string])
    shell = Mix.shell()

    case opts[:show] do
      nil ->
        skills = Skills.list()

        Enum.each(skills, fn skill ->
          shell.info(
            "#{String.pad_trailing(skill.name, 30)} #{String.pad_trailing(to_string(skill.root), 8)} " <>
              "#{String.slice(skill.description, 0, 90)}"
          )
        end)

        shell.info("")

        shell.info(
          "#{length(skills)} skills. `agents` = .agents/skills, `claude` = .claude/skills."
        )

      name ->
        case Skills.read(name) do
          {:ok, body} -> shell.info(body)
          {:error, message} -> Mix.raise(message)
        end
    end
  end
end
