defmodule Noetic.Harness.PromptTest do
  @moduledoc """
  "Every registered agent has a usable prompt" is the claim the whole registry
  rests on. These tests are what makes it a fact.
  """
  # `async: true` since an earlier change. It was sync because the fixture root was
  # `NOETIC_HARNESS_ROOT`, a VM-global, so a fixture tree here was visible to
  # every other test in the VM. `Noetic.Harness.put_root/1` scopes it to this
  # process and the `Task`s it spawns, so the isolation is per test.
  use ExUnit.Case, async: true

  alias Noetic.Harness.{FileServerBudget, Fixture, Prompt, Registry}

  # Composition runs on the pack (`Noetic.Harness.Pack`). The tests tagged
  # `this_repository` are about this repository's 270 roles, their overlays
  # and skills, and read them.
  setup {Noetic.Harness.Pack, :root}

  # This repository's registry, for the tests about it. Per test rather than
  # `setup_all`, whose process is not the test's and so is not on the pack.
  setup context do
    if context[:this_repository], do: {:ok, registry: Registry.load!()}, else: :ok
  end

  # Composing all 270 roles was ~815 calls to OTP's file server,
  # nearly all of them `Registry.load/0` re-reading `registry/overrides/` for
  # each role; 670 since `Loader` reads raw, the directory
  # listings that remain. "no composed prompt leaks" timed out at 60 s in a suite run at
  # load 16 on two cores, stuck in that read. Each test composes every role
  # once and states what that costs (`FileServerBudget`).
  @calls 800

  @tag timeout: FileServerBudget.timeout(@calls)
  @tag this_repository: true
  test "every one of the registered roles composes a prompt", %{registry: registry} do
    {failures, calls} =
      FileServerBudget.calls(fn ->
        registry.agents
        |> Enum.map(fn agent -> {agent["id"], Prompt.compose(agent["id"])} end)
        |> Enum.filter(&match?({_id, {:error, _}}, &1))
      end)

    assert failures == [], "roles that cannot compose: #{inspect(failures, limit: 5)}"
    assert calls <= @calls, "composing every role made #{calls} file-server calls"
  end

  @tag timeout: FileServerBudget.timeout(@calls)
  @tag this_repository: true
  test "no composed prompt leaks an unrendered placeholder", %{registry: registry} do
    {leaking, calls} =
      FileServerBudget.calls(fn ->
        registry.agents
        |> Enum.map(fn agent -> {agent["id"], Prompt.compose!(agent["id"])} end)
        |> Enum.filter(fn {_id, prompt} -> String.contains?(prompt, "{{") end)
        |> Enum.map(&elem(&1, 0))
      end)

    assert leaking == []
    assert calls <= @calls, "composing every role made #{calls} file-server calls"
  end

  test "every template placeholder is one the renderer supplies" do
    assert {:ok, []} = Prompt.unknown_placeholders()
  end

  test "a prompt carries the constitution verbatim, first" do
    prompt = Prompt.compose!("backend.typedb_engineer")
    constitution = File.read!(Noetic.Harness.agents_path("constitution.md"))

    assert String.starts_with?(prompt, String.trim(constitution))
  end

  test "every required section is present" do
    prompt = Prompt.compose!("qa.qa_architect")

    for heading <- [
          "# Identity",
          "# Mission",
          "# Skills",
          "# Tools",
          "# Context contract",
          "# Artifact contract",
          "# Working method",
          "# Evidence contract",
          "# Quality gates",
          "# Escalation",
          "# Completion"
        ] do
      assert String.contains?(prompt, heading), "missing #{heading}"
    end
  end

  @tag this_repository: true
  test "skills resolve to real files, and a missing one is called out loudly" do
    prompt = Prompt.compose!("backend.typedb_engineer")

    assert prompt =~ ".agents/skills/typeql/SKILL.md"
    refute prompt =~ "NOT FOUND ON DISK"
  end

  @tag this_repository: true
  test "the role overlay appears when there is one, and a substitute when there is not", %{
    registry: registry
  } do
    with_overlay = Prompt.compose!("backend.otp_architect")
    assert with_overlay =~ "OTP concurrency specialist"

    without =
      registry.agents
      |> Enum.find(&(Registry.overlay(&1["id"]) == :error))

    prompt = Prompt.compose!(without["id"])
    assert prompt =~ "no hand-authored operational overlay"
  end

  test "a workflow step narrows the prompt to that step" do
    prompt = Prompt.compose!("backend.typedb_engineer", workflow: "WF-002", step: "implement")

    assert prompt =~ "WF-002"
    assert prompt =~ "Implement the smallest coherent change"
    assert prompt =~ "the same step fails three times"
  end

  test "an unknown agent is an error, not an empty prompt" do
    assert {:error, message} = Prompt.compose("backend.does_not_exist")
    assert message =~ "no agent with id"
  end

  @tag :fixture
  test "an undeclared placeholder in a template is refused rather than rendered literally" do
    tree =
      Fixture.minimal()
      |> Fixture.with_templates()
      |> Map.update!("templates/prompt/00-identity.md", &(&1 <> "\n{{agent.invented_field}}\n"))

    Fixture.with_tree(tree, fn _root ->
      assert {:error, message} = Prompt.compose("backend.engineer")
      assert message =~ "unknown placeholders"
      assert message =~ "agent.invented_field"
    end)
  end

  @tag :fixture
  test "a required section that renders empty is refused" do
    tree =
      Fixture.minimal()
      |> Fixture.with_templates()
      |> Map.put("templates/prompt/07-evidence.md", "")

    Fixture.with_tree(tree, fn _root ->
      assert {:error, message} = Prompt.compose("backend.engineer")
      assert message =~ "required but rendered empty"
    end)
  end
end
