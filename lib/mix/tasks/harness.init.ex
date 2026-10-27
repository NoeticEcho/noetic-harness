defmodule Mix.Tasks.Harness.Init do
  @moduledoc """
  Write the starter pack into a repository that has no `.agents/`.

      noetic-harness init                       into the directory you ran it from
      noetic-harness init --path ../other-repo  into another one
      noetic-harness init --with elixir         with an add-on (repeatable)
      noetic-harness init --force               over an existing .agents/

  `noetic-harness init` is the same, and it reads `--path` from the directory you
  ran it in rather than from this checkout.

  Without `--force`, an existing `.agents/` is left untouched: the task says
  which of the pack's files are already there and exits non-zero. With it, the
  pack's files are written over those and nothing else under `.agents/` is
  touched or deleted. `Noetic.Harness.Starter` says what the pack is.

  It ends by printing the next four commands: sync, route, the gate plan, and
  a run.

  ## Why init does not run sync itself

  A fresh pack has no generated adapters, so `validate` straight after `init`
  warns once for each of them, 67 warnings for the starter. `sync` writes them,
  and is safe to run in the sense that what it writes is generated. But init
  writes `.agents/` and nothing else, and sync does not stay there:
  - `GEMINI.md` and `.cursor/rules/harness.mdc` are written whole, over a file
    of the same name a person already has;
  - `.gemini/settings.json` and `.cursor/mcp.json` keep the other keys but are
    re-serialised, sorted;
  - `CLAUDE.md` and `.codex/config.toml` get a marked block, and the rest is
    left alone;
  - `.claude/agents/` gets a file per nucleus role.

  So a repository's own `GEMINI.md` would be lost to an init, which is the one
  thing init promises not to do. Sync is the first command `Next:` prints
  instead, with what it writes, and the person runs it.
  """
  @shortdoc "Write the starter pack into a repository"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever
  # beams the last compile left, and answers for code that is not on disk.
  @requirements ["compile"]

  alias Noetic.Harness.Starter

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [path: :string, with: :keep, force: :boolean])

    shell = Mix.shell()
    caller = System.get_env("NOETIC_HARNESS_CALLER_DIR") || File.cwd!()
    target = Path.expand(opts[:path] || ".", caller)
    addons = Keyword.get_values(opts, :with)

    case Starter.install(target, with: addons, force: Keyword.get(opts, :force, false)) do
      {:ok, %{written: written, replaced: replaced}} ->
        shell.info(
          "wrote #{length(written)} file(s) into #{Path.join(target, ".agents")}" <>
            pack_label(addons) <> replaced_label(replaced)
        )

        unless File.dir?(Path.join(target, ".git")) do
          shell.info(
            "note: #{target} is not a git repository; the gates and the run ledger read git"
          )
        end

        shell.info("")
        Enum.each(next_steps(target), &shell.info/1)

      {:error, {:exists, present}} ->
        shell.error(
          "#{Path.join(target, ".agents")} already exists, and nothing was written. " <>
            "`--force` would replace these #{length(present)} file(s) and touch nothing else:"
        )

        Enum.each(present, &shell.error("  #{&1}"))
        exit({:shutdown, 1})

      {:error, message} ->
        shell.error(message)
        exit({:shutdown, 1})
    end
  end

  defp pack_label([]), do: " (the starter pack)"
  defp pack_label(addons), do: " (the starter pack, with #{Enum.join(addons, ", ")})"

  defp replaced_label([]), do: ""
  defp replaced_label(replaced), do: "; #{length(replaced)} of them replaced a file"

  @doc false
  # The harness reads the repository it is pointed at. From a checkout of the
  # harness that is `NOETIC_HARNESS_ROOT`, unless the target is where it would
  # look anyway.
  def next_steps(target) do
    prefix =
      if Path.expand(target) == Path.expand(Noetic.Harness.root()),
        do: "",
        else: "NOETIC_HARNESS_ROOT=#{target} "

    [
      "Next:",
      "  #{prefix}noetic-harness sync",
      "  #{prefix}noetic-harness route --title \"<what you are about to do>\" --explain",
      "  #{prefix}noetic-harness gates --lane fast --plan",
      "  #{prefix}noetic-harness run --start WF-002 --title \"<what you are about to do>\"",
      "",
      "sync generates the adapters, and until it runs validate warns about each one.",
      "It writes .agents/prompts, .agents/AGENTS_INDEX.md, .claude/agents, GEMINI.md",
      "and .cursor/rules/harness.mdc whole. It adds its own block to CLAUDE.md and",
      ".codex/config.toml, and its own key to .gemini/settings.json and .cursor/mcp.json,",
      "which it writes back with their keys sorted. Look first if you keep any of these by hand.",
      "",
      "The gates run your format, lint, build and test commands, from the bin",
      "directory in .agents. Until you write them for your language they report",
      "unavailable; the README there says how."
    ]
  end
end
