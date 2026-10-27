defmodule Noetic.Harness.MemoryTest do
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Fixture, Memory}

  defp record(attrs \\ %{}) do
    Memory.append(
      Map.merge(
        %{
          kind: "lesson",
          title: "typeql-check catches what ExUnit structurally cannot",
          body: "A compiler emitting invalid TypeQL passes every test about its AST.",
          scope: ["typedb", "gsl"],
          confidence: "observed"
        },
        attrs
      )
    )
  end

  test "a record is written with provenance and confidence" do
    Fixture.with_tree(Fixture.minimal(), fn _root ->
      {:ok, _path} = record()
      [stored] = Memory.list()

      assert stored["confidence"] == "observed"
      assert stored["provenance"]["source"] == "run"
      assert stored["status"] == "current"
      assert stored["version"] == 1
    end)
  end

  test "required fields are required" do
    Fixture.with_tree(Fixture.minimal(), fn _root ->
      assert {:error, message} = Memory.append(%{kind: "lesson", title: "x"})
      assert message =~ "missing required fields"
    end)
  end

  test "confidence is a closed vocabulary, because it carries meaning" do
    Fixture.with_tree(Fixture.minimal(), fn _root ->
      assert {:error, message} = record(%{confidence: "pretty sure"})
      assert message =~ "observed"
    end)
  end

  test "the store is append-only: a second write to the same id is refused" do
    Fixture.with_tree(Fixture.minimal(), fn _root ->
      {:ok, _} = record()
      assert {:error, message} = record()
      assert message =~ "append-only"
    end)
  end

  test "retiring keeps the body and records why" do
    Fixture.with_tree(Fixture.minimal(), fn _root ->
      {:ok, _} = record()
      [%{"id" => id, "body" => body}] = Memory.list()

      {:ok, _} = Memory.retire(id, "typeql-check is now in the gate lane", nil)

      assert Memory.list() == []
      [retired] = Memory.list(all: true)

      assert retired["status"] == "retired"
      assert retired["body"] == body
      assert retired["retired_reason"] =~ "gate lane"
    end)
  end

  test "relevance prefers a declared scope over an incidental mention" do
    Fixture.with_tree(Fixture.minimal(), fn _root ->
      {:ok, _} = record()

      {:ok, _} =
        record(%{
          title: "a note that merely mentions typedb",
          scope: ["visual"],
          body: "Something about typedb in passing."
        })

      [first | _] = Memory.relevant(["typedb"])
      assert "typedb" in first["scope"]
    end)
  end

  test "a dangling supersession and a reasonless retirement are validation failures" do
    Fixture.with_tree(Fixture.minimal(), fn _root ->
      {:ok, _} = record()
      [%{"id" => id}] = Memory.list()
      {:ok, _} = Memory.retire(id, "replaced", "mem-2099-01-01-does-not-exist")

      problems = Memory.validate()
      assert Enum.any?(problems, &(&1 =~ "does not exist"))
    end)
  end
end
