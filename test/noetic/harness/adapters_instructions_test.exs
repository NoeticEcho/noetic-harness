defmodule Noetic.Harness.Adapters.InstructionsTest do
  @moduledoc """
  The harness's loop, generated for Codex, Gemini and Cursor.

  Three of the six files are shared with a person or another tool, so most of
  this is about what a sync must leave alone.
  """

  use ExUnit.Case, async: true

  alias Noetic.Harness.Adapters.Instructions

  # A repository root of its own, on the pack (`Noetic.Harness.Pack`), so a
  # sync writes into the fixture and never into this checkout's CLAUDE.md.
  setup do
    root =
      Path.join(System.tmp_dir!(), "harness-instructions-#{System.os_time(:microsecond)}")
      |> Noetic.Harness.Pack.populate(tree: false)

    previous = Noetic.Harness.root_override()
    Noetic.Harness.put_root(root)

    on_exit(fn ->
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp sync! do
    for {path, content} <- Instructions.expected() do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end
  end

  defp read!(root, relative), do: File.read!(Path.join(root, relative))

  test "the rendered loop names every MCP tool, and stays short" do
    body = Instructions.render()
    {:ok, manifest} = Noetic.Harness.MCP.manifest()

    for tool <- manifest["tools"], do: assert(body =~ "`#{tool["name"]}`")
    refute body =~ "{{"

    # A copy lands in CLAUDE.md, which every Claude session reads in full on
    # every request. The first version was ninety lines of tables.
    assert length(String.split(body, "\n")) <= 30
  end

  test "a sync is idempotent: the second one changes nothing", %{root: root} do
    File.write!(Path.join(root, "CLAUDE.md"), "# Project\n\nHand-written.\n")
    sync!()
    first = Instructions.expected()
    sync!()
    assert Instructions.expected() == first

    for {path, content} <- first, do: assert(File.read!(path) == content, path)
    assert read!(root, "CLAUDE.md") =~ "Hand-written."
  end

  test "the CLAUDE.md block replaces itself and nothing around it", %{root: root} do
    File.write!(Path.join(root, "CLAUDE.md"), "# Project\n\nBefore.\n")
    sync!()

    # A person writes below the block, and the block goes stale.
    claude = Path.join(root, "CLAUDE.md")

    File.write!(
      claude,
      String.replace(File.read!(claude), "harness_route", "harness_ROUTE") <> "\nAfter.\n"
    )

    sync!()
    text = File.read!(claude)
    assert text =~ "Before."
    assert text =~ "After."
    assert text =~ "`harness_route`"
    refute text =~ "harness_ROUTE"
    assert length(String.split(text, "BEGIN NOETIC HARNESS INSTRUCTIONS")) == 2
  end

  test "beads' settings in .codex/config.toml survive", %{root: root} do
    File.mkdir_p!(Path.join(root, ".codex"))
    File.write!(Path.join(root, ".codex/config.toml"), "[features]\nhooks = true\n")
    sync!()

    toml = read!(root, ".codex/config.toml")
    assert toml =~ "[features]\nhooks = true"
    assert toml =~ "[mcp_servers.noetic-harness]"

    assert toml =~
             ~s|args = ["-c", "cd \\"$(git rev-parse --show-toplevel)\\" && exec noetic-harness mcp"]|
  end

  test "somebody else's MCP server in .cursor/mcp.json survives", %{root: root} do
    File.mkdir_p!(Path.join(root, ".cursor"))

    File.write!(
      Path.join(root, ".cursor/mcp.json"),
      ~s|{"mcpServers": {"theirs": {"command": "their-server"}}, "other": 1}|
    )

    sync!()
    json = JSON.decode!(read!(root, ".cursor/mcp.json"))
    assert json["mcpServers"]["theirs"] == %{"command" => "their-server"}
    assert json["mcpServers"]["noetic-harness"]["command"] == "bash"
    assert json["other"] == 1
  end

  test "a JSON file that does not parse is left exactly as it is", %{root: root} do
    File.mkdir_p!(Path.join(root, ".gemini"))
    File.write!(Path.join(root, ".gemini/settings.json"), "{ not json")
    sync!()
    assert read!(root, ".gemini/settings.json") == "{ not json"
  end

  test "the whole files carry the banner, and Cursor's is always applied", %{root: root} do
    sync!()
    assert read!(root, "GEMINI.md") =~ "<!-- GENERATED"
    cursor = read!(root, ".cursor/rules/harness.mdc")
    assert cursor =~ ~r/\A---\n.*alwaysApply: true\n---\n/s
    assert cursor =~ "<!-- GENERATED"
  end

  # `only: :instructions`, not the whole of `drift/1`, and that is the fix for
  # An earlier change rather than a narrowing of the claim. The whole of it composes all
  # 270 standing prompts, and `Prompt.compose/2` reloads the registry for each,
  # so this test used to make ~1,500 calls to OTP's file server to ask about
  # six files. Under load a call costs ~60 ms, and the test took 30 s in a
  # loaded suite and 60 s, its timeout, on the workstation. The validator's
  # `adapters` check still asks the whole question (`ValidationTest`).
  test "a hand edit is drift", %{root: root} do
    sync!()
    File.write!(Path.join(root, "GEMINI.md"), "edited by hand\n")

    {:ok, registry} = Noetic.Harness.Registry.load()
    drift = Noetic.Harness.Adapters.drift(registry, only: :instructions)
    assert "GEMINI.md" in drift
    refute ".cursor/rules/harness.mdc" in drift
  end

  test "only: says which adapters are asked about, and nothing else is reported" do
    sync!()
    {:ok, registry} = Noetic.Harness.Registry.load()

    # This root has no `.claude/agents/`, so every nucleus adapter is missing,
    # and only the question that asks about them says so.
    assert Noetic.Harness.Adapters.drift(registry, only: :instructions) == []
    claude = Noetic.Harness.Adapters.drift(registry, only: :claude)
    assert claude != [] and Enum.all?(claude, &String.starts_with?(&1, ".claude/agents/"))
  end

  test "a generated file nothing produces is an orphan; a file without the banner is not",
       %{root: root} do
    dir = Path.join(root, ".claude/agents")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "no-such-role.md"),
      "<!-- GENERATED by `noetic-harness sync` -->\n"
    )

    File.write!(Path.join(dir, "written-by-a-person.md"), "a person's own agent\n")

    {:ok, registry} = Noetic.Harness.Registry.load()
    drift = Noetic.Harness.Adapters.drift(registry, only: :claude)

    assert ".claude/agents/no-such-role.md (generated, but nothing produces it any more)" in drift
    refute Enum.any?(drift, &String.contains?(&1, "written-by-a-person"))
  end
end
