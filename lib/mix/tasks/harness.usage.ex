defmodule Mix.Tasks.Harness.Usage do
  @shortdoc "What a session cost, and optionally record it against the run"

  @moduledoc """
  Read a Claude Code transcript and count what the session spent.

      noetic-harness usage                          # the newest transcript for this repository
      noetic-harness usage --transcript <path>
      noetic-harness usage --record                 # write it to the current run
      noetic-harness usage --record --run <id>
      noetic-harness usage --json

  **Read-only unless you say `--record`.** The harness's other commands that
  write — `run --step`, `memory --add` — are each explicit about it, and this
  one is the same: printing a number is safe and appending to the ledger is a
  claim.

  ## What it counts, and what it refuses to read

  Counts only: the four token counters, thinking tokens, messages, models and
  tool names. `Noetic.Harness.Usage` never reads message text, tool arguments
  or tool results — a transcript records everything a person said and
  everything their files contained, and the ledger is committed to git.

  ## Finding the transcript

  `--transcript` is the reliable way. The `SessionEnd` hook does not use this
  task at all — it calls `Noetic.Harness.Usage.record/1` with the
  `transcript_path` its payload carries — so this option is how a person does
  by hand what the hook is handed. Without it the newest `*.jsonl` under
  `~/.claude/projects/<slug>` is used, where `<slug>` is this repository's
  path with `/` and `.` replaced by `-`. That convention is **inferred from
  one machine's layout and is not documented anywhere**, so the command says
  which file it picked rather than reporting a number from a file nobody
  named, and refuses instead of guessing when the directory is absent.
  """

  use Mix.Task

  alias Noetic.Harness.{Run, Usage}

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [transcript: :string, record: :boolean, run: :string, json: :boolean]
      )

    shell = Mix.shell()

    with {:ok, path} <- transcript(opts),
         {:ok, summary} <- Usage.read(path) do
      report(shell, summary, path, opts)
    else
      {:error, message} ->
        shell.error(message)
        exit({:shutdown, 1})
    end
  end

  defp report(shell, summary, path, opts) do
    if opts[:json] do
      shell.info(Noetic.Harness.Loader.pretty!(summary))
    else
      print(shell, summary, path)
    end

    if opts[:record], do: record(shell, summary, opts)
  end

  defp record(shell, summary, opts) do
    case run_id(opts) do
      {:ok, id} ->
        case Run.observe(id, summary) do
          {:ok, _} ->
            shell.info("")
            shell.info("recorded against #{id}")

          {:error, message} ->
            shell.error(message)
            exit({:shutdown, 1})
        end

      {:error, message} ->
        shell.error(message)
        exit({:shutdown, 1})
    end
  end

  # No run, no recording. `Usage.session_run/1` refuses when two are open
  # rather than picking the newest, for the reason an earlier change records: more
  # than one session can share this working directory, and "newest wins"
  # writes one session's evidence into another's ledger. It also refuses a run
  # that is another epic's, which is what the SessionEnd hook
  # asks, so `--record` by hand and the hook cannot pick two different runs.
  defp run_id(opts) do
    case opts[:run] do
      id when is_binary(id) ->
        {:ok, id}

      _ ->
        case Usage.session_run() do
          {:ok, id} -> {:ok, id}
          {:many, message} -> {:error, message}
          {:foreign, message} -> {:error, message}
          :none -> {:error, no_run()}
        end
    end
  end

  defp no_run do
    "no open run to record this against. `noetic-harness run --start <WF-0xx> --title ...` " <>
      "opens one, or name it with --run"
  end

  defp print(shell, summary, path) do
    shell.info("session #{summary["transcript"]}")
    shell.info("  #{path}")
    shell.info("")
    shell.info("  #{pad("messages")}#{number(summary["messages"])}")

    for key <- Usage.counters() do
      shell.info("  #{pad(key)}#{number(summary["tokens"][key])}")
    end

    shell.info("  #{pad("thinking_tokens")}#{number(summary["thinking_tokens"])}")

    if summary["unreadable"] > 0 do
      shell.info("  #{pad("unreadable lines")}#{number(summary["unreadable"])}")
    end

    top(shell, "models", summary["models"])
    top(shell, "tools", summary["tools"])
  end

  defp top(_shell, _label, empty) when empty == %{}, do: :ok

  defp top(shell, label, counts) do
    shell.info("")
    shell.info("  #{label}")

    counts
    |> Enum.sort_by(fn {_k, v} -> -v end)
    |> Enum.take(8)
    |> Enum.each(fn {key, value} -> shell.info("    #{pad(key, 32)}#{number(value)}") end)
  end

  defp pad(text, width \\ 30), do: String.pad_trailing(text, width)

  # Grouped, because a nine-digit token count read without separators is a
  # number nobody checks.
  defp number(nil), do: "—"

  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1 ")
    |> String.reverse()
  end

  defp number(other), do: to_string(other)

  defp transcript(opts) do
    case opts[:transcript] do
      nil -> newest()
      # Against the directory the person ran `noetic-harness` from, which is not
      # this process's: `noetic-harness` runs mix from `apps/noetic_harness`.
      path -> {:ok, Path.expand(path, System.get_env("NOETIC_HARNESS_CALLER_DIR") || File.cwd!())}
    end
  end

  defp newest do
    dir = project_dir()

    case Path.wildcard(Path.join(dir, "*.jsonl")) do
      [] ->
        {:error,
         "no transcript under #{dir}. The directory name is inferred from this repository's " <>
           "path and is not a documented convention, so pass --transcript <path> rather than " <>
           "trusting this to have guessed right"}

      files ->
        {:ok, Enum.max_by(files, &File.stat!(&1).mtime)}
    end
  end

  defp project_dir do
    slug = Noetic.Harness.root() |> String.replace(~r{[/.]}, "-")
    Path.join([System.user_home!(), ".claude", "projects", slug])
  end
end
