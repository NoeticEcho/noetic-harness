defmodule Noetic.Harness.CLI do
  @moduledoc """
  `noetic-harness <subcommand> [args...]`: the single executable's entry point.

  `noetic-harness <subcommand>` runs `mix harness.<subcommand>`, and so does the
  README's `noetic-harness` script. This is the same dispatch without mix:
  `argv`'s first word names a task module, `Mix.Tasks.Harness.<Subcommand>`,
  and the rest is that task's arguments, untouched. There is no second
  implementation of any command. A command is a task module, and the table
  of them is read from the application's own module list, so a task added to
  `lib/mix/tasks/` is a subcommand here with nothing else to change.

  ## Why the tasks are called directly

  `Mix.Task.run/2` would first run each task's `@requirements`, and every
  harness task requires `compile`, so that it cannot answer from stale beams.
  In a release there is no source and nothing to compile: the beams are the
  release. So the task's `run/1` is called directly, and what `Mix.Task.run/2`
  would add is done here:

  - `:mix` is started, because the tasks print through `Mix.shell/0`, whose
    state lives in a process the `:mix` application starts. The release
    carries `:mix` loaded and not started, for this.
  - `exit({:shutdown, n})`, the tasks' way of failing, is exit status `n`.
  - `Mix.Error`, from `Mix.raise/1`, is `** (Mix) <message>` on standard
    error and status 1, as mix prints it. Any other exception is printed
    with its stacktrace, and is status 1 too.

  ## Only in the executable

  The release names this module as the application's callback, so that the
  executable has something to run. `start/2` runs a command only when Burrito
  started the VM (`__BURRITO` in the environment, which Burrito's launcher
  sets). Anywhere else, a `MIX_ENV=prod` checkout say, the application starts
  an empty supervisor and nothing else: the harness is a library its mix tasks
  read, and loading it must not run a command.

  Its standard output is set to Unicode first. The harness prints `—` and
  `·`, and a VM started without a UTF-8 locale writes each as an escape.
  Colour is on only when standard output is a terminal, as mix decides it: a
  release otherwise writes ANSI codes into a pipe.
  """

  use Application

  @usage """
  noetic-harness <subcommand> [args...]

  The same commands as `mix harness.<subcommand>`, in one executable. Run it
  in the repository you are developing; it finds the nearest `.agents/` above
  the current directory.

  Subcommands:
  """

  @doc false
  @impl Application
  def start(_type, _args) do
    if System.get_env("__BURRITO") do
      :io.setopts(:standard_io, encoding: :unicode)
      :io.setopts(:standard_error, encoding: :unicode)
      Application.put_env(:elixir, :ansi_enabled, terminal?())

      :init.get_plain_arguments()
      |> Enum.map(&List.to_string/1)
      |> main()
      |> System.halt()
    else
      Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
    end
  end

  # `:io.columns/1` answers only for a terminal: colour for a person, none for
  # a pipe or a file.
  defp terminal?, do: match?({:ok, _}, :io.columns(:standard_io))

  @doc """
  Runs `argv` as a command and returns its exit status. Nothing is halted:
  the caller decides what the status means.
  """
  @spec main([String.t()]) :: non_neg_integer()
  def main(argv) do
    {:ok, _} = Application.ensure_all_started(:mix)

    case argv do
      [] -> usage(0)
      [flag] when flag in ["help", "--help", "-h"] -> usage(0)
      [flag] when flag in ["--version", "-v"] -> version()
      [subcommand | args] -> dispatch(subcommand, args)
    end
  end

  @doc """
  The subcommands this build has, each with the task module that runs it.
  """
  @spec commands() :: %{String.t() => module()}
  def commands do
    for module <- Application.spec(:noetic_harness, :modules) || [],
        "harness." <> name <- [task_name(module)],
        into: %{},
        do: {name, module}
  end

  defp task_name(module) do
    case Module.split(module) do
      ["Mix", "Tasks" | _] -> Mix.Task.task_name(module)
      _ -> nil
    end
  end

  defp dispatch(subcommand, args) do
    case Map.fetch(commands(), subcommand) do
      {:ok, module} ->
        run(module, args)

      :error ->
        IO.puts(:stderr, "noetic-harness: no subcommand #{inspect(subcommand)}.\n")
        usage(1)
    end
  end

  defp run(module, args) do
    module.run(args)
    0
  rescue
    error in Mix.Error ->
      IO.puts(:stderr, "** (Mix) " <> Exception.message(error))
      1

    error ->
      IO.puts(:stderr, Exception.format(:error, error, __STACKTRACE__))
      1
  catch
    :exit, {:shutdown, status} when is_integer(status) -> status
    :exit, :shutdown -> 0
  end

  defp usage(status) do
    lines =
      commands()
      |> Enum.sort()
      |> Enum.map(fn {name, module} ->
        case Mix.Task.shortdoc(module) do
          nil -> "  " <> name
          shortdoc -> "  " <> String.pad_trailing(name, 14) <> shortdoc
        end
      end)

    device = if status == 0, do: :stdio, else: :stderr
    IO.puts(device, @usage <> Enum.join(lines, "\n"))
    status
  end

  defp version do
    IO.puts("noetic-harness " <> to_string(Application.spec(:noetic_harness, :vsn)))
    0
  end
end
