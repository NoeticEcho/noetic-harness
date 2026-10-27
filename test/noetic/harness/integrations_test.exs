defmodule Noetic.Harness.IntegrationsTest do
  @moduledoc """
  The switches for what the harness reaches outside itself:
  on here, where `project.json` says so; off wherever it does not; and
  `project.json` refuses a switch that is not one.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Fixture, Integrations, Project}

  # The pack's copy, read when the module compiles: the harness root is not
  # yet any test's, and a standalone checkout of the engine has no `.agents/`.
  @schema Noetic.Harness.Loader.load!(
            Path.join([Noetic.Harness.Pack.source(), "schemas", "project.schema.json"])
          )

  defp errors(project),
    do: for({:error, m} <- Project.validate(project: project, schema: @schema), do: m)

  @tag this_repository: true
  test "every one is on in this repository, which is how it behaved before there were switches" do
    assert Enum.all?(Integrations.names(), &Integrations.enabled?/1)
  end

  test "absent is off, and so is anything but true" do
    Fixture.with_tree(Fixture.minimal(), fn root ->
      refute Enum.any?(Integrations.names(), &Integrations.enabled?/1)

      Fixture.write_project(root, %{
        "version" => 1,
        "integrations" => %{"beads" => "yes", "knowledge_base" => false, "jido" => true}
      })

      Process.delete({Noetic.Harness.Loader, :cache, Project.path()})

      refute Integrations.enabled?("beads")
      refute Integrations.enabled?("knowledge_base")
      assert Integrations.enabled?("jido")
      refute Integrations.enabled?("workers")
    end)
  end

  test "an integration that is not one is not a question the code can ask" do
    assert_raise FunctionClauseError, fn -> Integrations.enabled?("github") end
  end

  test "project.json refuses a switch that is not a boolean, or not a switch" do
    assert Enum.any?(
             errors(%{"version" => 1, "integrations" => %{"beads" => "yes"}}),
             &(&1 =~ "integrations.beads")
           )

    assert Enum.any?(
             errors(%{"version" => 1, "integrations" => %{"github" => true}}),
             &(&1 =~ "unexpected key github")
           )
  end
end
