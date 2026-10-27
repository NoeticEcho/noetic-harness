defmodule Noetic.Harness.KBTest do
  @moduledoc """
  The knowledge base, asked from the files.

  Each test builds a small `docs/kb/extraction/` under a root of its own, so
  that what it asserts is what the index does with records it knows, not
  what today's extraction happens to contain. One test at the end runs
  against the repository's real extraction, because an index that works on a
  fixture and not on the corpus is not the thing anybody asked for.
  """

  use ExUnit.Case, async: true

  alias Noetic.Harness.KB
  alias Noetic.Harness.KB.{Index, Text}

  doctest Noetic.Harness.KB.Text

  @group %{
    "group" => "G4_lighthouse",
    "documents" => [
      %{
        "id" => "doc:keeper-log",
        "path" => "/srv/checkout/_refdoc/keeper_log.md",
        "title" => "Журнал смотрителя",
        "summary" => "Что помнит робот-смотритель.",
        "key_terms" => ["память"]
      },
      %{
        "id" => "doc:scene",
        "path" => "/tmp/claude-0/-srv-checkout/abc/scratchpad/ref/pack_one/pack_one/src/scene.ts",
        "title" => "scene.ts",
        "summary" => "The scene."
      },
      %{
        "id" => "doc:lexer",
        "path" => "/tmp/na/acme-engine/src/parser/lexer.ts",
        "title" => "lexer.ts",
        "summary" => "A lexer."
      },
      %{
        "id" => "doc:lost",
        "path" => "/tmp/somewhere/else/lost.md",
        "title" => "lost.md",
        "summary" => "Nobody kept it."
      }
    ],
    "concepts" => [
      %{
        "id" => "concept:keeper-memory-shelves",
        "name" => "Три полки памяти робота",
        "aliases" => ["memory shelves"],
        "domain" => "agent",
        "definition" => "Три полки памяти с разными замками: утренняя, вечерняя, штормовая.",
        "attributes" => %{"count" => 3},
        "sources" => ["doc:keeper-log"]
      },
      %{
        "id" => "concept:paper-lantern",
        "name" => "Бумажный фонарь",
        "aliases" => ["paper lantern"],
        "domain" => "craft",
        "definition" => "Фонарь из бумаги на бамбуковом каркасе.",
        "attributes" => %{},
        "sources" => ["doc:scene", "doc:lexer", "doc:lost"]
      }
    ],
    "requirements" => [
      %{
        "id" => "req:lighthouse-nine-lights",
        "text" => "Память каждого маяка хранит девять огней.",
        "kind" => "data",
        "priority" => "must",
        "component" => "agent",
        "sources" => ["doc:keeper-log"]
      }
    ],
    "relations" => [
      %{
        "from" => "concept:keeper-memory-shelves",
        "type" => "part_of",
        "to" => "concept:keeper",
        "note" => "нижний ярус",
        "sources" => ["doc:keeper-log"]
      }
    ]
  }

  @other %{
    "group" => "G3_craft",
    "concepts" => [
      %{
        "id" => "concept:paper-lantern",
        "name" => "Фонарь",
        "aliases" => [],
        "domain" => "craft",
        "definition" => "Тот же фонарь, извлечённый второй раз.",
        "attributes" => %{},
        "sources" => []
      }
    ],
    "visual_directives" => [
      %{"id" => "vis:lantern-sway", "text" => "The lantern sways on the z axis.", "sources" => []}
    ]
  }

  @refdoc [
    "_refdoc/keeper_log.md",
    "_refdoc/pack_one/src/scene.ts",
    "_refdoc/extra/pack_one/src/scene.ts",
    "_refdoc/acme_avatar/acme-engine.tar.gz"
  ]

  defp with_kb(groups, fun) do
    root = Noetic.Harness.TestTmp.path("kb-test") |> Noetic.Harness.Fixture.write_project()

    for {name, data} <- groups, do: write_group(root, name, data)

    for path <- @refdoc do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), "x")
    end

    previous = Noetic.Harness.put_root(root)

    try do
      fun.(root)
    after
      KB.forget()

      if previous,
        do: Noetic.Harness.put_root(previous),
        else: Noetic.Harness.delete_root()

      File.rm_rf!(root)
    end
  end

  defp write_group(root, name, data) do
    path = Path.join([root, "docs/kb/extraction", "#{name}.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(data))
  end

  defp ids(result), do: Enum.map(result.hits, & &1.id)

  # A port nothing listens on: bound, read, closed.
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  describe "the words" do
    test "Russian inflections fold to one stem, and ё to е" do
      assert Text.terms("памяти") == Text.terms("память")
      assert Text.terms("памятью") == Text.terms("память")
      assert Text.terms("роботов") == Text.terms("робота")
      assert Text.terms("ещё") == Text.terms("еще")
    end

    test "English plurals fold, and a noun ending in -et is not a verb" do
      assert Text.terms("memories") == Text.terms("memory")
      assert Text.terms("agents") == Text.terms("agent")
      assert Text.terms("бюджет") == ["бюджет"]
    end

    test "punctuation, dashes and guillemets separate words; one letter is not a word" do
      assert Text.words("«Фонарь»—бумага… x y") == ["фонарь", "бумага"]
    end

    test "a snippet is cut on characters and centred on the match" do
      text = String.duplicate("слово ", 100) <> "роботов " <> String.duplicate("слово ", 100)
      snippet = Text.snippet(text, ["робот"], 60)

      assert String.valid?(snippet)
      assert snippet =~ "роботов"
      assert String.starts_with?(snippet, "…")
      assert String.ends_with?(snippet, "…")
    end
  end

  describe "a query" do
    test "in Russian finds a Russian record, by an inflected form it never uses" do
      with_kb(%{"G4_lighthouse" => @group}, fn _root ->
        # The records say «памяти» and «Память»; the query says «памятью».
        assert {:ok, result} = KB.query("памятью роботов", probe: false)
        assert hd(result.hits).id == "concept:keeper-memory-shelves"
        assert hd(result.hits).group == "G4"
        assert hd(result.hits).group_name == "G4_lighthouse"
        assert hd(result.hits).matched =~ "Три полки памяти"
        assert result.backend == "files"
      end)
    end

    test "in English finds a Russian record through its alias and its id" do
      with_kb(%{"G4_lighthouse" => @group}, fn _root ->
        assert {:ok, result} = KB.query("memory shelves", probe: false)
        assert "concept:keeper-memory-shelves" in ids(result)

        assert {:ok, result} = KB.query("nine lights", probe: false)
        assert ids(result) == ["req:lighthouse-nine-lights"]
      end)
    end

    test "a hit carries its id, group, kind, matched text and sources" do
      with_kb(%{"G4_lighthouse" => @group}, fn _root ->
        {:ok, %{hits: [hit | _]}} = KB.query("девять огней", probe: false)

        assert hit.id == "req:lighthouse-nine-lights"
        assert hit.kind == "requirement"
        assert hit.field == "statement"
        assert hit.matched =~ "девять огней"
        assert hit.sources == [%{path: "_refdoc/keeper_log.md", resolved: true}]
      end)
    end

    test "a query that is an id puts that record first" do
      with_kb(%{"G4_lighthouse" => @group}, fn _root ->
        {:ok, result} = KB.query("req:lighthouse-nine-lights", probe: false)
        assert hd(ids(result)) == "req:lighthouse-nine-lights"
      end)
    end

    test "--group and --kind narrow it, and an unknown one says what exists" do
      with_kb(%{"G4_lighthouse" => @group, "G3_craft" => @other}, fn _root ->
        {:ok, all} = KB.query("lantern", probe: false)
        {:ok, g3} = KB.query("lantern", group: "g3", probe: false)
        {:ok, directives} = KB.query("lantern", kind: "visual_directives", probe: false)

        assert "vis:lantern-sway" in ids(all)
        assert Enum.all?(g3.hits, &(&1.group == "G3"))
        assert ids(directives) == ["vis:lantern-sway"]

        assert {:error, message} = KB.query("lantern", group: "G99", probe: false)
        assert message =~ "G3" and message =~ "G4"
        assert {:error, message} = KB.query("lantern", kind: "poem", probe: false)
        assert message =~ "concept"
      end)
    end

    test "the same id from two groups is one hit, and says where else it was" do
      with_kb(%{"G4_lighthouse" => @group, "G3_craft" => @other}, fn _root ->
        {:ok, result} = KB.query("фонарь", probe: false)

        assert Enum.count(result.hits, &(&1.id == "concept:paper-lantern")) == 1
        hit = Enum.find(result.hits, &(&1.id == "concept:paper-lantern"))
        assert hit.also_in != []
      end)
    end

    test "an empty query is refused with a sentence" do
      with_kb(%{"G4_lighthouse" => @group}, fn _root ->
        assert {:error, message} = KB.query("  ", probe: false)
        assert message =~ "a query is needed"
      end)
    end

    test "no extraction is an error that says where it looked" do
      with_kb(%{}, fn root ->
        assert {:error, message} = KB.query("память", probe: false)
        assert message =~ Path.join(root, "docs/kb/extraction")
      end)
    end
  end

  describe "sources" do
    test "resolve to _refdoc, to the shallowest copy, into an archive, or stay as recorded" do
      with_kb(%{"G4_lighthouse" => @group}, fn _root ->
        {:ok, %{hits: [hit | _]}} = KB.query("paper lantern", probe: false)

        assert hit.id == "concept:paper-lantern"

        assert hit.sources == [
                 # Two copies of the pack; the top-level one.
                 %{path: "_refdoc/pack_one/src/scene.ts", resolved: true},
                 # Read from an unpacked archive the corpus keeps.
                 %{
                   path: "_refdoc/acme_avatar/acme-engine.tar.gz",
                   resolved: true,
                   member: "src/parser/lexer.ts"
                 },
                 # Nothing here holds it: the path as the extraction wrote it.
                 %{path: "/tmp/somewhere/else/lost.md", resolved: false}
               ]
      end)
    end
  end

  describe "the index" do
    test "is built once, then served from memory, then from disk, and rebuilt on change" do
      with_kb(%{"G4_lighthouse" => @group}, fn root ->
        assert {:ok, first, %{from: :built, hash: hash}} = KB.index()
        assert {:ok, _, %{from: :memory, hash: ^hash}} = KB.index()

        # A fresh BEAM has no memory; it has the file.
        KB.forget()
        assert {:ok, _, %{from: :disk, hash: ^hash}} = KB.index()
        assert File.exists?(Path.join(KB.cache_dir(root), "#{hash}.etf"))

        # An edit is a new hash and a rebuild, whatever the mtime says.
        changed = put_in(@group, ["requirements"], [])
        write_group(root, "G4_lighthouse", changed)

        assert {:ok, second, %{from: :built, hash: new_hash}} = KB.index()
        refute new_hash == hash
        assert tuple_size(second.records) == tuple_size(first.records) - 1

        # The directory holds one index, not a history.
        assert Path.wildcard(Path.join(KB.cache_dir(root), "*.etf")) ==
                 [Path.join(KB.cache_dir(root), "#{new_hash}.etf")]

        # And a new group file is a new hash too.
        write_group(root, "G3_craft", @other)
        assert {:ok, _, %{from: :built, files: 2}} = KB.index()
      end)
    end

    test "a fresh BEAM takes the hash from the stat manifest while no file has changed" do
      with_kb(%{"G4_lighthouse" => @group}, fn root ->
        {:ok, _, %{hash: hash}} = KB.index()
        manifest = Path.join(KB.cache_dir(root), "stat.manifest")
        assert File.exists?(manifest)

        # Proof that it is read, not only written: a hash no file has, planted
        # in it, is the hash a fresh BEAM uses.
        planted =
          manifest |> File.read!() |> :erlang.binary_to_term() |> Map.put(:hash, "planted")

        File.write!(manifest, :erlang.term_to_binary(planted))
        KB.forget()
        assert {:ok, _, %{hash: "planted"}} = KB.index()

        # A file whose mtime moved is hashed again.
        KB.forget()
        file = Path.join(root, hd(Index.source_files(root)))
        File.touch!(file, System.os_time(:second) + 60)
        assert {:ok, _, %{hash: ^hash}} = KB.index()
      end)
    end

    test "a stat manifest written by other code is not trusted" do
      with_kb(%{"G4_lighthouse" => @group}, fn root ->
        {:ok, _, %{hash: hash}} = KB.index()
        manifest = Path.join(KB.cache_dir(root), "stat.manifest")

        stale =
          manifest
          |> File.read!()
          |> :erlang.binary_to_term()
          |> Map.merge(%{fingerprint: "v2", hash: "planted"})

        File.write!(manifest, :erlang.term_to_binary(stale))
        KB.forget()
        assert {:ok, _, %{hash: ^hash, from: :disk}} = KB.index()

        File.write!(manifest, "not a term")
        KB.forget()
        assert {:ok, _, %{hash: ^hash, from: :disk}} = KB.index()
      end)
    end

    test "packed postings are exact, and a record decodes to what was indexed" do
      with_kb(%{"G4_lighthouse" => @group}, fn _root ->
        {:ok, index, _} = KB.index()

        for n <- 0..(Index.size(index) - 1) do
          record = Index.record(index, n)
          assert Index.meta(index, n) == {record.id, record.kind, record.group, record.group_name}

          expected =
            [title: 3.0, statement: 1.0, attributes: 0.5]
            |> Enum.flat_map(fn {field, w} -> Enum.map(Text.terms(record[field]), &{&1, w}) end)
            |> Enum.reduce(%{}, fn {term, w}, acc -> Map.update(acc, term, w, &(&1 + w)) end)

          for {term, tf} <- expected do
            {_df, found} =
              Index.reduce_postings(index, term, nil, fn m, got, acc ->
                if m == n, do: got, else: acc
              end)

            assert found == tf, "#{record.id}: #{term} is #{inspect(found)}, not #{tf}"
          end
        end
      end)
    end

    test "cached-only never builds: not cached is an error of its own, and nothing is written" do
      with_kb(%{"G4_lighthouse" => @group}, fn root ->
        assert KB.index(cached: true) == {:error, :not_cached}
        assert KB.query("память", cached: true, probe: false) == {:error, :not_cached}
        refute File.exists?(KB.cache_dir(root))

        {:ok, _, %{from: :built, hash: hash}} = KB.index()
        assert {:ok, _, %{from: :memory, hash: ^hash}} = KB.index(cached: true)

        KB.forget()
        assert {:ok, _, %{from: :disk, hash: ^hash}} = KB.index(cached: true)
        assert {:ok, %{hits: [_ | _]}} = KB.query("память", cached: true, probe: false)
      end)
    end

    test "cached-only with the stat manifest gone still finds the disk cache by its hash" do
      with_kb(%{"G4_lighthouse" => @group}, fn root ->
        {:ok, _, %{hash: hash}} = KB.index()
        File.rm!(Path.join(KB.cache_dir(root), "stat.manifest"))
        KB.forget()

        assert {:ok, _, %{from: :disk, hash: ^hash}} = KB.index(cached: true)
      end)
    end

    test "a cache file that is not an index is a miss, not a failure" do
      with_kb(%{"G4_lighthouse" => @group}, fn root ->
        {:ok, _, %{hash: hash}} = KB.index()
        KB.forget()
        File.write!(Path.join(KB.cache_dir(root), "#{hash}.etf"), "not a term")

        assert {:ok, _, %{from: :built}} = KB.index()
      end)
    end

    test "a cache file is trusted only for the hash it holds, not the name it has" do
      with_kb(%{"G4_lighthouse" => @group}, fn root ->
        {:ok, _, %{hash: old}} = KB.index()

        write_group(root, "G4_lighthouse", put_in(@group, ["requirements"], []))
        new = Index.content_hash(root, Index.source_files(root))

        # The old index under the new name: a copy, a clock skew, a bad merge.
        File.cp!(
          Path.join(KB.cache_dir(root), "#{old}.etf"),
          Path.join(KB.cache_dir(root), "#{new}.etf")
        )

        KB.forget()
        assert {:ok, index, %{from: :built, hash: ^new}} = KB.index()
        refute Map.has_key?(index.ids, "req:lighthouse-nine-lights")
      end)
    end

    test "the hash covers the files' paths and bytes" do
      with_kb(%{"G4_lighthouse" => @group}, fn root ->
        files = Index.source_files(root)
        hash = Index.content_hash(root, files)

        assert hash == Index.content_hash(root, files)
        File.write!(Path.join(root, hd(files)), JSON.encode!(@other))
        refute hash == Index.content_hash(root, files)
      end)
    end
  end

  describe "the stores" do
    test "absent knowledge store and Qdrant degrade to files, and the answer says so" do
      with_kb(%{"G4_lighthouse" => @group}, fn _root ->
        addresses = [postgres: {"127.0.0.1", closed_port()}, qdrant: {"127.0.0.1", closed_port()}]

        {:ok, bare} = KB.query("память", probe: false)
        {:ok, result} = KB.query("память", probe: addresses)

        assert result.backend == "files"
        assert ids(result) == ids(bare)
        assert [%{name: "postgres", up: false}, %{name: "qdrant", up: false}] = result.backends
        assert Enum.all?(result.backends, &(&1.note =~ "not reachable" and &1.note =~ "files"))
      end)
    end

    test "a store that is up is reported up and not queried, and files still answer" do
      with_kb(%{"G4_lighthouse" => @group}, fn _root ->
        {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
        {:ok, port} = :inet.port(socket)

        try do
          {:ok, result} =
            KB.query("память",
              probe: [postgres: {"127.0.0.1", closed_port()}, qdrant: {"127.0.0.1", port}]
            )

          assert result.backend == "files"
          assert %{up: true, note: note} = Enum.find(result.backends, &(&1.name == "qdrant"))
          assert note =~ "does not query it yet"
        after
          :gen_tcp.close(socket)
        end
      end)
    end
  end

  describe "a glossary term" do
    @glossary %{
      "about" => "test",
      "terms" => [
        %{
          "id" => "term:spectators",
          "en" => "spectators",
          "ru" => "зрители",
          "aliases" => ["audience"],
          "domain" => "broadcast",
          "status" => "decided",
          "definition" => "The people who watch an avatar's live broadcast.",
          "in_repo" => "Not built.",
          "sources" => ["_refdoc/keeper_log.md"]
        }
      ]
    }

    # A corpus concept that says «зрители» more often, in a shorter record,
    # than the term does: what outranked `term:spectators` before.
    @viewers %{
      "group" => "G5_audience",
      "concepts" => [
        %{
          "id" => "concept:viewer-ladder",
          "name" => "Лестница зрителей · зрители · зритель",
          "aliases" => ["зрители"],
          "definition" => "Зрители поднимаются по лестнице: зрители, зрители, зрители.",
          "sources" => []
        }
      ]
    }

    defp with_glossary(fun) do
      with_kb(%{"G5_audience" => @viewers}, fn root ->
        File.write!(Path.join(root, "docs/kb/glossary.json"), JSON.encode!(@glossary))
        fun.(root)
      end)
    end

    test "a query that is its name ranks it first, in either language and inflection" do
      with_glossary(fn _root ->
        for query <- ["зрители", "зрителям", "Spectators", "audience"] do
          {:ok, result} = KB.query(query, probe: false)
          assert hd(result.hits).id == "term:spectators", "#{query}: #{inspect(ids(result))}"
        end
      end)
    end

    test "without the exact name, ranking is BM25's, and the concept can win" do
      with_glossary(fn _root ->
        {:ok, result} = KB.query("лестница зрителей", probe: false)
        assert hd(result.hits).id == "concept:viewer-ladder"
      end)
    end

    test "a term hit carries its names, its status and its link" do
      with_glossary(fn _root ->
        {:ok, %{hits: [hit | _]}} = KB.query("зрители", probe: false)

        assert hit.kind == "term"
        assert hit.group == "glossary"
        assert hit.title == "spectators · зрители (decided)"
        assert hit.status == "decided"
        assert hit.link == "docs/kb/glossary.md#term-spectators"
        assert hit.matched =~ "live broadcast"
      end)
    end

    test "an id still ranks above a name" do
      with_glossary(fn _root ->
        {:ok, result} = KB.query("concept:viewer-ladder", probe: false)
        assert hd(result.hits).id == "concept:viewer-ladder"
      end)
    end
  end
end
