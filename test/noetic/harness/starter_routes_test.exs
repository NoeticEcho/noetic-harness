defmodule Noetic.Harness.StarterRoutesTest do
  @moduledoc """
  What the starter pack's router does with the first titles a new user types.

  `fix the parser's handling of empty input` is the release workflow's own
  demonstration title, and in a fresh `init` repository it fell back to WF-001
  with low confidence: no signal of the starter's knew "fix". Each test here
  routes against a repository `Starter.install/1` wrote, so the starter's
  `signals.json` and workflows are what is under test, not this repository's.

  "fix" fires a signal of its own with the regression capabilities and no
  family. A family would outrank the subject of the sentence: `bug` comes
  first in `kind_inference.precedence`, so "fix the docs typo" would be a
  bug and not documentation. Without one, a "fix" with no other word reaches
  WF-003 by its capabilities, and a "fix" beside a subject goes where the
  subject's family sends it.
  """

  # async: false: the router reads the harness root, which is VM-global.
  use ExUnit.Case, async: false

  alias Noetic.Harness.{Router, Starter}

  setup_all do
    root = Noetic.Harness.TestTmp.dir!("starter-routes")
    {:ok, _} = Starter.install(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  # The root is the test process's own: `setup_all` runs in another one.
  setup %{root: root} do
    previous = Noetic.Harness.root_override()
    Noetic.Harness.put_root(root)

    on_exit(fn ->
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
    end)

    :ok
  end

  defp route(title) do
    {:ok, route} = Router.route(%{title: title})
    route
  end

  test "the release demo's title is a bug, routed to WF-003 and not to the fallback" do
    route = route("fix the parser's handling of empty input")

    assert route.workflow["id"] == "WF-003", route.workflow_reason
    assert "fix" in Enum.map(route.signals, & &1["id"])
    refute route.confidence == :low
  end

  for title <- [
        "bug: login crashes on empty password",
        "the export button does not work",
        "the export button doesn't work since the upgrade",
        "fixes the off-by-one in pagination",
        "bugfix: the importer drops the last row",
        "hotfix the off-by-one in pagination",
        "search returns the wrong result for quoted words"
      ] do
    test "#{inspect(title)} routes to WF-003" do
      route = route(unquote(title))
      assert route.workflow["id"] == "WF-003", route.workflow_reason
    end
  end

  test "\"fix the docs typo\" is documentation, not a bug" do
    route = route("fix the docs typo")
    assert route.workflow["id"] == "WF-019", route.workflow_reason
  end

  test "a fixed-width header is not a fix" do
    refute "fix" in Enum.map(route("a fixed-width header on the report").signals, & &1["id"])
  end

  test "\"don't workaround\" is not a regression" do
    refute "regression" in Enum.map(
             route("don't workaround the guard in the parser").signals,
             & &1["id"]
           )
  end

  test "a fixture is not a fix" do
    refute "fix" in Enum.map(route("add fixtures for the parser tests").signals, & &1["id"])
  end
end
