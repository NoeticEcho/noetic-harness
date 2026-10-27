defmodule Noetic.Harness.KB.GlossaryTest do
  @moduledoc """
  The glossary as the harness reads it: which terms a piece of
  work names, and where a term's entry is.
  """

  use ExUnit.Case, async: true

  alias Noetic.Harness.KB.Glossary

  # Where the glossary is, the pack's project says (`Noetic.Harness.Pack`):
  # each fixture below writes one there. It used to be this repository's
  # `kb.glossary`.
  @moduletag pack_project: %{
               "kb" => %{
                 "glossary" => "kb/glossary.json",
                 "glossary_markdown" => "kb/glossary.md"
               }
             }
  setup {Noetic.Harness.Pack, :root}

  doctest Noetic.Harness.KB.Glossary

  @terms [
    %{
      "id" => "term:spectators",
      "en" => "spectators",
      "ru" => "зрители",
      "aliases" => ["audience"],
      "status" => "decided",
      "definition" => "The people who watch an avatar's live broadcast."
    },
    %{
      "id" => "term:source-of-truth",
      "en" => "source of truth",
      "ru" => "источник истины",
      "aliases" => [],
      "status" => "contested",
      "definition" => "One subsystem owns each kind of state."
    },
    %{
      "id" => "term:call",
      "en" => "`call` (world function)",
      "ru" => "вызов",
      "aliases" => [],
      "status" => "decided",
      "definition" => "A world function."
    },
    %{
      "id" => "term:ai",
      "en" => "AI",
      "ru" => "ИИ",
      "aliases" => [],
      "status" => "proposed",
      "definition" => "Too short to match."
    }
  ]

  defp with_glossary(terms, fun) do
    root = Noetic.Harness.TestTmp.path("glossary")
    path = Path.join(root, Glossary.path())
    File.mkdir_p!(Path.dirname(path))
    if terms, do: File.write!(path, JSON.encode!(%{"about" => "test", "terms" => terms}))

    try do
      fun.(root)
    after
      Glossary.forget(root)
      File.rm_rf!(root)
    end
  end

  defp ids(named), do: Enum.map(named, fn {term, _key} -> term.id end)

  test "an English and a Russian title name the same terms, inflection and all" do
    with_glossary(@terms, fn root ->
      {:ok, terms} = Glossary.terms(root)

      assert ids(Glossary.named_in(terms, "Show the sources of truth to the spectators")) ==
               ["term:source-of-truth", "term:spectators"]

      assert ids(Glossary.named_in(terms, "показать зрителям источники истины")) ==
               ["term:source-of-truth", "term:spectators"]
    end)
  end

  test "a name is matched as whole words, and its parenthetical is not part of it" do
    with_glossary(@terms, fn root ->
      {:ok, terms} = Glossary.terms(root)

      assert ids(Glossary.named_in(terms, "the call returns")) == ["term:call"]
      assert ids(Glossary.named_in(terms, "recall the product function")) == []
      assert ids(Glossary.named_in(terms, "the audience")) == ["term:spectators"]
    end)
  end

  test "a name shorter than three letters never matches" do
    with_glossary(@terms, fn root ->
      {:ok, terms} = Glossary.terms(root)
      assert ids(Glossary.named_in(terms, "AI and ИИ")) == []
    end)
  end

  test "the most specific term comes first: the longest name" do
    with_glossary(@terms, fn root ->
      {:ok, terms} = Glossary.terms(root)

      assert [{%{id: "term:source-of-truth"}, ["sourc", "truth"]} | _] =
               Glossary.named_in(terms, "spectators and the source of truth")
    end)
  end

  test "a term carries its status and its link into the rendered glossary" do
    with_glossary(@terms, fn root ->
      {:ok, terms} = Glossary.terms(root)
      term = Enum.find(terms, &(&1.id == "term:source-of-truth"))

      assert term.status == "contested"
      assert term.link == "kb/glossary.md#term-source-of-truth"
    end)
  end

  test "no glossary is an answer, not a crash" do
    with_glossary(nil, fn root ->
      assert Glossary.terms(root) == {:error, :absent}
    end)
  end

  test "an edit to the glossary is seen, the cache notwithstanding" do
    with_glossary(@terms, fn root ->
      {:ok, before} = Glossary.terms(root)
      assert length(before) == 4

      path = Path.join(root, Glossary.path())
      File.write!(path, JSON.encode!(%{"terms" => Enum.take(@terms, 1)}))
      File.touch!(path, System.os_time(:second) + 5)

      assert {:ok, [_one]} = Glossary.terms(root)
    end)
  end
end
