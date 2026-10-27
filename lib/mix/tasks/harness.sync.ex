defmodule Mix.Tasks.Harness.Sync do
  @moduledoc """
  Regenerate the client adapters from the canonical definitions.

      noetic-harness sync                 write everything
      noetic-harness sync --check         report drift without writing
      noetic-harness sync --only claude   just .claude/agents/
      noetic-harness sync --only instructions   just what Codex, Gemini and Cursor read

  Generated files carry a banner naming this command. Editing one is a defect:
  the next sync reverts it, which is the worst way to lose a change. Change the
  canonical definitions under `.agents/` and run this.

  `--check` is what CI would run: it fails when a generated file differs from
  what the definitions produce, which catches both a hand edit and a definition
  change that was never synced.
  """
  @shortdoc "Regenerate the Claude, Codex, Gemini and Cursor adapters from the canonical definitions"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]
  alias Noetic.Harness.{Adapters, Registry}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [check: :boolean, only: :string])
    shell = Mix.shell()
    registry = Registry.load!()

    if opts[:check] do
      case Adapters.drift(registry) do
        [] ->
          shell.info("adapters are in sync")

        drifted ->
          Enum.each(drifted, &shell.error("stale  #{&1}"))
          shell.error("")
          shell.error("#{length(drifted)} generated file(s) differ. Run `noetic-harness sync`.")
          exit({:shutdown, 1})
      end
    else
      only = if opts[:only], do: String.to_existing_atom(opts[:only])

      case Adapters.sync(registry, only: only) do
        {:ok, paths} ->
          shell.info("wrote #{length(paths)} file(s)")

          if only in [nil, :prompts],
            do:
              shell.info(
                "  .agents/prompts/       #{count(paths, "/.agents/prompts/")} standing prompts"
              )

          if only in [nil, :claude],
            do:
              shell.info(
                "  .claude/agents/        #{count(paths, "/.claude/agents/")} nucleus subagents"
              )

          if only in [nil, :index], do: shell.info("  .agents/AGENTS_INDEX.md")

          if only in [nil, :instructions],
            do:
              shell.info(
                "  for Codex, Gemini, Cursor: CLAUDE.md block, GEMINI.md, .cursor/rules/harness.mdc, " <>
                  "and the MCP server in .codex/, .gemini/, .cursor/"
              )

        {:error, message} ->
          Mix.raise(message)
      end
    end
  end

  defp count(paths, fragment), do: Enum.count(paths, &String.contains?(&1, fragment))
end
