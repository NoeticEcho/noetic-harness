defmodule Noetic.Harness.ProjectionTest do
  @moduledoc """
  A projection is reproducible, says what it left out and how it
  cut, and its hash moves when any field of the state does.
  """

  use ExUnit.Case, async: true

  alias Noetic.Harness.Projection

  @work %{title: "the product channel crashes mid-ritual", body: nil, paths: ["a.ex"]}

  defp bundle(excerpt \\ "defmodule A do") do
    %{
      sections: [
        %{
          key: "adr",
          items: [%{path: "docs/decisions/DR-001.md", excerpt: excerpt, score: nil}],
          truncated: true
        }
      ],
      unresolved: ["typedb:schema"],
      memory: [%{"id" => "mem-1", "title" => "a lesson", "body" => "long body text"}],
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  test "the same state and version give the same hash, whenever it is built" do
    a = Projection.from_bundle(@work, bundle(), 8)
    b = Projection.from_bundle(@work, %{bundle() | generated_at: "2000-01-01T00:00:00Z"}, 8)
    assert a["hash"] == b["hash"]
    assert a["projection_version"] == Projection.version()
  end

  test "changing one field of the state changes the hash" do
    base = Projection.from_bundle(@work, bundle(), 8)["hash"]

    refute Projection.from_bundle(%{@work | title: "the product channel crashes"}, bundle(), 8)[
             "hash"
           ] ==
             base

    refute Projection.from_bundle(@work, bundle("defmodule B do"), 8)["hash"] == base
    refute Projection.from_bundle(%{@work | paths: ["b.ex"]}, bundle(), 8)["hash"] == base
  end

  test "what was left out is listed, and the cut names its method" do
    p = Projection.from_bundle(@work, bundle(), 8)
    what = Enum.map(p["excluded"], & &1["what"])

    assert "section typedb:schema" in what
    assert "items of adr past 8" in what
    assert "generated_at" in what
    assert p["truncation"] =~ "first 8 items by rank"
  end

  test "memory contributes its identity, not its body" do
    p = Projection.from_bundle(@work, bundle(), 8)
    refute inspect(p["state"]) =~ "long body text"
  end
end
