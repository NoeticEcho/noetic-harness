defmodule Noetic.Harness.PlanesSignalsTest do
  @moduledoc """
  The router's signals name no runtime capability or workflow (item A's signals check).

  `Router.route/2` refuses work whose signals reach a runtime capability
  (`PlanesApartTest`). That is a refusal at the moment someone routes; this
  is the same rule before anything routes, in `validate`, everywhere
  `signals.json` can send the router: a signal, a declared kind, and the
  fallback's capabilities and workflow.

  `validation.ex` is behind the evaluator fence, so this lands only with the
  person's approval.
  """

  # async: true: each test builds a root of its own and points only its own
  # process at it (`Noetic.Harness.put_root/1`, which a `Task` it starts
  # inherits); the loaders' caches are per process too. Nothing is shared.
  use ExUnit.Case, async: true

  import Noetic.Harness.RuntimePack, only: [root!: 1, mixed_root!: 1, mixed_root!: 2, edit!: 3]

  alias Noetic.Harness.Validation

  defp planes do
    {:ok, findings} = Validation.run([:planes])
    for {:error, message} <- findings, do: message
  end

  defp signals!(agents, fun), do: edit!(agents, "registry/signals.json", fun)

  test "the starter's signals beside a runtime pack name nothing of it" do
    mixed_root!("signals-clean")
    assert planes() == []
  end

  test "a runtime pack with no router has no signals to check" do
    dir = root!("signals-none")
    refute File.exists?(Path.join(dir, ".agents/registry/signals.json"))
    assert planes() == []
  end

  test "a signal, a declared kind, and the fallback, each naming a runtime capability" do
    mixed_root!("signals-capability", fn agents ->
      signals!(agents, fn doc ->
        doc
        |> Map.update!("signals", fn signals ->
          signals ++
            [%{"id" => "card", "text" => "product card", "capabilities" => ["copy.draft"]}]
        end)
        |> put_in(["kind_signals", "docs"], ["docs.authoring", "proof.read"])
        |> update_in(["fallback", "capabilities"], &(&1 ++ ["sources.research"]))
      end)
    end)

    assert Enum.sort(planes()) ==
             Enum.sort([
               "signal card: names the runtime capability copy.draft, and the development " <>
                 "router routes only to development capabilities",
               "kind_signals docs: names the runtime capability proof.read, and the development " <>
                 "router routes only to development capabilities",
               "fallback: names the runtime capability sources.research, and the development " <>
                 "router routes only to development capabilities"
             ])
  end

  test "a fallback routing to a runtime workflow" do
    mixed_root!("signals-workflow", fn agents ->
      signals!(agents, &put_in(&1, ["fallback", "workflow"], "WF-101"))
    end)

    assert planes() == ["fallback: routes to the runtime workflow WF-101"]
  end
end
