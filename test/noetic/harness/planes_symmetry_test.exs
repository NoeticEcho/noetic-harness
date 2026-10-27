defmodule Noetic.Harness.PlanesSymmetryTest do
  @moduledoc """
  The `planes` check in both directions, everywhere a role or a workflow is
  named (item C).

  Before it, a development workflow naming a runtime role was refused only
  when the role was an escalation target or held one of its steps' gates. A
  development workflow whose default lane ran a review gate held by a runtime
  role validated, and nothing at all refused a runtime workflow naming a
  development role. A role is named in four places: a workflow's escalation
  target, and the holder of a gate a workflow's step, its lane, or a role or
  capability itself names. An escalation can also name a workflow. Each is
  held here, each way.

  The root holds both planes (`Noetic.Harness.RuntimePack.mixed_root!/2`), and
  `validation.ex` is behind the evaluator fence, so this lands only with the
  person's approval.
  """

  # async: true: each test builds a root of its own and points only its own
  # process at it (`Noetic.Harness.put_root/1`, which a `Task` it starts
  # inherits); the loaders' caches are per process too. Nothing is shared.
  use ExUnit.Case, async: true

  import Noetic.Harness.RuntimePack,
    only: [mixed_root!: 1, mixed_root!: 2, edit!: 3, update_role: 3]

  alias Noetic.Harness.Validation

  # A review a development role holds, and one a runtime role holds.
  @development_review %{
    "id" => "code.second_read",
    "name" => "a second reader passed the change",
    "kind" => "review",
    "severity" => "blocking",
    "holder" => "qa.test_architect"
  }

  @runtime_review %{
    "id" => "copy.second_read",
    "name" => "a second reader passed the copy",
    "kind" => "review",
    "severity" => "blocking",
    "holder" => "editorial.proofreader"
  }

  defp planes do
    {:ok, findings} = Validation.run([:planes, :gates, :workflows])
    for {:error, message} <- findings, do: message
  end

  defp gate!(agents, gate) do
    edit!(
      agents,
      "policies/gates.json",
      &Map.update!(&1, "gates", fn gates -> gates ++ [gate] end)
    )
  end

  defp workflow!(agents, file, fun), do: edit!(agents, "workflows/" <> file, fun)

  defp escalate(doc, to),
    do: Map.update(doc, "escalations", [], &(&1 ++ [%{"when" => "it is unclear", "to" => to}]))

  test "the mixed root names nothing across the planes" do
    mixed_root!("symmetry-clean")
    assert planes() == []
  end

  describe "a development workflow" do
    test "whose default lane runs a review a runtime role holds" do
      mixed_root!("symmetry-dev-lane", fn agents ->
        gate!(agents, @runtime_review)

        edit!(agents, "policies/gates.json", fn doc ->
          Map.update!(doc, "lanes", fn lanes ->
            lanes ++
              [
                %{
                  "id" => "reviewed",
                  "doc" => "fast, and a second read",
                  "gates" => ["fast", "copy.second_read"]
                }
              ]
          end)
        end)

        workflow!(
          agents,
          "WF-003-bug-to-root-cause.json",
          &Map.put(&1, "default_lane", "reviewed")
        )
      end)

      assert planes() == [
               "workflow WF-003: a development workflow names the runtime role editorial.proofreader"
             ]
    end

    test "escalating to a runtime workflow" do
      mixed_root!("symmetry-dev-escalation", fn agents ->
        workflow!(agents, "WF-003-bug-to-root-cause.json", &escalate(&1, "WF-101"))
      end)

      assert planes() == [
               "workflow WF-003: a development workflow escalates to the runtime workflow WF-101"
             ]
    end
  end

  describe "a runtime workflow" do
    test "escalating to a development role, or to a development workflow" do
      mixed_root!("symmetry-runtime-escalation", fn agents ->
        workflow!(agents, "WF-101-product-card.json", fn doc ->
          doc |> escalate("engineering.implementer") |> escalate("WF-003")
        end)
      end)

      assert planes() == [
               "workflow WF-101: a runtime workflow names the development role engineering.implementer",
               "workflow WF-101: a runtime workflow escalates to the development workflow WF-003"
             ]
    end

    test "whose step runs a review a development role holds" do
      mixed_root!("symmetry-runtime-step", fn agents ->
        gate!(agents, @development_review)

        workflow!(agents, "WF-102-letter.json", fn doc ->
          Map.update!(doc, "steps", fn steps ->
            Enum.map(steps, fn
              %{"id" => "proofread"} = step ->
                Map.update!(step, "gates", &(&1 ++ ["code.second_read"]))

              step ->
                step
            end)
          end)
        end)
      end)

      assert planes() == [
               "workflow WF-102: a runtime workflow names the development role qa.test_architect"
             ]
    end

    test "whose default lane runs a review a development role holds" do
      mixed_root!("symmetry-runtime-lane", fn agents ->
        gate!(agents, @development_review)

        edit!(agents, "policies/gates.json", fn doc ->
          Map.update!(doc, "lanes", fn lanes ->
            Enum.map(lanes, fn
              %{"id" => "letter"} = lane ->
                Map.update!(lane, "gates", &(&1 ++ ["code.second_read"]))

              lane ->
                lane
            end)
          end)
        end)
      end)

      assert planes() == [
               "workflow WF-102: a runtime workflow names the development role qa.test_architect"
             ]
    end
  end

  describe "a role or a capability" do
    test "naming a review held by a role of the other plane, either way" do
      mixed_root!("symmetry-holders", fn agents ->
        gate!(agents, @development_review)

        edit!(agents, "registry/agents.json", fn doc ->
          doc
          |> update_role(
            "editorial.guardian",
            &Map.update!(&1, "gates", fn g -> g ++ ["code.second_read"] end)
          )
          |> update_role(
            "engineering.implementer",
            &Map.update!(&1, "gates", fn g -> g ++ ["guardian.review"] end)
          )
        end)

        edit!(agents, "registry/capabilities.json", fn doc ->
          Map.update!(doc, "capabilities", fn capabilities ->
            Enum.map(capabilities, fn
              %{"id" => "copy.draft"} = c ->
                Map.update!(c, "gates", &(&1 ++ ["code.second_read"]))

              %{"id" => "qa.testing"} = c ->
                Map.update(c, "gates", ["proof.review"], &(&1 ++ ["proof.review"]))

              c ->
                c
            end)
          end)
        end)
      end)

      found = planes()

      for expected <- [
            "engineering.implementer: a development definition names the gate guardian.review, " <>
              "held by the runtime role editorial.guardian",
            "editorial.guardian: a runtime definition names the gate code.second_read, " <>
              "held by the development role qa.test_architect",
            "capability copy.draft: a runtime definition names the gate code.second_read, " <>
              "held by the development role qa.test_architect",
            "capability qa.testing: a development definition names the gate proof.review, " <>
              "held by the runtime role editorial.proofreader"
          ] do
        assert expected in found, expected
      end
    end
  end
end
