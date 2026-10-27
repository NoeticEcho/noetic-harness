defmodule Noetic.Harness.Adapters.Instructions do
  @moduledoc """
  The harness's loop, generated into whatever file Codex, Gemini and Cursor
  read.

  Claude Code reaches the harness through hooks, a skill and slash commands.
  Codex, Gemini and Cursor reach it through nothing unless something tells
  them, and a hand-written summary of `noetic-harness` goes stale and then lies.
  So the summary is rendered from `.agents/templates/instructions/harness.md`
  with the tool names taken from `.agents/policies/mcp.json`, and
  `noetic-harness sync --check` fails on a hand edit exactly as it does for the
  other generated files.

  **It is short on purpose.** One copy lands in `CLAUDE.md`, which every
  Claude session reads in full on every request — the same size argument that
  keeps `usage_rules`' output out of it (`mix.exs`). The first version carried
  a tool table and a workflow table, about ninety lines; an MCP client already
  gets both from `tools/list` and `harness_workflows`, so they were weight
  without information.

  ## Who reads what

  | Agent | Reads | What is generated there |
  |---|---|---|
  | Codex | `AGENTS.md`, which is a symlink to `CLAUDE.md` | A marked block at the end of `CLAUDE.md`. The rest of the file stays hand-written. |
  | Codex | `.codex/config.toml` | A marked `[mcp_servers.noetic-harness]` block |
  | Gemini | `GEMINI.md` | The whole file, pointing at `CLAUDE.md` for the rest |
  | Gemini | `.gemini/settings.json` | `mcpServers["noetic-harness"]`, other keys kept |
  | Cursor | `.cursor/rules/harness.mdc` | The whole file, `alwaysApply: true` |
  | Cursor | `.cursor/mcp.json` | `mcpServers["noetic-harness"]`, other keys kept |

  **Three of these files are shared, and only our part is ours.** `CLAUDE.md`
  is hand-written, `.codex/config.toml` already carries beads' settings, and a
  person may add their own MCP servers to the JSON files. So those are
  *spliced*: a block between markers, or one key in a JSON object, is replaced
  and nothing else is touched. What "expected" means for a spliced file is the
  current file with our part put right, so the same drift comparison works for
  both kinds.

  The JSON files are re-serialised through `Noetic.Harness.Loader.pretty!/1`,
  which sorts keys. A hand-formatted file therefore drifts once, on the first
  sync, and is stable after; that is the price of not writing a JSON merger.

  ## How the server is started

  Every client is told to run `bash -c 'cd "$(git rev-parse
  --show-toplevel)" && exec noetic-harness mcp'` rather than the command alone. None of the
  three promises which directory it spawns a server from, and `git rev-parse`
  answers from wherever it is — including from inside a worktree, where it
  names the worktree and not the main checkout.
  """

  alias Noetic.Harness.{Loader, MCP}

  @begin_md "<!-- BEGIN NOETIC HARNESS INSTRUCTIONS"
  @end_md "<!-- END NOETIC HARNESS INSTRUCTIONS -->"
  @begin_toml "# BEGIN noetic-harness"
  @end_toml "# END noetic-harness"

  @server "noetic-harness"
  @command "bash"
  @args ["-c", ~s|cd "$(git rev-parse --show-toplevel)" && exec noetic-harness mcp|]

  @doc """
  Every file this adapter owns or splices into, as `path => expected content`.
  """
  @spec expected() :: %{Path.t() => String.t()}
  def expected do
    body = render()

    %{
      path("GEMINI.md") => gemini(body),
      path(".cursor/rules/harness.mdc") => cursor(body),
      path("CLAUDE.md") => splice_md(read(path("CLAUDE.md")), body),
      path(".codex/config.toml") => splice_toml(read(path(".codex/config.toml"))),
      path(".gemini/settings.json") =>
        splice_json(read(path(".gemini/settings.json")), gemini_server()),
      path(".cursor/mcp.json") => splice_json(read(path(".cursor/mcp.json")), plain_server())
    }
  end

  @doc "The template, rendered."
  @spec render() :: String.t()
  def render do
    template = File.read!(Noetic.Harness.agents_path("templates/instructions/harness.md"))

    template
    |> String.replace("{{mcp_tools}}", mcp_tools())
  end

  defp mcp_tools do
    {:ok, manifest} = MCP.manifest()
    Enum.map_join(manifest["tools"], ", ", &"`#{&1["name"]}`")
  end

  # ---- whole files ---------------------------------------------------------

  defp gemini(body) do
    """
    #{banner("<!--", "-->")}
    # #{Noetic.Harness.Project.name() || "This project"} — for Gemini

    The project's instructions are `CLAUDE.md` (also reachable as `AGENTS.md`).
    Read it before anything else; it applies to you in full. What follows is the
    part of it written for an agent that is not Claude Code.

    #{body}\
    """
  end

  defp cursor(body) do
    """
    ---
    description: How this repository develops itself — the harness, over MCP and in a shell
    alwaysApply: true
    ---

    #{banner("<!--", "-->")}
    #{body}\
    """
  end

  # ---- spliced files -------------------------------------------------------

  defp splice_md(current, body) do
    block = "#{@begin_md} — #{banner_text()} -->\n#{body}#{@end_md}\n"
    splice(current, @begin_md, @end_md, block)
  end

  defp splice_toml(current) do
    block = """
    #{@begin_toml} — #{banner_text()}
    [mcp_servers.#{@server}]
    command = "#{@command}"
    args = [#{Enum.map_join(@args, ", ", &toml_string/1)}]
    startup_timeout_sec = 60
    #{@end_toml}
    """

    splice(current, @begin_toml, @end_toml, block)
  end

  # A block between markers is replaced; a file without one gets it appended,
  # after a blank line; a missing file is just the block.
  defp splice(current, begin_marker, end_marker, block) do
    case current do
      nil ->
        block

      text ->
        case String.split(text, begin_marker, parts: 2) do
          [before, rest] ->
            after_block =
              case String.split(rest, end_marker, parts: 2) do
                [_old, tail] -> String.replace_prefix(tail, "\n", "")
                [_unterminated] -> ""
              end

            before <> block <> after_block

          [_no_marker] ->
            String.trim_trailing(text) <> "\n\n" <> block
        end
    end
  end

  # A file that does not parse is left exactly as it is. Replacing it with our
  # one key would be a sync that silently deletes somebody's configuration, and
  # a person who broke their own JSON is better told by their client.
  defp splice_json(nil, server), do: splice_json("{}", server)

  defp splice_json(current, server) do
    case JSON.decode(current) do
      {:ok, %{} = existing} ->
        servers = Map.get(existing, "mcpServers", %{})
        Loader.pretty!(Map.put(existing, "mcpServers", Map.put(servers, @server, server)))

      _ ->
        current
    end
  end

  defp plain_server, do: %{"command" => @command, "args" => @args}

  # Gemini's per-request timeout is in milliseconds. A route or a context can
  # wait on `bd`, which has its own ten-second bound; two minutes is the
  # server's own ceiling on a tool call.
  defp gemini_server, do: Map.put(plain_server(), "timeout", 120_000)

  # ---- helpers -------------------------------------------------------------

  defp banner(open, close), do: "#{open} GENERATED — #{banner_text()} #{close}"

  defp banner_text do
    "by `noetic-harness sync` from `.agents/templates/instructions/harness.md` and " <>
      "`.agents/policies/mcp.json`. Do not edit: the next sync reverts it."
  end

  defp toml_string(value), do: JSON.encode!(value)

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp path(relative), do: Path.join(Noetic.Harness.root(), relative)
end
