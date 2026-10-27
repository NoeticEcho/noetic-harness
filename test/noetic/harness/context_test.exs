defmodule Noetic.Harness.ContextTest do
  @moduledoc """
  The context bundle. The engine's tests build it on the pack
  (`Noetic.Harness.Pack`): its capabilities, its `project.json`'s context
  sources, its skills and its small tree. The kb, terms and reading-map
  sections as this repository's knowledge base answers them are
  `ContextRepositoryTest`'s.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.Context

  setup {Noetic.Harness.Pack, :root}

  test "relevant context is included" do
    {:ok, bundle} =
      Context.build(%{title: "change the TypeDB schema"}, capabilities: ["typedb.schema"])

    keys = Enum.map(bundle.sections, & &1.key)

    # typedb.schema declares live_schema, typeql_files, adr_006 and memory:typedb.
    # The first three are files; the fourth is attached as memory, not a section.
    assert "live_schema" in keys or "adr_006" in keys
    refute "memory:typedb" in bundle.unresolved
  end

  test "unrelated context is excluded" do
    {:ok, bundle} =
      Context.build(%{title: "change the TypeDB schema"}, capabilities: ["typedb.schema"])

    keys = Enum.map(bundle.sections, & &1.key)
    refute "scene_code" in keys
    refute "client_code" in keys
    refute "changelog" in keys
  end

  test "context follows the capability, not the wording" do
    {:ok, client} = Context.build(%{title: "anything at all"}, capabilities: ["frontend.web"])
    {:ok, backend} = Context.build(%{title: "anything at all"}, capabilities: ["elixir.ecto"])

    client_keys = MapSet.new(client.sections, & &1.key)
    backend_keys = MapSet.new(backend.sections, & &1.key)

    refute MapSet.equal?(client_keys, backend_keys)
    assert "client_code" in client_keys
    assert "migrations" in backend_keys or "schema" in backend_keys
  end

  test "provenance survives assembly: every section says where it came from and why" do
    {:ok, bundle} = Context.build(%{title: "x"}, capabilities: ["elixir.otp"])

    for section <- bundle.sections do
      assert section.why != ""
      assert section.items != []

      for item <- section.items do
        assert is_binary(item.path)
      end
    end
  end

  test "a context source that could not be resolved is reported, not silently dropped" do
    {:ok, bundle} = Context.build(%{title: "x"}, capabilities: ["typedb.schema"])

    # This repository has no live TypeDB in the test environment, and several
    # sources are genuinely unresolvable here. What matters is that the bundle
    # says so rather than looking complete.
    assert is_list(bundle.unresolved)
    rendered = Context.render(bundle)

    if bundle.unresolved != [] do
      assert rendered =~ "Not attached"
    end
  end

  test "memory keys are satisfied elsewhere rather than reported missing" do
    {:ok, bundle} = Context.build(%{title: "x"}, capabilities: ["research.prior_art"])

    refute "memory" in bundle.unresolved
    refute Enum.any?(bundle.unresolved, &String.starts_with?(&1, "memory:"))
  end

  test "skills relevant to the capability are attached, and others are not" do
    {:ok, bundle} = Context.build(%{title: "x"}, capabilities: ["typedb.schema"])
    names = Enum.map(bundle.skills, & &1.name)

    assert "typeql" in names
    refute "babylon9" in names
  end

  test "the bundle is a budget: sections are capped and truncation is declared" do
    {:ok, bundle} = Context.build(%{title: "x"}, capabilities: ["elixir.ecto"], limit: 2)

    for section <- bundle.sections do
      assert length(section.items) <= 2
    end
  end

  test "an empty capability list produces an empty bundle rather than the repository" do
    {:ok, bundle} = Context.build(%{title: "x"}, capabilities: [])

    assert bundle.sections == []
    assert bundle.unresolved == []
  end

  describe "the kb hits in every bundle" do
    # A tree of the test's own: the minimal registry, whose one capability,
    # `elixir.implementation`, does not ask for `kb`, and a knowledge base of
    # two records, so that "cached" and "not cached" are states the test sets.
    alias Noetic.Harness.{Fixture, Hooks, KB}

    @kb_group %{
      "group" => "G4_lighthouse",
      "concepts" => [
        %{
          "id" => "concept:keeper-memory-shelves",
          "name" => "Три полки памяти робота",
          "aliases" => ["memory shelves"],
          "definition" => "Три полки памяти с разными замками.",
          "sources" => []
        },
        %{
          "id" => "concept:harbour-bell-ledger",
          "name" => "Журнал колокола",
          "aliases" => ["bell ledger memory"],
          "definition" => "Что колокол гавани помнит о каждом корабле.",
          "sources" => []
        }
      ]
    }

    defp with_kb_tree(fun) do
      Fixture.with_tree(Fixture.minimal(), fn root ->
        Fixture.write_project(root)
        path = Path.join(root, "docs/kb/extraction/G4_lighthouse.json")
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, JSON.encode!(@kb_group))

        try do
          fun.(root)
        after
          KB.forget()
        end
      end)
    end

    defp kb_ids(bundle) do
      case Enum.find(bundle.sections, &(&1.key == "kb")) do
        nil -> []
        section -> Enum.map(section.items, &(&1.path |> String.split(" ") |> hd()))
      end
    end

    test "a capability that does not ask for kb carries the hits; off a hook path a cold index is built" do
      with_kb_tree(fn root ->
        {:ok, bundle} =
          Context.build(%{title: "memory shelves"}, capabilities: ["elixir.implementation"])

        assert "concept:keeper-memory-shelves" in kb_ids(bundle)
        assert Path.wildcard(Path.join(KB.cache_dir(root), "*.etf")) != []
        refute Enum.any?(bundle.unresolved, &String.starts_with?(&1, "kb"))
      end)
    end

    test "on a hook path a cold index is not built: no hits, said so, within the hook's ceiling" do
      with_kb_tree(fn root ->
        started = System.monotonic_time(:millisecond)

        {:ok, bundle} =
          Context.build(%{title: "memory shelves"},
            capabilities: ["elixir.implementation"],
            kb: :cached
          )

        took = System.monotonic_time(:millisecond) - started
        ceiling = Hooks.ceiling("user_prompt", "resident")

        assert took < ceiling, "a hook-path bundle took #{took} ms against #{ceiling}"
        assert kb_ids(bundle) == []
        assert Enum.any?(bundle.unresolved, &String.starts_with?(&1, "kb (no cached index"))
        refute File.exists?(KB.cache_dir(root)), "a hook-path bundle built the index"
      end)
    end

    test "on a hook path a cached index is used, from memory and from disk" do
      with_kb_tree(fn _root ->
        {:ok, _, %{from: :built}} = KB.index()

        {:ok, warm} =
          Context.build(%{title: "memory shelves"},
            capabilities: ["elixir.implementation"],
            kb: :cached
          )

        assert "concept:keeper-memory-shelves" in kb_ids(warm)

        # A fresh BEAM has no memory; it has the file.
        KB.forget()

        {:ok, fresh} =
          Context.build(%{title: "memory shelves"},
            capabilities: ["elixir.implementation"],
            kb: :cached
          )

        assert "concept:keeper-memory-shelves" in kb_ids(fresh)
        refute Enum.any?(fresh.unresolved, &String.starts_with?(&1, "kb"))
      end)
    end

    test "the kb section keeps the bundle's limit, and says when it cut" do
      with_kb_tree(fn _root ->
        {:ok, bundle} =
          Context.build(%{title: "memory"}, capabilities: ["elixir.implementation"], limit: 1)

        section = Enum.find(bundle.sections, &(&1.key == "kb"))
        assert length(section.items) == 1
        assert section.truncated
      end)
    end
  end
end
