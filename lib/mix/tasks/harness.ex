defmodule Mix.Tasks.Harness do
  @moduledoc """
  The harness CLI.

      mix harness                       this help
      noetic-harness inspect               what exists, what is wired, what is missing
      noetic-harness agents                the competency registry
      noetic-harness skills                repository-local skills
      noetic-harness workflows             workflow and pipeline definitions
      noetic-harness route                 what a work item would route to
      noetic-harness context               what context would be assembled
      noetic-harness prompt <agent>        the prompt an agent would receive
      noetic-harness gates                 gate lanes: what runs, what is unavailable
      noetic-harness memory                project memory
      noetic-harness kb <words>            the knowledge base, from the files
      noetic-harness evolution             candidates, lineage, promotion readiness
      noetic-harness validate              everything above, checked
      noetic-harness sync                  regenerate the client adapters

  Each takes `--help`.
  """
  @shortdoc "The product development harness CLI"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info(@moduledoc)
  end
end
