defmodule Mix.Tasks.Harness.Workspace do
  @shortdoc "Dispatched runs' worktrees, and the branches a killed run left behind"

  @moduledoc """
  What the dispatcher has checked out, and what it left behind.

      noetic-harness workspace              # worktrees, and the orphaned branches
      noetic-harness workspace --prune      # remove the orphans, and only them

  A dispatched run's branch outlives the VM that made it. A run killed before
  its cleanup leaves `harness/run/<id>` behind, and the next run to pick that
  id is refused by `Workspace.open/2` — correctly, a design decision — with a failure
  that reads like a regression in whatever that run was testing.

  **Listing is the default and pruning is asked for.** An orphan is a branch
  with no ledger entry in any worktree and none in the history of any ref
  — or a directory under `.git/noetic-harness/` in the same position
  (`Noetic.Harness.Workspace.orphans/0` says why that and nothing looser), and
  `--prune` removes exactly those. A branch whose run exists — open, finished
  or long since deleted from the tree — is a diff somebody may still need to
  review, and nothing here touches it.
  """

  use Mix.Task

  alias Noetic.Harness.Workspace

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [prune: :boolean])
    shell = Mix.shell()

    case Workspace.orphans() do
      {:error, message} ->
        shell.error(message)
        exit({:shutdown, 1})

      {:ok, orphans} ->
        if opts[:prune], do: prune(shell, orphans), else: report(shell, orphans)
    end
  end

  defp report(shell, orphans) do
    case Workspace.list() do
      {:ok, []} -> shell.info("worktrees: none")
      {:ok, trees} -> shell.info("worktrees (#{length(trees)}):\n" <> bullets(trees))
      {:error, message} -> shell.error(message)
    end

    case orphans do
      [] ->
        shell.info("orphaned runs: none")

      ids ->
        shell.info(
          "orphaned runs (#{length(ids)}) — a branch or a directory, and no ledger entry anywhere:\n" <>
            bullets(ids) <> "\n`noetic-harness workspace --prune` removes them."
        )
    end
  end

  defp prune(shell, []), do: shell.info("orphaned runs: none, so nothing to prune")

  defp prune(shell, orphans) do
    results = Workspace.prune(orphans)

    for {id, result} <- results do
      case result do
        :ok -> shell.info("removed #{id}")
        {:error, message} -> shell.error("kept #{id}: #{message}")
      end
    end

    if Enum.any?(results, &match?({_, {:error, _}}, &1)), do: exit({:shutdown, 1})
  end

  defp bullets(items), do: Enum.map_join(items, "\n", &("  · " <> &1))
end
