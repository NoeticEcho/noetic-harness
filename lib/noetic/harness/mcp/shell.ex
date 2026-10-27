defmodule Noetic.Harness.MCP.Shell do
  @moduledoc """
  Mix's shell, for a task run as an MCP tool.

  `Mix.Shell.IO` writes errors to stderr, so a task's refusal — the part a
  caller most needs — would reach the server's log and not the caller. This
  writes both to the group leader, which `Noetic.Harness.MCP` has made a
  `StringIO` for the length of the call.

  It never prompts. stdin is the protocol stream: a task that asked a question
  would read the client's next message as its answer.
  """

  @behaviour Mix.Shell

  @impl true
  def print_app, do: :ok

  @impl true
  def info(message), do: IO.puts(IO.ANSI.format(message, false))

  @impl true
  def error(message), do: IO.puts(IO.ANSI.format(message, false))

  @impl true
  def prompt(_message), do: ""

  @impl true
  def yes?(_message), do: false

  @impl true
  def yes?(_message, _options), do: false

  @impl true
  def cmd(command), do: cmd(command, [])

  @impl true
  def cmd(command, options), do: Mix.Shell.cmd(command, options, &IO.write/1)
end
