defmodule Noetic.Harness.RouterTest do
  @moduledoc """
  Routing is capability-based. These tests assert that property rather than
  particular role names, except where a named role is the point.

  The router's mechanism is tested on the pack's signals, registry and
  workflows (`Noetic.Harness.Pack`). "Routes this repository has got wrong"
  is tagged `this_repository`: each case there is a title somebody routed
  here and checked by hand, and what it guards is this repository's
  `signals.json`, so it reads that one.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Loader, Registry, Router, Workflow}

  setup {Noetic.Harness.Pack, :root}

  # Per test rather than `setup_all`: the root is per process, and the
  # module's process is not the test's.
  setup do
    {:ok, signals} =
      Loader.load(Path.join(Noetic.Harness.agents_path("registry"), "signals.json"))

    {:ok, registry: Registry.load!(), signals: signals}
  end

  test "a TypeDB task resolves to TypeDB capabilities, not to a role name", %{signals: signals} do
    {capabilities, _fired} =
      Router.extract(%{title: "change the TypeDB schema for motif authorship"}, signals)

    assert "typedb.schema" in capabilities
    assert "semantic.modeling" in capabilities
  end

  test "paths route even when the words do not", %{signals: signals} do
    {capabilities, fired} =
      Router.extract(
        %{title: "make it work", paths: ["apps/acme_web/assets/js/app.ts"]},
        signals
      )

    assert "frontend.web" in capabilities
    assert Enum.any?(fired, &("path" in &1["matched_on"]))
  end

  test "a short word inside a longer one does not fire a signal", %{signals: signals} do
    # "authorship" contains "auth" and "ship"; both used to fire, and the second
    # sent a schema change to the release workflow.
    {capabilities, _fired} = Router.extract(%{title: "record motif authorship"}, signals)

    refute "ops.release" in capabilities
    refute "security.review" in capabilities
  end

  test "nothing firing is reported as low confidence rather than guessed at" do
    {:ok, route} = Router.route(%{title: "do the thing"})

    assert route.confidence == :low
    assert route.workflow["id"] == "WF-001"
  end

  test "an explicit workflow wins over inference" do
    {:ok, route} = Router.route(%{title: "change the TypeDB schema", workflow: "WF-015"})

    assert route.workflow["id"] == "WF-015"
    assert route.workflow_reason =~ "explicitly"
  end

  describe "a workflow started only by id (trigger.explicit)" do
    # WF-021 carries the commonest capabilities at almost the least
    # authority, so before it was excluded from scoring it won every tie in
    # which only capabilities matched — 44 of 438 corpus routes, and every
    # path under `.agents/`.
    test "is never inferred, however well its capabilities match" do
      for work <- [
            %{title: "edit the gate policy", paths: [".agents/policies/gates.json"]},
            %{
              title: "change the run ledger",
              paths: ["apps/noetic_harness/lib/noetic/harness/run.ex"]
            },
            %{title: "epic in a branch"},
            %{title: "implement, test and document a feature, then sync"}
          ] do
        {:ok, route} = Router.route(work)

        refute route.workflow["id"] == "WF-021", "#{inspect(work)} routed to WF-021"
      end
    end

    test "is not even a candidate", %{signals: signals} do
      {capabilities, _fired} =
        Router.extract(%{title: "x", paths: [".agents/policies/gates.json"]}, signals)

      scored =
        Router.score_workflows(
          %{title: "x", paths: [".agents/policies/gates.json"]},
          Workflow.list!(),
          capabilities,
          signals
        )

      refute Enum.any?(scored, fn {workflow, _parts} -> workflow["id"] == "WF-021" end)
    end

    test "is still reached by id" do
      {:ok, route} = Router.route(%{title: "anything", workflow: "WF-021"})

      assert route.workflow["id"] == "WF-021"
    end
  end

  test "a failure report routes to the bug workflow even when it names a domain heavily" do
    {:ok, route} =
      Router.route(%{title: "the product channel crashes when a journey ends mid-ritual"})

    assert route.workflow["id"] == "WF-003"
  end

  test "the team is the smallest set covering the capabilities", %{registry: registry} do
    capabilities = ["typedb.schema", "qa.testing", "docs.authoring"]
    {team, uncovered} = Router.compose_team(registry, capabilities)

    assert uncovered == []
    assert length(team) <= 3

    covered = team |> Enum.flat_map(& &1["capabilities"]) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(capabilities), covered)
  end

  test "the team is capped, and what is left over is reported rather than dropped", %{
    registry: registry
  } do
    capabilities = [
      "typedb.schema",
      "frontend.design_system",
      "ops.incident",
      "data.entity_resolution",
      "security.privacy",
      "product.narrative",
      "frontend.accessibility"
    ]

    {team, uncovered} = Router.compose_team(registry, capabilities, 2)

    assert length(team) == 2
    assert uncovered != []
  end

  test "a lane is a floor: high risk raises it and nothing lowers it" do
    {:ok, workflow} = Noetic.Harness.Workflow.fetch("WF-004")
    assert workflow["default_lane"] == "fast"

    assert Router.lane(workflow, %{}) == "fast"
    assert Router.lane(workflow, %{risk: "high"}) == "focused"
  end

  test "independence constraints are surfaced from the workflow" do
    {:ok, workflow} = Noetic.Harness.Workflow.fetch("WF-010")
    constraints = Router.independence_constraints(workflow)

    assert {"holdout", "candidate"} in constraints
    assert {"antigoodhart", "candidate"} in constraints
  end

  # Every word in this string is ordinary repository prose. None of it is about
  # a database, a benchmark or a schema. A signal that fires on it is matching a
  # substring of a longer word, which is how `ecto` came to fire on "directory"
  # and "vector" and to drag an uncovered capability into most teams.
  @innocuous "the directory holds a vector of selectors; reindex the collection and inspect the projection"

  test "no signal fires on ordinary prose that is about none of them", %{signals: signals} do
    {capabilities, fired} = Router.extract(%{title: @innocuous}, signals)

    assert fired == [],
           "these signals matched a substring rather than a word: " <>
             Enum.map_join(fired, ", ", & &1["id"]) <>
             " — anchor the short alternatives in .agents/registry/signals.json"

    # `extract/2` falls back to a default set when nothing fires, so the
    # capabilities are not empty and asserting on them would say nothing.
    assert is_list(capabilities)
  end

  test "the ecto signal still fires on work that is actually about Ecto", %{signals: signals} do
    {_capabilities, fired} =
      Router.extract(%{title: "add a migration and a changeset for the motif repo"}, signals)

    assert "ecto" in Enum.map(fired, & &1["id"])
  end

  describe "the kind of work, when nobody declared one" do
    @crash "the lineage report crashes mid-import when two users join"

    test "a failure verb makes it a bug, not a feature in the domain it mentions", %{
      signals: signals,
      registry: registry
    } do
      # The shape of the sentence signals.json's own `weights` doc uses as its
      # example, which routed to a domain's feature workflow until an earlier change. A bug
      # is always *in* a domain, so the domain's keywords and capabilities
      # always match it.
      assert Router.kind(%{title: @crash}, signals) == "bug"

      {capabilities, _fired} = Router.extract(%{title: @crash}, signals)

      {workflow, _why} =
        Router.select_workflow(%{title: @crash}, Workflow.list!(), capabilities, signals)

      assert workflow["id"] == "WF-003"
      assert registry
    end

    test "a kind the caller declared is never overridden by inference", %{signals: signals} do
      assert Router.kind(%{title: @crash, kind: "feature"}, signals) == "feature"
    end

    test "a sentence with no family fires nothing and infers nothing", %{signals: signals} do
      assert Router.kind(%{title: "the horizon has a hard seam in every frame"}, signals) == nil
    end

    test "the precedence, not the file order, decides between two fired families", %{
      signals: signals
    } do
      # `bug` and `data` both fire on the example. `data` is declared first
      # in signals.json; `bug` comes first in the precedence, and the precedence
      # is what must win — otherwise the fix is an accident of file order.
      {_capabilities, fired} = Router.extract(%{title: @crash}, signals)
      families = fired |> Enum.map(& &1["family"]) |> Enum.reject(&is_nil/1)

      assert "bug" in families
      assert "data" in families
      assert Router.kind(%{title: @crash}, signals) == "bug"
    end
  end

  describe "a body informs the team, not the classification" do
    # An earlier change as filed: a feature about the toolchain whose body mentioned a
    # word of another family. That family fired and its 5 beat the declared
    # kind's 4, sending a toolchain upgrade to that family's workflow.
    @toolchain %{
      title: "Take the toolchain to current versions and keep it there",
      # "lineage" fires the `data` family and is not one of WF-005's own
      # trigger keywords, so only the family can pull the route there.
      body:
        "Erlang, Elixir and Node lag the current releases; the lineage report must keep working.",
      kind: "feature"
    }

    test "a family named only in the body does not outweigh the declared kind" do
      {:ok, route} = Router.route(@toolchain)
      refute route.workflow["id"] == "WF-005"
      assert %{family: 0} = Enum.find(route.candidates, &(&1.id == "WF-005")) || %{family: 0}
    end

    test "the body still reaches the capabilities" do
      {:ok, with_body} = Router.route(@toolchain)
      {:ok, without} = Router.route(Map.delete(@toolchain, :body))
      assert "data.provenance" in with_body.capabilities
      refute "data.provenance" in without.capabilities
    end

    test "a path still classifies: it is what the change touched" do
      {:ok, route} =
        Router.route(%{title: "tighten this up", paths: ["docs/guides/setup.md"]})

      assert Enum.any?(route.candidates, &(&1.family > 0))
    end
  end
end
