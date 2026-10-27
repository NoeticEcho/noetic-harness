defmodule Noetic.Harness.RegistryTest do
  @moduledoc """
  The registry's own invariants, checked against the repository's real
  definitions rather than a fixture — because the claim worth making is that
  *this* registry is sound, not that a registry could be.
  """
  # `async: true` since an earlier change. It was sync because the fixture root was
  # `NOETIC_HARNESS_ROOT`, a VM-global, so a fixture tree here was visible to
  # every other test in the VM. `Noetic.Harness.put_root/1` scopes it to this
  # process and the `Task`s it spawns, so the isolation is per test.
  use ExUnit.Case, async: true

  # About this repository's registry, which it reads. The
  # fixture tests below build a tree of their own.
  @moduletag this_repository: true

  alias Noetic.Harness.{Fixture, Registry}

  setup_all do
    {:ok, registry: Registry.load!()}
  end

  test "every agent parses and carries the required fields", %{registry: registry} do
    for agent <- registry.agents do
      for field <- ~w(id name domain archetype capabilities skills tools max_trust status) do
        assert Map.has_key?(agent, field), "#{agent["id"] || inspect(agent)} is missing #{field}"
      end
    end
  end

  test "ids are unique, and so are the upstream ids", %{registry: registry} do
    assert length(registry.agents) ==
             registry.agents |> Enum.map(& &1["id"]) |> Enum.uniq() |> length()

    # Only the derived ones. A role added by hand through `overrides/`
    # has no upstream legacy id and carries `nil` — with two of
    # them `Enum.uniq/1` would collapse the pair and this would fail for a
    # reason that has nothing to do with the upstream registry.
    legacy = registry.agents |> Enum.map(& &1["legacy_id"]) |> Enum.reject(&is_nil/1)

    assert length(legacy) == legacy |> Enum.uniq() |> length()
  end

  test "the full upstream registry survived the derivation", %{registry: registry} do
    # 270 is the count of *derived* roles, and it stays 270 — that is the
    # claim, and pinning `length(registry.agents)` was a proxy for it that
    # stopped being one when an earlier change let `overrides/` add a role. A drop
    # below 270 means the derivation lost something; a rise means a hand-added
    # role, which is a different event and must not be able to hide the first.
    derived = Enum.reject(registry.agents, &(&1["added"] == true))
    added = Enum.filter(registry.agents, &(&1["added"] == true))

    assert length(derived) == 270,
           "the derivation produced #{length(derived)} roles, not 270 — something upstream " <>
             "was lost, and the #{length(added)} hand-added role(s) are not it"

    assert map_size(registry.domains) == 21

    for agent <- added do
      assert agent["domain"] in Map.keys(registry.domains),
             "#{agent["id"]} was added by hand into a domain that does not exist"
    end
  end

  test "every referenced domain, archetype and capability exists", %{registry: registry} do
    for agent <- registry.agents do
      assert Map.has_key?(registry.domains, agent["domain"])
      assert Map.has_key?(registry.archetypes, agent["archetype"])

      for capability <- agent["capabilities"] do
        assert Map.has_key?(registry.capabilities, capability),
               "#{agent["id"]} names capability #{capability}, which is not in the vocabulary"
      end
    end
  end

  test "no role exceeds its domain's trust ceiling", %{registry: registry} do
    for agent <- registry.agents do
      ceiling = registry.domains[agent["domain"]]["trust_ceiling"]

      refute Noetic.Harness.Policy.at_least?(agent["max_trust"], ceiling) and
               agent["max_trust"] != ceiling,
             "#{agent["id"]} holds #{agent["max_trust"]} above the #{agent["domain"]} ceiling #{ceiling}"
    end
  end

  test "supplying/2 requires all capabilities, not any", %{registry: registry} do
    both = Registry.supplying(registry, ["typedb.schema", "semantic.modeling"])
    assert both != []

    assert Enum.all?(
             both,
             &("typedb.schema" in &1["capabilities"] and "semantic.modeling" in &1["capabilities"])
           )

    impossible = Registry.supplying(registry, ["typedb.schema", "frontend.design_system"])
    assert Enum.all?(impossible, &("frontend.design_system" in &1["capabilities"]))
  end

  test "the nucleus is a real subset and every member has an operational overlay", %{
    registry: registry
  } do
    nucleus = Registry.nucleus(registry)
    assert length(nucleus) > 0
    assert length(nucleus) < length(registry.agents)

    for agent <- nucleus do
      assert {:ok, _overlay} = Registry.overlay(agent["id"]),
             "#{agent["id"]} is in the nucleus but has no .agents/roles/ overlay"
    end
  end

  test "dormant roles are excluded from routing", %{registry: registry} do
    dormant = Enum.filter(registry.agents, &(&1["status"] == "dormant"))

    assert dormant != [],
           "the economy domain is meant to be dormant; if it is not, this test is stale"

    capability = hd(dormant)["capabilities"] |> hd()
    refute Enum.any?(Registry.supplying(registry, [capability]), &(&1["status"] == "dormant"))
  end

  @tag :fixture
  test "a duplicate id is a load-time failure, not a silent last-one-wins" do
    tree = Fixture.minimal()

    duplicated =
      update_in(tree["registry/agents.json"]["agents"], fn [agent] -> [agent, agent] end)

    Fixture.with_tree(duplicated, fn _root ->
      {:ok, registry} = Registry.load()
      # The loader keeps both; the validator is what refuses them. Asserting the
      # loader silently deduplicated would be asserting the bug.
      assert length(registry.agents) == 2
      assert {:ok, findings} = Noetic.Harness.Validation.run([:registry])
      assert Enum.any?(findings, fn {_severity, message} -> message =~ "appears 2 times" end)
    end)
  end

  @tag :fixture
  test "an unknown reference fails clearly rather than producing an empty field" do
    tree = Fixture.minimal()

    broken =
      update_in(tree["registry/agents.json"]["agents"], fn [agent] ->
        [Map.put(agent, "capabilities", ["nonexistent.capability"])]
      end)

    Fixture.with_tree(broken, fn _root ->
      assert {:ok, findings} = Noetic.Harness.Validation.run([:registry])

      assert Enum.any?(findings, fn {severity, message} ->
               severity == :error and message =~ "unknown capability nonexistent.capability"
             end)
    end)
  end

  @tag :fixture
  test "a missing definition file names the file" do
    tree = Map.delete(Fixture.minimal(), "registry/capabilities.json")

    Fixture.with_tree(tree, fn _root ->
      assert {:error, message} = Registry.load()
      assert message =~ "capabilities.json"
      assert message =~ "not found"
    end)
  end

  describe "the escape hatch can add a role, not only amend one" do
    # The System One overlay proposes new roles and there was no
    # way to add one by hand: `agents.json` is generated and must not be
    # edited, and `overrides/` only merged over entries that already existed.
    # A file named for an unknown id was loaded, matched nothing, and was
    # dropped without a word.

    @complete %{
      "id" => "qa.someone_new",
      "name" => "Someone New",
      "domain" => "qa",
      "capabilities" => ["qa.testing"],
      "max_trust" => "T1",
      "status" => "active"
    }

    test "a complete override with an unknown id is a role" do
      generated = [%{"id" => "backend.someone_known"}]

      {[added], orphans} = Registry.unmatched(generated, %{"qa.someone_new" => @complete})

      assert added["id"] == "qa.someone_new"
      assert added["added"] == true
      assert orphans == []
    end

    test "an incomplete override with an unknown id is an orphan, not a role" do
      # The case that makes the addition path safe. Once a file can create a
      # role, a typo in a filename means a role that is simply absent from a
      # registry of 270 — which nobody notices. So incomplete is loud.
      generated = [%{"id" => "backend.someone_known"}]
      typo = Map.delete(@complete, "capabilities")

      {added, [{id, _spec}]} = Registry.unmatched(generated, %{"qa.someone_nwe" => typo})

      assert added == []
      assert id == "qa.someone_nwe"
    end

    test "an override whose id is known still amends rather than adds" do
      generated = [%{"id" => "qa.someone_new", "name" => "Old"}]

      {added, orphans} = Registry.unmatched(generated, %{"qa.someone_new" => @complete})

      assert added == []
      assert orphans == []
    end

    test "addition?/1 wants every required field and says which they are" do
      assert Registry.addition?(@complete)
      refute Registry.addition?(%{})
      refute Registry.addition?("not a map")

      for field <- Registry.required_for_addition() do
        refute Registry.addition?(Map.delete(@complete, field)),
               "a spec missing #{field} was read as a complete role"
      end
    end

    test "the validator reports an orphan by name and by what it is missing" do
      tree =
        Map.put(Fixture.minimal(), "registry/overrides/backend.typpo.json", %{
          "name" => "Typo",
          "domain" => "backend"
        })

      Fixture.with_tree(tree, fn _root ->
        {:ok, findings} = Noetic.Harness.Validation.run([:registry])

        errors = for {:error, message} <- findings, message =~ "typpo", do: message

        assert [message] = errors
        assert message =~ "matches no generated role"
        assert message =~ "capabilities"
        assert message =~ "max_trust"
      end)
    end

    test "the role this bead added is actually in the registry", %{registry: registry} do
      # Against the real definitions, because the claim is about this
      # repository. The prompt composes too — `noetic-harness sync` wrote 271
      # standing prompts where it used to write 270.
      assert {:ok, agent} = Registry.fetch(registry, "qa.calibration_analyst")

      assert agent["added"] == true, "it is present but not by the addition path"
      assert "evolution.calibration" in agent["capabilities"]

      assert Map.has_key?(registry.capabilities, "evolution.calibration"),
             "the role holds a capability the registry does not define"
    end
  end
end
