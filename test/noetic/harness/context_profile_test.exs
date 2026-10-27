defmodule Noetic.Harness.ContextProfileTest do
  @moduledoc """
  The context bundle as the environment makes it: with `HARNESS_AGENT` set, as
  a cloud worker has it, and unset, as a local session and hosted CI have it.

  The tests in `ContextTest` pass `:profile` explicitly, so they never read
  the variable. The budget test there does, and it passed in the one place
  that ran it with the variable set and failed everywhere else: the
  reading-map section listed all six maps against a limit of two. These build
  the same bundle both ways, so the lane checks both whichever way it runs.

  They read this repository's reading maps and glossary, not the pack's
  (`Noetic.Harness.Pack` has none): the sections are the ones an agent here
  gets, as `ContextTest`'s `this_repository` tests are.
  """

  # async: false: these tests set and unset the HARNESS_AGENT environment
  # variable, which is process-global, and every async test that builds a
  # bundle without `:profile` would read it.
  use ExUnit.Case, async: false

  # This repository's reading maps and glossary, as the moduledoc says.
  @moduletag this_repository: true

  alias Noetic.Harness.Context

  setup do
    previous = System.get_env("HARNESS_AGENT")

    on_exit(fn ->
      if previous,
        do: System.put_env("HARNESS_AGENT", previous),
        else: System.delete_env("HARNESS_AGENT")
    end)

    :ok
  end

  defp section(bundle, key), do: Enum.find(bundle.sections, &(&1.key == key))

  defp budgeted do
    {:ok, bundle} =
      Context.build(%{title: "spectators, source of truth, journal, read model"},
        capabilities: ["elixir.ecto"],
        limit: 2
      )

    bundle
  end

  test "with HARNESS_AGENT unset, every section keeps the limit and declares its cut" do
    System.delete_env("HARNESS_AGENT")
    bundle = budgeted()

    for section <- bundle.sections do
      assert length(section.items) <= 2, "#{section.key} has #{length(section.items)} items"
    end

    maps = section(bundle, "reading_map")
    assert maps.why =~ "no HARNESS_AGENT"
    assert maps.truncated
    assert section(bundle, "terms").truncated
  end

  test "with HARNESS_AGENT set, every section keeps the limit and the map is the profile's" do
    System.put_env("HARNESS_AGENT", "memory")
    bundle = budgeted()

    for section <- bundle.sections do
      assert length(section.items) <= 2, "#{section.key} has #{length(section.items)} items"
    end

    assert [%{path: "docs/kb/reading-maps/memory.md"}] = section(bundle, "reading_map").items
  end

  test "an empty HARNESS_AGENT is no profile" do
    System.put_env("HARNESS_AGENT", "")

    assert section(budgeted(), "reading_map").why =~ "no HARNESS_AGENT"
  end
end
