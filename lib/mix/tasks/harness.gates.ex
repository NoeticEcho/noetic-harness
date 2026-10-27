defmodule Mix.Tasks.Harness.Gates do
  @moduledoc """
  Gate lanes: what would run, what runs, and what cannot.

      noetic-harness gates                          the lanes
      noetic-harness gates --lane focused --plan    what would run against the current change
      noetic-harness gates --lane focused           run it
      noetic-harness gates --lane full --paths a,b  run it against specific paths

  Every gate reports `passed`, `failed`, `skipped` or `unavailable`. A lane with
  an unavailable blocking gate reports **partial**, never passed: the work it
  guarded is unverified, and saying otherwise is the single most damaging thing
  this tool could do.
  """
  @shortdoc "Plan or run a gate lane"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]
  alias Noetic.Harness.{Gates, Git, Policy}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [lane: :string, plan: :boolean, paths: :string, only: :string]
      )

    shell = Mix.shell()

    case opts[:lane] do
      nil -> catalogue(shell)
      lane -> execute(shell, lane, opts)
    end
  end

  defp catalogue(shell) do
    {:ok, doc} = Policy.gates()

    Enum.each(doc["lanes"], fn lane ->
      {:ok, expanded} = Gates.expand(lane["id"])
      shell.info("#{String.pad_trailing(lane["id"], 11)} #{length(expanded)} gates")
      shell.info("            #{lane["doc"]}")
      shell.info("            #{Enum.join(expanded, ", ")}")
      shell.info("")
    end)
  end

  defp execute(shell, lane, opts) do
    paths =
      case opts[:paths] do
        nil ->
          case Git.changed_paths() do
            {:ok, paths} ->
              shell.info("(#{length(paths)} changed path(s) from git)")
              paths

            :error ->
              shell.info("(git said nothing; every gate with a path filter will therefore run)")
              []
          end

        given ->
          String.split(given, [",", " "], trim: true)
      end

    only = if opts[:only], do: String.split(opts[:only], [",", " "], trim: true)

    case Gates.run(lane, paths: paths, dry_run: !!opts[:plan], only: only) do
      {:error, message} ->
        Mix.raise(message)

      {:ok, {status, results}} ->
        shell.info("")
        shell.info(Gates.summarise(lane, {status, results}))

        unless opts[:plan] do
          case status do
            :passed -> :ok
            :partial -> exit({:shutdown, 2})
            :failed -> exit({:shutdown, 1})
          end
        end
    end
  end
end
