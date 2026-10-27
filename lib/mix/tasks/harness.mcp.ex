defmodule Mix.Tasks.Harness.Mcp do
  @shortdoc "Serve the harness read-only over MCP, on stdin and stdout"

  @moduledoc """
  The harness as an MCP server, for an agent that is not Claude Code.

      noetic-harness mcp

  An MCP client starts this command and speaks JSON-RPC to it, one message a
  line, on stdin and stdout, until it closes stdin. The tools are the
  read-only harness tasks `.agents/policies/mcp.json` lists, and
  `Noetic.Harness.MCP` holds the allow-list they must stay inside: nothing
  over MCP records, dispatches or verifies. `noetic-harness sync` writes the
  configuration that tells Codex, Gemini and Cursor to start it.

  Standard output is the protocol, so everything else goes to standard error:
  the logger is moved there before the first message is read.

  ## From a checkout

  Under `mix`, this task compiles first, and a compile that has work to do
  prints to standard output before the server starts. A client reads that as
  a broken message. In the single executable nothing is compiled. From a
  checkout, compile before a client starts the server, or start it the way the
  development repository's own script does: off the compiled beams, with the
  compile's output on standard error.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run([]), do: Noetic.Harness.MCP.serve()

  def run(_args),
    do: Mix.raise("mcp takes no arguments: an MCP client starts it and talks on stdin")
end
