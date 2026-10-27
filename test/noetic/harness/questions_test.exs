defmodule Noetic.Harness.QuestionsTest do
  @moduledoc """
  A question edited without a new version is a validate error,
  and `--bump` is how an edit becomes one.
  """

  use ExUnit.Case, async: true

  alias Noetic.Harness.{Fixture, Questions, Validation}

  @question %{
    "id" => "q.test",
    "version" => "1",
    "type" => "choice",
    "instructions" => "Which?",
    "options" => ["a", "b"],
    "criteria" => %{"a" => "the first", "b" => "the second"},
    "versions" => []
  }

  defp recorded(q) do
    Map.put(q, "versions", [
      %{
        "version" => "1",
        "fingerprint" => Questions.fingerprint(q),
        "at" => "2026-09-23",
        "why" => "first"
      }
    ])
  end

  @tag this_repository: true
  test "the repository's questions all match their current version" do
    assert Questions.list() != []
    assert Questions.check() == []
  end

  test "the fingerprint ignores key order and sees every content field" do
    q = @question
    reordered = q |> Enum.reverse() |> Map.new()
    assert Questions.fingerprint(q) == Questions.fingerprint(reordered)

    for {field, value} <- [
          {"instructions", "Which one?"},
          {"options", ["a", "c"]},
          {"criteria", %{"a" => "the first", "b" => "changed"}},
          {"type", "score"}
        ] do
      refute Questions.fingerprint(Map.put(q, field, value)) == Questions.fingerprint(q), field
    end

    assert Questions.fingerprint(Map.put(q, "note", "prose")) == Questions.fingerprint(q)
  end

  test "an edit without a bump is an error; the bump records a new version and keeps the old" do
    edited = recorded(@question) |> Map.put("instructions", "Which, really?")
    tree = Map.put(Fixture.minimal(), "decisions/questions/q.test.json", edited)

    Fixture.with_tree(tree, fn _root ->
      assert [{:error, message}] = Questions.check()
      assert message =~ "edited without a new version"

      {:ok, findings} = Validation.run([:questions])
      assert Enum.any?(findings, &match?({:error, _}, &1))

      assert {:ok, "2"} = Questions.bump("q.test", "clarified the instruction")
      assert Questions.check() == []

      [q] = Questions.list()
      assert Enum.map(q["versions"], & &1["version"]) == ["1", "2"]
      assert {:error, _} = Questions.bump("q.test", "again")
    end)
  end
end
