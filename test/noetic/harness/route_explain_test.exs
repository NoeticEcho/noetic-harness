defmodule Noetic.Harness.RouteExplainTest do
  @moduledoc """
  The numbers the router computes are returned and printed, not
  used and discarded. Nobody knows how often the router is wrong, and a route
  whose score, kind and runner-up are invisible cannot even be argued with.
  """

  # `Mix.shell/1` is VM-global: the --explain test swaps it for
  # `Mix.Shell.Process`, and a concurrent test printing through the shared
  # shell would send its lines to this process's mailbox.
  use ExUnit.Case, async: false

  alias Noetic.Harness.Router

  # The router's mechanism, on the pack's signals rather than this
  # repository's (`Noetic.Harness.Pack`).
  setup {Noetic.Harness.Pack, :root}

  @title "the product channel crashes mid-ritual"

  test "the route carries its confidence score, the thresholds, the kind and every candidate" do
    {:ok, signals} =
      Noetic.Harness.Loader.load(
        Path.join(Noetic.Harness.agents_path("registry"), "signals.json")
      )

    {:ok, route} = Router.route(title: @title)

    assert route.confidence_thresholds == %{
             high: signals["confidence"]["high"],
             medium: signals["confidence"]["medium"]
           }

    assert is_integer(route.confidence_score) and route.confidence_score > 0
    assert route.kind == %{value: "bug", source: :inferred}

    [winner, runner_up | _] = route.candidates
    assert winner.id == route.workflow["id"]
    assert winner.total == winner.family + winner.kind + winner.keyword + winner.capability
    assert winner.total >= runner_up.total

    {:ok, declared} = Router.route(title: @title, kind: "feature")
    assert declared.kind == %{value: "feature", source: :declared}
  end

  test "a named workflow has no candidates, because nothing was scored" do
    {:ok, route} = Router.route(title: @title, workflow: "WF-002")
    assert route.candidates == []
  end

  test "--explain names the runner-up and its score" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    {:ok, route} = Router.route(title: @title)
    [_winner, runner_up | _] = route.candidates

    Mix.Task.rerun("harness.route", ["--title", @title, "--explain"])

    lines = collect([])

    assert Enum.any?(lines, &(&1 =~ "runner-up     #{runner_up.id} at #{runner_up.total}")),
           "no runner-up line in:\n#{Enum.join(lines, "\n")}"

    assert Enum.any?(
             lines,
             &(&1 =~ ~r/score #{route.confidence_score}, high at \d+, medium at \d+/)
           )

    assert Enum.any?(lines, &(&1 =~ "kind          bug (inferred"))
  end

  defp collect(acc) do
    receive do
      {:mix_shell, :info, [line]} -> collect([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
