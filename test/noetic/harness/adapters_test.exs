defmodule Noetic.Harness.AdaptersTest do
  # async: false: one test deliberately edits a generated file to prove drift is
  # detected, and a concurrent test reading that file would see the edit.
  use ExUnit.Case, async: false

  # This repository's generated adapters against its definitions: the sync
  # drift check, which is about this repository.
  @moduletag this_repository: true

  alias Noetic.Harness.{Adapters, Registry}

  setup_all do
    {:ok, registry: Registry.load!()}
  end

  test "the committed adapters match what the definitions produce", %{registry: registry} do
    assert Adapters.drift(registry) == [],
           "run `noetic-harness sync` — the generated files and the canonical definitions disagree"
  end

  test "there is one standing prompt per registered role", %{registry: registry} do
    generated = Path.wildcard(Path.join(Noetic.Harness.agents_path("prompts"), "*.md"))
    assert length(generated) == length(registry.agents)
  end

  test "Claude adapters are generated for the nucleus only, because descriptions cost context", %{
    registry: registry
  } do
    generated = Path.wildcard(Path.join(Noetic.Harness.root(), ".claude/agents/*.md"))

    assert length(generated) == length(Registry.nucleus(registry))
    assert length(generated) < length(registry.agents)
  end

  test "every generated file says it is generated and names the command" do
    files =
      Path.wildcard(Path.join(Noetic.Harness.agents_path("prompts"), "*.md")) ++
        Path.wildcard(Path.join(Noetic.Harness.root(), ".claude/agents/*.md"))

    for path <- Enum.take_random(files, 12) do
      content = File.read!(path)
      assert content =~ "GENERATED", "#{path} carries no banner"
      assert content =~ "noetic-harness sync"
    end
  end

  test "a Claude adapter carries the front matter Claude Code needs", %{registry: registry} do
    agent = Registry.nucleus(registry) |> hd()
    content = File.read!(Path.join(Noetic.Harness.root(), ".claude/agents/#{agent["id"]}.md"))

    assert content =~ ~r/\A---\nname: #{Regex.escape(agent["id"])}\ndescription: .+\n---/
  end

  test "generated adapters point at the constitution rather than inlining it" do
    content =
      File.read!(Path.join(Noetic.Harness.agents_path("prompts"), "backend.typedb_engineer.md"))

    assert content =~ ".agents/constitution.md"
    refute content =~ "# Agent Constitution"
  end

  test "the index covers every role and marks the nucleus", %{registry: registry} do
    index = File.read!(Path.join(Noetic.Harness.agents_path(), "AGENTS_INDEX.md"))

    for agent <- Enum.take_random(registry.agents, 20) do
      assert index =~ agent["id"]
    end

    assert index =~ "competency library, not a process list"
  end

  test "a hand edit to a generated file is detected as drift", %{registry: registry} do
    path = Path.join(Noetic.Harness.agents_path("prompts"), "backend.otp_architect.md")
    original = File.read!(path)

    try do
      File.write!(path, original <> "\nedited by hand\n")
      drifted = Adapters.drift(registry)
      assert ".agents/prompts/backend.otp_architect.md" in drifted
    after
      File.write!(path, original)
    end

    assert Adapters.drift(registry) == []
  end
end
