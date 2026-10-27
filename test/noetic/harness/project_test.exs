defmodule Noetic.Harness.ProjectTest do
  @moduledoc """
  `.agents/registry/project.json`: what a repository tells the
  engine about itself, validated by `noetic-harness validate`, and read in place
  of the paths the engine used to name.

  Against a tree with none, which is a valid repository that configures
  nothing and is told so. And against a fixture whose sources are its own,
  which is the point of the change: a project's context is its data. This
  repository's own file is `ProjectRepositoryTest`'s.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Context, Fixture, Profiles, Project}

  # The pack's copy, read when the module compiles: the harness root is not
  # yet any test's, and a standalone checkout of the engine has no `.agents/`.
  @schema Noetic.Harness.Loader.load!(
            Path.join([Noetic.Harness.Pack.source(), "schemas", "project.schema.json"])
          )

  defp errors(findings), do: for({:error, message} <- findings, do: message)

  defp check(project), do: errors(Project.validate(project: project, schema: @schema))

  defp valid(extra), do: Map.merge(%{"version" => 1}, extra)

  describe "a repository without one" do
    test "is valid and configures nothing" do
      assert Project.validate(project: :absent) == []

      Fixture.with_tree(Fixture.minimal(), fn _root ->
        assert Project.get() == %{}
        assert Project.validate() == []
        assert Project.name() == nil
        assert Project.kb("glossary") == nil
        assert Project.context_source("adrs") == nil
        assert Project.adr_file_prefix(7) == nil
        assert Project.services() == []
      end)
    end

    test "is told what is not configured, not what is missing" do
      Fixture.with_tree(Fixture.minimal(), fn _root ->
        {:ok, bundle} =
          Context.build(%{title: "the spectators"},
            capabilities: ["elixir.implementation"],
            profile: "memory",
            kb: :cached
          )

        assert "terms (no kb.glossary in .agents/registry/project.json)" in bundle.unresolved

        assert "reading_map (no kb.reading_maps in .agents/registry/project.json)" in bundle.unresolved

        assert {:error, message} = Noetic.Harness.KB.index()
        assert message =~ "names no kb.extraction"
      end)
    end
  end

  describe "a project's context is its data" do
    test "a source declared in project.json is a section, named and explained as declared" do
      tree =
        Fixture.minimal()
        |> put_in(["registry/capabilities.json", "capabilities"], [
          %{
            "id" => "elixir.implementation",
            "doc" => "Write Elixir.",
            "skills" => [],
            "tools" => ["read"],
            "gates" => ["compile"],
            "evidence" => ["the commands you ran"],
            "context" => ["notes", "handbook"]
          }
        ])

      Fixture.with_tree(tree, fn root ->
        Fixture.write_project(root, %{
          "version" => 1,
          "context" => %{
            "notes" => %{
              "kind" => "files",
              "title" => "Team notes",
              "why" => "what this team writes down",
              "paths" => ["NOTES.md"]
            },
            "handbook" => %{"same_as" => "notes"}
          }
        })

        File.write!(Path.join(root, "NOTES.md"), "# Notes\n\nWrite it down.\n")

        {:ok, bundle} =
          Context.build(%{title: "anything"},
            capabilities: ["elixir.implementation"],
            kb: :cached
          )

        # `handbook` answers as `notes` does, under `notes`: an alias is named
        # for the source that answered, as `typeql_files` was `live_schema`.
        assert [notes, notes] = Enum.filter(bundle.sections, &(&1.key == "notes"))
        assert %{title: "Team notes", why: "what this team writes down"} = notes
        assert [%{path: "NOTES.md"}] = notes.items
        refute "notes" in bundle.unresolved
        refute "handbook" in bundle.unresolved
      end)
    end
  end

  describe "what reads it cannot be broken by it" do
    test "a malformed source is not attached, not a crash on the hook path" do
      Fixture.with_tree(Fixture.minimal(), fn root ->
        Fixture.write_project(root, %{
          "version" => 1,
          "context" => %{
            "no_paths" => %{"kind" => "files", "title" => "T", "why" => "W"},
            "absolute" => %{"kind" => "glob", "title" => "T", "why" => "W", "globs" => ["/etc/*"]},
            "fine" => %{"kind" => "files", "title" => "T", "why" => "W", "paths" => ["x.md"]}
          }
        })

        assert Project.context_source("no_paths") == nil
        assert Project.context_source("absolute") == nil
        assert %{"key" => "fine"} = Project.context_source("fine")
        assert Project.validate() != []
      end)
    end

    test "the kb index's fingerprint covers the project's kb section" do
      # Which files an index reads and how a recorded path resolves are the
      # project's now, so a cache built under other settings is not this one.
      Fixture.with_tree(Fixture.minimal(), fn root ->
        Fixture.write_project(root)
        before = IO.iodata_to_binary(Noetic.Harness.KB.Index.fingerprint())

        changed = put_in(Fixture.project(), ["kb", "source_roots"], ["_refdoc"])
        Fixture.write_project(root, changed)
        # `Loader.cached_load/1` memoises per process; a new request is a new
        # process, and this test is one process, so it forgets by hand.
        Process.delete({Noetic.Harness.Loader, :cache, Project.path()})

        refute IO.iodata_to_binary(Noetic.Harness.KB.Index.fingerprint()) == before
      end)
    end
  end

  describe "a malformed file is refused" do
    test "a key the schema does not know" do
      assert [message] = check(valid(%{"paths" => %{}}))
      assert message =~ "unexpected key paths"
    end

    test "an absolute path, a port out of range, a version that is not 1" do
      assert Enum.any?(
               check(valid(%{"kb" => %{"glossary" => "/etc/glossary.json"}})),
               &(&1 =~ "kb.glossary")
             )

      services = %{"probe" => [%{"name" => "pg", "port" => 70_000}], "start" => "up"}
      assert Enum.any?(check(valid(%{"services" => services})), &(&1 =~ "port"))
      assert Enum.any?(check(%{"version" => 2}), &(&1 =~ "version"))
    end

    test "a context source without its kind's fields, or of no kind" do
      files = %{"kind" => "files", "title" => "T", "why" => "W"}
      assert [message] = check(valid(%{"context" => %{"x" => files}}))
      assert message =~ "context.x: missing required key paths"

      glob = %{"kind" => "glob", "title" => "T", "why" => "W", "globs" => ["/abs/**"]}
      assert [message] = check(valid(%{"context" => %{"x" => glob}}))
      assert message =~ "context.x.globs: expected a non-empty list of paths relative to the root"

      assert [message] = check(valid(%{"context" => %{"x" => %{"kind" => "grep"}}}))
      assert message =~ ~s|kind "grep" is not one of|

      assert [message] = check(valid(%{"context" => %{"x" => %{"title" => "T"}}}))
      assert message =~ "a source has a kind"
    end

    test "a same_as that names nothing, or loops" do
      assert [message] = check(valid(%{"context" => %{"a" => %{"same_as" => "b"}}}))
      assert message =~ ~s|same_as "b" names no source, or a chain that loops|

      loop = %{"a" => %{"same_as" => "b"}, "b" => %{"same_as" => "a"}}
      assert length(check(valid(%{"context" => loop}))) == 2
    end

    test "every finding reaches validate's profiles check" do
      findings =
        Profiles.validate(doc: nil, project: [project: %{"version" => 2}, schema: @schema])

      assert Enum.any?(errors(findings), &String.starts_with?(&1, "project: "))
    end
  end
end
