defmodule Noetic.Harness.BriefTest do
  @moduledoc """
  The *Terms* section of a coordinator's brief: which glossary
  terms a brief's first line names, the section made of them, and the check
  that reports a brief without one or with a term the glossary lacks. Each
  test has a glossary of its own under `Fixture.with_tree/2`.
  """

  # async: true. The root is process-local (`Noetic.Harness.put_root/1`), and
  # every file written is under that root.
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Brief, Fixture}
  alias Noetic.Harness.KB.Glossary

  doctest Brief

  @glossary %{
    "terms" => [
      %{
        "id" => "term:spectators",
        "en" => "spectators",
        "ru" => "зрители",
        "status" => "decided",
        "definition" => "Those who watch an avatar's world without acting in it."
      },
      %{
        "id" => "term:harness",
        "en" => "harness (the development harness)",
        "ru" => "харнесс",
        "status" => "contested",
        "definition" => "A development organism, not an agent zoo."
      },
      %{
        "id" => "term:avatar-agent",
        "en" => "agent (of an avatar)",
        "ru" => "агент",
        "status" => "contested",
        "definition" => "An executable capability, not a personality."
      },
      %{
        "id" => "term:acme",
        "en" => "ACME",
        "ru" => "ACME",
        "status" => "proposed",
        "definition" => "The product's working name."
      },
      %{
        "id" => "term:path",
        "en" => "path (the road)",
        "ru" => "путь",
        "status" => "contested",
        "definition" => "The invariant carrier of transition."
      },
      %{
        "id" => "term:brief",
        "en" => "brief",
        "ru" => "бриф",
        "status" => "decided",
        "definition" => String.duplicate("A brief reads EPIC <id>. ", 20)
      }
    ]
  }

  defp with_glossary(fun) do
    Fixture.with_tree(Fixture.minimal(), fn root ->
      Fixture.write_project(root)
      File.mkdir_p!(Path.join(root, "docs/kb"))
      File.write!(Path.join(root, "docs/kb/glossary.json"), JSON.encode!(@glossary))

      try do
        fun.(root)
      after
        Glossary.forget(root)
      end
    end)
  end

  defp ids({:ok, terms, _truncated}), do: Enum.map(terms, & &1.id)

  describe "the terms a brief's first line names" do
    test "words name terms in either language and any inflection" do
      with_glossary(fn _ ->
        assert "term:spectators" in ids(Brief.terms("EPIC bd-1: what the зрителям see"))
        assert "term:brief" in ids(Brief.terms("EPIC bd-1: every brief gets a section"))
      end)
    end

    test "a path names its directory and file name, not a glob and not a dot-directory" do
      with_glossary(fn _ ->
        named = ids(Brief.terms("scope docs/design/harness.md, .agents/templates/**"))

        assert "term:harness" in named
        refute "term:avatar-agent" in named, "`.agents` named the avatar's agent"
      end)
    end

    test "an umbrella app's directory is code, not a word: acme_harness does not name ACME" do
      with_glossary(fn _ ->
        named =
          ids(Brief.terms("scope apps/acme_harness/lib/**, apps/acme/lib/acme/memory/**"))

        refute "term:acme" in named
        refute "term:harness" in named
      end)
    end

    test "-term:<id> leaves a term out, and its token names nothing" do
      with_glossary(fn _ ->
        text = "the MCP context path, for the spectators"
        assert "term:path" in ids(Brief.terms(text))

        named = ids(Brief.terms(text <> " -term:path -term:spectators"))
        refute "term:path" in named
        refute "term:spectators" in named

        assert "term:path" not in ids(Brief.terms(text, exclude: ["term:path"]))

        # The token's own words name nothing: `-term:harness-role` is not «harness».
        refute "term:harness" in ids(Brief.terms("the brief -term:harness-role"))
      end)
    end

    test "they are capped, and the cap is said" do
      with_glossary(fn _ ->
        assert {:ok, [_one], true} = Brief.terms("spectators and the harness", max: 1)
      end)
    end

    test "no glossary is an error of its own" do
      Fixture.with_tree(Fixture.minimal(), fn _ ->
        assert Brief.terms("spectators") == {:error, :absent}
      end)
    end
  end

  describe "the section" do
    test "names each term by id, with its names, status, a clipped definition and its link" do
      with_glossary(fn _ ->
        {:ok, terms, truncated} = Brief.terms("the brief for spectators")
        section = Brief.render(terms, truncated)

        assert String.starts_with?(section, "## Terms\n")
        assert section =~ "- `term:spectators` — **spectators** · зрители (decided): "
        assert section =~ "→ docs/kb/glossary.md#term-spectators"
        [brief_line] = section |> String.split("\n") |> Enum.filter(&(&1 =~ "term:brief"))
        assert brief_line =~ "…"
        assert String.length(brief_line) < 300
      end)
    end

    test "a scope that names nothing says so, and a cap says so" do
      assert Brief.render([]) =~ "- (the scope names no glossary term)"
      assert Brief.render([], true) =~ "most specific are kept"
    end

    test "what it generates passes its own check" do
      with_glossary(fn _ ->
        {:ok, terms, truncated} = Brief.terms("spectators, the harness and the brief")
        brief = "EPIC bd-1: branch claude/bd-1-x\n\n" <> Brief.render(terms, truncated)

        assert Brief.check(brief) == []
      end)
    end
  end

  describe "the check" do
    test "a brief without the section is reported" do
      with_glossary(fn _ ->
        assert [finding] = Brief.check("EPIC bd-1: branch claude/bd-1-x\n\n## The epic\n")
        assert finding =~ "no `## Terms` section"
      end)
    end

    test "a section that lists nothing is reported" do
      with_glossary(fn _ ->
        assert [finding] = Brief.check("## Terms\n\n<paste it here>\n\n## The epic\n- x\n")
        assert finding =~ "lists nothing"
      end)
    end

    test "a term the glossary does not have is reported, and a known one is not" do
      with_glossary(fn _ ->
        brief = """
        ## Terms

        - `term:spectators` — spectators
        - `term:audience-of-one` — made up
        """

        assert Brief.check(brief) == ["`term:audience-of-one` is not in docs/kb/glossary.json"]
      end)
    end

    test "a line with no id cannot be checked, so it is reported" do
      with_glossary(fn _ ->
        assert [finding] = Brief.check("## Terms\n\n- **spectators**: the audience\n")
        assert finding =~ "names no glossary id"
      end)
    end

    test "only the section is read: an id elsewhere in the brief is not its business" do
      with_glossary(fn _ ->
        brief = "## Terms\n\n- `term:brief` — brief\n\n## The epic\n\n- rename `term:gone`\n"
        assert Brief.check(brief) == []
      end)
    end
  end

  describe "reading a brief" do
    test "from a text file, or from a coordination record's `brief`, by a repository path" do
      with_glossary(fn root ->
        File.write!(Path.join(root, "brief.md"), "EPIC bd-1: x")

        File.write!(
          Path.join(root, "coord.json"),
          JSON.encode!(%{"id" => "coord-x", "brief" => "EPIC bd-2: y"})
        )

        File.write!(Path.join(root, "other.json"), JSON.encode!(%{"id" => "coord-y"}))

        assert Brief.read("brief.md") == {:ok, "EPIC bd-1: x"}
        assert Brief.read("coord.json") == {:ok, "EPIC bd-2: y"}
        assert {:error, message} = Brief.read("other.json")
        assert message =~ "no `brief` field"
        assert {:error, _} = Brief.read("missing.md")
      end)
    end
  end
end
