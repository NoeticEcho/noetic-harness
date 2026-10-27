defmodule Mix.Tasks.Harness.Plugin do
  @moduledoc """
  Rewrite the Claude Code plugin's subagents from the starter pack, or check
  that they are in step with it.

      noetic-harness plugin            rewrite priv/plugin/agents/
      noetic-harness plugin --check    list what differs, and exit non-zero if anything does

  The plugin's skills, manifest and README are written by hand and are not
  touched. `Noetic.Harness.Plugin` says how the agents are made, and why each
  carries its whole prompt.
  """
  @shortdoc "Rewrite or check the plugin's subagents from the starter pack"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever
  # beams the last compile left, and answers for code that is not on disk.
  @requirements ["compile"]

  alias Noetic.Harness.Plugin

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [check: :boolean])
    shell = Mix.shell()

    if opts[:check] do
      case Plugin.drift() do
        [] ->
          shell.info("the plugin's agents are what the starter pack makes")

        paths ->
          shell.error(
            "#{length(paths)} of the plugin's agents differ from what the starter pack " <>
              "makes now; `harness plugin` rewrites them:"
          )

          Enum.each(paths, &shell.error("  #{&1}"))
          exit({:shutdown, 1})
      end
    else
      written = Plugin.write!()
      shell.info("wrote #{length(written)} agent(s) into #{Path.join(Plugin.dir(), "agents")}")
    end
  end
end
