defmodule Noetic.Harness.Adapters do
  @moduledoc """
  Generating the client-specific files from the canonical definitions.

  ## One source, several dialects

  Claude Code reads `.claude/agents/*.md` with its own front matter. Codex reads
  `AGENTS.md` and `.agents/`. They want different files; they must not want
  different *contracts*. So every adapter is derived from the same registry,
  the same constitution, the same templates — and every generated file carries a
  banner naming the command that produced it.

  **Editing a generated file is a defect**, not a shortcut: the next
  `noetic-harness sync` reverts it silently, which is the worst possible way to
  lose a change. `drift/1` exists so that the validator notices an edited or
  stale adapter and says so instead.

  ## What is generated where

  | Output | Contents | Why that scope |
  |---|---|---|
  | `.agents/prompts/<id>.md` | All 270 standing prompts | The deliverable: every registered role has a written, inspectable prompt. |
  | `.claude/agents/<id>.md` | The 28 nucleus roles | Claude Code loads every agent's description into context. 270 would drown the session; the nucleus is the set workflows actually route to. |
  | `.agents/AGENTS_INDEX.md` | The whole registry, one line each | How a human or Codex finds the other 242 without loading them. |
  | `GEMINI.md`, `.cursor/rules/harness.mdc`, a block in `CLAUDE.md`, the MCP entries in `.codex/`, `.gemini/`, `.cursor/` | The harness's loop and its MCP server, for Codex, Gemini and Cursor | `Noetic.Harness.Adapters.Instructions`. The agents the user said are used or planned here, and no others. |

  **Development roles only**. A runtime role is a product's AI
  employee, not a coding client's subagent: `sync` writes no prompt, no
  `.claude/agents/` file and no index row for one, whatever its `nucleus`
  says, and the index says how many it left out. Its door is `harness export`.

  The standing prompts reference the constitution rather than inlining it —
  otherwise every one of 270 files carries the same six kilobytes, and a change
  to one paragraph produces a 1.6MB diff. `Noetic.Harness.Prompt.compose/2`
  inlines it at runtime, which is where it is actually needed.
  """

  alias Noetic.Harness.{Prompt, Registry}
  alias Noetic.Harness.Adapters.Instructions

  @banner_marker "<!-- GENERATED"

  @doc """
  Write every adapter. Returns the paths written.

  Options: `:only` — `:prompts`, `:claude`, `:index` or `:instructions`.
  """
  @spec sync(Registry.t(), keyword()) :: {:ok, [Path.t()]} | {:error, String.t()}
  def sync(registry, opts \\ []) do
    only = Keyword.get(opts, :only)

    targets =
      [
        {:prompts, &write_prompts/1},
        {:claude, &write_claude/1},
        {:index, &write_index/1},
        {:instructions, fn _registry -> write_all(Instructions.expected()) end}
      ]
      |> Enum.filter(fn {name, _fun} -> is_nil(only) or only == name end)

    Enum.reduce_while(targets, {:ok, []}, fn {_name, fun}, {:ok, acc} ->
      case fun.(registry) do
        {:ok, paths} -> {:cont, {:ok, acc ++ paths}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  @doc """
  Generated files whose content differs from what the definitions produce now.

  This is how a stale or hand-edited adapter is caught. It compares content
  rather than timestamps, because a `touch` is not a change and a revert is.

  Options: `:only`, the same four names `sync/2` takes. Without it, every
  adapter, which is what the validator asks. With `only: :instructions` it
  composes none of the 270 standing prompts, which are most of the cost: a test
  about `GEMINI.md` has no reason to wait on them.

  ## What it reads, and why that is counted

  Each expected file once, and a file on disk that nothing expects once more,
  to see whether it carries the banner. It used to read every file in the two
  directories for the banner *before* dropping the ones it expected, which read
  all ~300 of them twice for an answer about the zero or one that are
  orphaned.

  The reads are `:raw`. A plain `File.read/1` is a call to OTP's one file
  server process, `file_server_2`, and under load that call is what costs:
  `ValidationTest` and `Adapters.InstructionsTest` timed out at 60 s on a
  loaded two-core workstation, and a probe in the suite measured a file-server
  round trip at ~60 ms median with four callers queued, against ~0.05 ms idle.
  A raw read is made by the calling process and queues behind nobody.
  """
  @spec drift(Registry.t(), keyword()) :: [String.t()]
  def drift(registry, opts \\ []) do
    only = Keyword.get(opts, :only)

    expected =
      [
        prompts: fn -> expected_prompts(registry) end,
        claude: fn -> expected_claude(registry) end,
        index: fn -> expected_index(registry) end,
        instructions: &Instructions.expected/0
      ]
      |> Enum.filter(fn {name, _fun} -> is_nil(only) or only == name end)
      |> Enum.reduce(%{}, fn {_name, fun}, acc -> Map.merge(acc, fun.()) end)

    stale =
      for {path, content} <- expected,
          read(path) != {:ok, content},
          do: relative(path)

    orphaned =
      [prompts: prompts_dir(), claude: claude_dir()]
      |> Enum.filter(fn {name, _dir} -> is_nil(only) or only == name end)
      |> Enum.map(fn {_name, dir} -> dir end)
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.md")))
      |> Enum.reject(&Map.has_key?(expected, &1))
      |> Enum.filter(&generated?/1)
      |> Enum.map(&"#{relative(&1)} (generated, but nothing produces it any more)")

    Enum.sort(stale ++ orphaned)
  end

  # ---- prompts -------------------------------------------------------------

  defp write_prompts(registry), do: write_all(expected_prompts(registry))

  defp expected_prompts(registry) do
    Map.new(Registry.on_plane(registry, "development"), fn agent ->
      {Path.join(prompts_dir(), "#{agent["id"]}.md"), prompt_file(agent)}
    end)
  end

  defp prompt_file(agent) do
    body =
      case Prompt.compose(agent["id"]) do
        {:ok, prompt} -> strip_constitution(prompt)
        {:error, message} -> "**This role cannot currently compose a prompt: #{message}**\n"
      end

    """
    #{banner("noetic-harness sync")}
    # #{agent["name"]} — `#{agent["id"]}`

    > The **Agent Constitution** (`.agents/constitution.md`) is the first section of
    > this prompt at runtime and is omitted here so that a change to one paragraph
    > does not rewrite 270 files. `noetic-harness prompt #{agent["id"]}` renders the
    > whole thing, constitution included, which is what an agent actually receives.

    #{body}
    """
  end

  # ---- Claude Code ---------------------------------------------------------

  defp write_claude(registry), do: write_all(expected_claude(registry))

  defp expected_claude(registry) do
    registry
    |> Registry.nucleus()
    |> Map.new(fn agent ->
      {Path.join(claude_dir(), "#{agent["id"]}.md"), claude_file(agent, registry)}
    end)
  end

  defp claude_file(agent, registry) do
    body =
      case Prompt.compose(agent["id"]) do
        {:ok, prompt} -> strip_constitution(prompt)
        {:error, message} -> "**This role cannot currently compose a prompt: #{message}**"
      end

    """
    ---
    name: #{agent["id"]}
    description: #{description(agent, registry)}
    ---

    #{banner("noetic-harness sync")}
    Read `.agents/constitution.md` first. It binds this role and nothing in this
    file overrides it.

    #{body}
    """
  end

  # Claude Code matches on this line, so it has to say what the role is *for*
  # rather than what it is called. The capability list is the useful part: it is
  # what the router would have matched on anyway.
  defp description(agent, registry) do
    domain = Map.get(registry.domains, agent["domain"], %{})

    [
      agent["name"],
      "—",
      "#{Map.get(domain, "summary", agent["domain"])}",
      "Use for:",
      Enum.join(agent["capabilities"], ", ") <> "."
    ]
    |> Enum.join(" ")
    |> String.replace("\n", " ")
    |> String.slice(0, 480)
  end

  # ---- index ---------------------------------------------------------------

  defp write_index(registry), do: write_all(expected_index(registry))

  defp expected_index(registry) do
    %{Path.join(Noetic.Harness.agents_path(), "AGENTS_INDEX.md") => index_file(registry)}
  end

  defp index_file(registry) do
    roles = Registry.on_plane(registry, "development")
    by_domain = Enum.group_by(roles, & &1["domain"])

    # A domain only runtime roles live in is not a development one.
    runtime_only =
      registry
      |> Registry.on_plane("runtime")
      |> MapSet.new(& &1["domain"])
      |> MapSet.difference(MapSet.new(Map.keys(by_domain)))

    domains =
      registry.domains
      |> Map.values()
      |> Enum.reject(&MapSet.member?(runtime_only, &1["id"]))
      |> Enum.sort_by(& &1["id"])

    sections =
      domains
      |> Enum.map_join("\n\n", fn domain ->
        agents = Map.get(by_domain, domain["id"], [])

        rows =
          Enum.map_join(agents, "\n", fn agent ->
            marks =
              [
                if(agent["nucleus"], do: "nucleus"),
                if(agent["status"] == "dormant", do: "dormant"),
                if("high_risk" in (agent["tags"] || []), do: "high-risk")
              ]
              |> Enum.reject(&is_nil/1)
              |> Enum.join(", ")

            "| `#{agent["id"]}` | #{agent["name"]} | #{agent["archetype"]} | #{agent["max_trust"]} | #{marks} |"
          end)

        """
        ## #{domain["id"]} — #{domain["summary"]}

        Owns: #{Enum.map_join(domain["owns"] || [], ", ", &"`#{&1}`") |> blank_to("nothing in the repository directly")}

        | id | role | archetype | max trust | |
        |---|---|---|---|---|
        #{rows}
        """
      end)

    """
    #{banner("noetic-harness sync")}
    # Agent index

    #{length(roles)} registered roles across #{length(domains)} domains.#{runtime_note(registry)}
    **This is a competency library, not a process list.** A workflow assembles a
    temporary team of three to five of these for one task; a task that appears to
    need eight has been described badly.

    Adapters are generated for the #{length(Registry.nucleus(registry))} nucleus roles,
    which is the set the workflows actually route to. Every other role composes on
    demand:

    ```bash
    noetic-harness agents --domain <domain>      # what exists
    noetic-harness agents --explain <id>         # why it has the capabilities it has
    noetic-harness prompt <id>                   # its full prompt, constitution included
    ```

    #{sections}
    """
  end

  # Said only when there is something to say, so a registry with no runtime
  # role writes the index it always did.
  defp runtime_note(registry) do
    case length(Registry.on_plane(registry, "runtime")) do
      0 ->
        ""

      count ->
        "\n#{count} runtime roles are not listed: they are a product's AI employees, " <>
          "and `harness export` is their door."
    end
  end

  # ---- writing -------------------------------------------------------------

  defp write_all(files) do
    paths =
      Enum.map(files, fn {path, content} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
        path
      end)

    {:ok, Enum.sort(paths)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp banner(command) do
    "#{@banner_marker} by `#{command}` from `.agents/registry/` and `.agents/templates/`. " <>
      "Do not edit: the next sync reverts it. Change the canonical definitions instead. -->\n"
  end

  defp generated?(path) do
    case read(path) do
      {:ok, content} -> String.contains?(content, @banner_marker)
      _ -> false
    end
  end

  # The constitution is prepended by `Prompt.compose/2` and separated from the
  # rest by a horizontal rule. Splitting on that rule is how the generated files
  # keep the role-specific part without re-deriving it.
  defp strip_constitution(prompt) do
    case String.split(prompt, "\n\n---\n\n", parts: 2) do
      [_constitution, body] -> body
      [whole] -> whole
    end
  end

  defp read(path), do: File.read(path, [:raw])

  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value

  defp prompts_dir, do: Noetic.Harness.agents_path("prompts")
  defp claude_dir, do: Path.join(Noetic.Harness.root(), ".claude/agents")
  defp relative(path), do: Path.relative_to(path, Noetic.Harness.root())
end
