defmodule Noetic.Harness.WorkflowTest do
  @moduledoc """
  Two subjects, kept apart:

  - **the engine**, `Workflow.validate/4` and `Workflow.waves/1`, on the
    pack's registry (`Noetic.Harness.Pack`). What a validation catches does
    not depend on which registry it is checked against.
  - **this repository's workflows**, the tests that read `.agents/workflows/`
    as it is: the catalogue, its graphs, WF-010's stages, the pipelines, the
    count of grouped steps. They are about this repository's registry, are tagged
    `this_repository`, and stay on it.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Policy, Registry, Workflow}

  # The pack, except for a test tagged `this_repository`, which reads this
  # repository's `.agents/`. Per test rather than `setup_all`: the root is per
  # process, and `setup_all`'s is not the test's.
  setup {Noetic.Harness.Pack, :root}

  setup do
    {:ok, doc} = Policy.gates()

    {:ok,
     registry: Registry.load!(),
     workflows: Workflow.list!(),
     gate_ids: MapSet.new(doc["gates"], & &1["id"]),
     lane_ids: MapSet.new(doc["lanes"], & &1["id"])}
  end

  @tag this_repository: true
  test "the whole catalogue is present and each workflow has an id and steps", %{
    workflows: workflows
  } do
    assert length(workflows) == 21

    for workflow <- workflows do
      assert workflow["id"] =~ ~r/^WF-\d{3}$/
      assert workflow["steps"] != []
      assert workflow["completion"] != []
    end
  end

  @tag this_repository: true
  test "every workflow graph validates", context do
    problems =
      Enum.flat_map(
        context.workflows,
        &Workflow.validate(&1, context.registry, context.gate_ids, context.lane_ids)
      )

    assert problems == []
  end

  describe "validate/4, the engine, on the pack" do
    test "a missing role is caught: a step whose capability nobody supplies", context do
      workflow = %{
        "id" => "WF-999",
        "steps" => [
          %{
            "id" => "impossible",
            "name" => "x",
            "capabilities" => ["nobody.supplies_this"],
            "trust" => "T1"
          }
        ],
        "completion" => ["done"]
      }

      problems = Workflow.validate(workflow, context.registry, context.gate_ids, context.lane_ids)
      assert Enum.any?(problems, &(&1 =~ "unknown capability nobody.supplies_this"))
    end

    test "an invalid transition is caught: a step consuming a later step's output", context do
      workflow = %{
        "id" => "WF-998",
        "steps" => [
          %{
            "id" => "first",
            "name" => "x",
            "capabilities" => [],
            "trust" => "T1",
            "inputs" => ["thing"],
            "outputs" => []
          },
          %{
            "id" => "second",
            "name" => "y",
            "capabilities" => [],
            "trust" => "T1",
            "inputs" => [],
            "outputs" => ["thing"]
          }
        ],
        "completion" => ["done"]
      }

      problems = Workflow.validate(workflow, context.registry, context.gate_ids, context.lane_ids)
      assert Enum.any?(problems, &(&1 =~ "only produced by a later step"))
    end

    test "a dangling independence constraint is caught, because it is silently inactive otherwise",
         context do
      workflow = %{
        "id" => "WF-997",
        "steps" => [
          %{
            "id" => "review",
            "name" => "x",
            "capabilities" => [],
            "trust" => "T1",
            "independent_of" => ["ghost"]
          }
        ],
        "completion" => ["done"]
      }

      problems = Workflow.validate(workflow, context.registry, context.gate_ids, context.lane_ids)
      assert Enum.any?(problems, &(&1 =~ "silently inactive"))
    end

    test "a workflow that cannot say when it is done is caught", context do
      workflow = %{
        "id" => "WF-996",
        "steps" => [%{"id" => "a", "name" => "x", "capabilities" => [], "trust" => "T1"}],
        "completion" => []
      }

      problems = Workflow.validate(workflow, context.registry, context.gate_ids, context.lane_ids)
      assert Enum.any?(problems, &(&1 =~ "no completion criteria"))
    end

    test "duplicate step ids are caught", context do
      workflow = %{
        "id" => "WF-995",
        "steps" => [
          %{"id" => "same", "name" => "x", "capabilities" => [], "trust" => "T1"},
          %{"id" => "same", "name" => "y", "capabilities" => [], "trust" => "T1"}
        ],
        "completion" => ["done"]
      }

      problems = Workflow.validate(workflow, context.registry, context.gate_ids, context.lane_ids)
      assert Enum.any?(problems, &(&1 =~ "appears 2 times"))
    end
  end

  test "waves group consecutive parallel steps and leave the rest alone" do
    workflow = %{
      "steps" => [
        %{"id" => "a", "parallel_group" => nil},
        %{"id" => "b", "parallel_group" => "explore"},
        %{"id" => "c", "parallel_group" => "explore"},
        %{"id" => "d", "parallel_group" => nil}
      ]
    }

    assert [[%{"id" => "a"}], [%{"id" => "b"}, %{"id" => "c"}], [%{"id" => "d"}]] =
             Workflow.waves(workflow)
  end

  test "waves work on the shape the real workflows actually have: no key at all" do
    # The fixture above writes `"parallel_group" => nil`. Not one step in
    # `.agents/workflows/` does — an ungrouped step simply omits the key — and
    # `waves/1` used to match on a map pattern, which requires the key to
    # exist. Twenty of twenty workflows raised `CaseClauseError` while this
    # suite was green.
    workflow = %{
      "steps" => [
        %{"id" => "a"},
        %{"id" => "b", "parallel_group" => "explore"},
        %{"id" => "c", "parallel_group" => "explore"},
        %{"id" => "d"}
      ]
    }

    assert [[%{"id" => "a"}], [%{"id" => "b"}, %{"id" => "c"}], [%{"id" => "d"}]] =
             Workflow.waves(workflow)
  end

  @tag this_repository: true
  test "every real workflow can be grouped into waves", %{workflows: workflows} do
    # Over the definitions rather than over a fixture, because the defect was
    # that the fixture was more regular than the definitions. Each step appears
    # in exactly one wave and none is lost.
    for workflow <- workflows do
      waves = Workflow.waves(workflow)

      assert Enum.map(waves, &Enum.map(&1, fn step -> step["id"] end)) |> List.flatten() ==
               Enum.map(workflow["steps"], & &1["id"]),
             "#{workflow["id"]}: waves/1 did not return every step exactly once, in order"
    end
  end

  @tag this_repository: true
  test "the evolution workflow keeps its stages in order and skips none", %{workflows: workflows} do
    {:ok, wf} = Workflow.fetch("WF-010")
    ids = Enum.map(wf["steps"], & &1["id"])

    for stage <- ~w(sandbox benchmark holdout transfer antigoodhart archive promote) do
      assert stage in ids, "WF-010 is missing the #{stage} stage"
    end

    assert Enum.find_index(ids, &(&1 == "holdout")) > Enum.find_index(ids, &(&1 == "benchmark"))
    assert Enum.find_index(ids, &(&1 == "promote")) == length(ids) - 1

    # And the holdout must be independent of the candidate that selected it.
    holdout = Enum.find(wf["steps"], &(&1["id"] == "holdout"))
    assert "candidate" in holdout["independent_of"]

    assert length(workflows) > 0
  end

  @tag this_repository: true
  test "pipelines reference only real workflows and real gates", context do
    {:ok, pipelines} = Workflow.pipelines()
    workflow_ids = MapSet.new(context.workflows, & &1["id"])

    for pipeline <- pipelines do
      for id <- pipeline["used_by"], do: assert(MapSet.member?(workflow_ids, id))

      for {stage, gate} <- pipeline["gates"] || %{} do
        assert stage in pipeline["stages"]
        assert MapSet.member?(context.gate_ids, gate) or MapSet.member?(context.lane_ids, gate)
      end
    end
  end
end
