defmodule Noetic.Harness.SecurityTest do
  @moduledoc """
  Permission boundaries. These are the tests whose failure would mean an agent
  can do something nobody granted it.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Policy, Prompt, Registry}

  # On the pack (`Noetic.Harness.Pack`).
  setup {Noetic.Harness.Pack, :root}

  # Per test: the root is per process, and `setup_all`'s process is not on
  # the pack.
  setup do
    {:ok, tool_defs} = Policy.tools_by_id()
    {:ok, registry: Registry.load!(), tool_defs: tool_defs}
  end

  test "the effective trust level is the minimum of role and step, in both directions" do
    assert Policy.resolve_trust("T4", "T1") == "T1"
    assert Policy.resolve_trust("T1", "T4") == "T1"
    assert Policy.resolve_trust("T2", "T2") == "T2"
  end

  test "an absent level degrades to the other, and two absent to T0" do
    assert Policy.resolve_trust(nil, "T3") == "T3"
    assert Policy.resolve_trust("T3", nil) == "T3"
    assert Policy.resolve_trust(nil, nil) == "T0"
  end

  test "a tool above the run's trust level is withheld, with a reason", %{tool_defs: defs} do
    {granted, withheld} = Policy.grant_tools(["read", "wrangler"], "T2", defs)

    assert "read" in granted
    refute "wrangler" in granted
    assert {"wrangler", reason} = List.keyfind(withheld, "wrangler", 0)
    assert reason =~ "requires T4"
  end

  test "an undefined tool is withheld rather than granted by default", %{tool_defs: defs} do
    {granted, withheld} = Policy.grant_tools(["invented.tool"], "T5", defs)

    assert granted == []
    assert {"invented.tool", reason} = List.keyfind(withheld, "invented.tool", 0)
    assert reason =~ "not defined"
  end

  test "no role holds T5 by role: administrative authority is granted per action or not at all",
       %{registry: registry} do
    assert Enum.all?(registry.agents, &(&1["max_trust"] != "T5"))
  end

  test "infrastructure-write tools are not granted to generic implementation roles", %{
    registry: registry
  } do
    infrastructure = ~w(wrangler aiven)

    for agent <- registry.agents,
        tool <- agent["tools"],
        tool in infrastructure do
      assert Noetic.Harness.Policy.at_least?(agent["max_trust"], "T4"),
             "#{agent["id"]} holds #{tool} at #{agent["max_trust"]}"
    end
  end

  test "a prompt states the withheld tools rather than silently omitting them" do
    prompt = Prompt.compose!("backend.typedb_engineer", trust: "T0")

    assert prompt =~ "Tools that are not available"
    assert prompt =~ "withheld" or prompt =~ "not present"
  end

  test "an untrusted role cannot escalate by naming a higher trust in the task" do
    # `trust:` is the step's grant, not a raise: the minimum still applies.
    low = Prompt.compose!("research.fundamental_researcher", trust: "T5")

    assert low =~ "Trust level: **T1"
  end

  test "the escalation policy is stated as never self-granted and never delegated sideways" do
    {:ok, doc} = Policy.trust_levels()

    assert doc["escalation"]["never_self_granted"] == true
    assert doc["escalation"]["never_delegated_sideways"] == true
  end

  test "protected operations name the gate that guards them" do
    {:ok, doc} = Policy.trust_levels()

    for level <- doc["levels"], level["id"] in ~w(T4 T5) do
      assert level["requires_gate"] == "protected"
      assert level["requires"] != []
    end
  end

  test "the protected lane contains the manual gates no command can satisfy" do
    {:ok, gates} = Noetic.Harness.Gates.expand("protected")

    assert "review.independent" in gates
    assert "human.approval" in gates
    assert "rollback.stated" in gates
  end
end
