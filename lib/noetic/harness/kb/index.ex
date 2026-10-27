defmodule Noetic.Harness.KB.Index do
  @moduledoc """
  The knowledge base as an inverted index, built from the files alone.

  ## What goes in

  Every `docs/kb/extraction/*.json` group file (`docs/kb/KB_SCHEMA.md`), and a
  glossary at `docs/kb/glossary.json` or `docs/kb/glossary/*.json` once
  An earlier change lands one. Each top-level list in a file is a *kind* — `concepts`
  becomes `concept`, `visual_directives` becomes `visual_directive` — and each
  element one record. The ten kinds the schema names are read field by field;
  a list under any other name is read generically (an `id`, `term` or `name`
  for its title, a `definition`, `text` or `summary` for its statement, the
  rest as attributes), so a glossary in a shape nobody has settled yet is still
  searchable rather than silently left out.

  ## Three fields, weighted

  A record has a **title** (a concept's name and aliases, a document's title, a
  requirement's id read as words), a **statement** (the definition, the text,
  the summary, the rationale) and **attributes** (everything else it carries:
  a concept's attributes, key terms, a gap's suggestion). A term in the title
  counts three times, in the statement once, in the attributes half — the
  BM25F idea without its per-field length normalisation, because three fields
  of such different lengths do not reward the extra parameters.

  ## Sources, resolved back to the repository

  The extractions record where each document was read, and most of those paths
  are the scratch directories of the sessions that did the reading
  (`/tmp/claude-0/…/scratchpad/ref/…`, `/tmp/na_docx/…`). `resolve_path/2`
  maps one back to a file under `_refdoc/` when it can — the path itself, then
  the longest tail of it that names exactly one file there, then a `.docx`
  with the same stem — and keeps the original, marked unresolved, when it
  cannot. A source nobody can open is still a source; it is not presented as a
  file that exists.

  ## Its shape is for a fresh BEAM

  The index is read far more often than it is built: `noetic-harness kb` in a
  shell loads it from `.agents/cache/kb/` into a BEAM that lives for one
  query. What that costs is what the index holds on the process heap, because
  decoding it, copying it into `:persistent_term` and every garbage collection
  that follows walk every word of it. At 16 977 records (version 2) it was
  5.1 million words: 3.2 million of them postings, as a list of `{n, tf}`
  tuples per term, and 1.7 million the records as maps. A fresh BEAM spent
  120 ms decoding, 75–190 ms copying, and then 220–1 100 ms in a first query
  whose garbage collection copied the whole live index.

  So since version 3 the two large parts are binaries, which the decoder
  copies as bytes, which `:persistent_term` shares rather than copies when
  they are large, and which a collection does not walk:

    * **postings**: each term's postings are one binary of 6-byte entries,
      `<<n::32, tf2::16>>`, where `tf2` is twice the weighted term frequency.
      The weights are 3, 1 and 0.5, so a frequency is a multiple of 0.5 and
      twice it is an exact integer;
    * **records**: each record is its own `term_to_binary/1` blob, decoded
      only when it becomes a hit (`record/2`). What a query needs of every
      record, its id, kind and group, is in `meta`, one small tuple each.

  `noetic-harness kb` prints the load and query times on every answer, and
  An earlier change's handoff has the numbers before and after.
  """

  alias Noetic.Harness.KB.{Glossary, Text}
  alias Noetic.Harness.Project

  @weights %{title: 3.0, statement: 1.0, attributes: 0.5}

  # A record's text is kept for the snippet, but not all of it: a document's
  # attributes can run to kilobytes of key terms. Past this the snippet would
  # not show it anyway.
  @max_field_chars 4_000

  @known_kinds %{
    "documents" => "document",
    "concepts" => "concept",
    "relations" => "relation",
    "requirements" => "requirement",
    "decisions" => "decision",
    "data_model" => "data_model",
    "visual_directives" => "visual_directive",
    "gaps" => "gap",
    "contradictions" => "contradiction",
    "quotes" => "quote"
  }

  @type kb_record :: %{
          id: String.t(),
          kind: String.t(),
          group: String.t(),
          group_name: String.t(),
          file: String.t(),
          title: String.t(),
          statement: String.t(),
          attributes: String.t(),
          status: String.t() | nil,
          link: String.t() | nil,
          sources: [
            %{
              required(:path) => String.t(),
              required(:resolved) => boolean(),
              optional(:member) => String.t()
            }
          ]
        }

  @typedoc "A record's id, kind, short group and group name, which every query needs."
  @type meta :: {String.t(), String.t(), String.t(), String.t()}

  @type t :: %{
          version: pos_integer(),
          hash: String.t(),
          records: tuple(),
          meta: tuple(),
          ids: %{String.t() => non_neg_integer()},
          names: %{String.t() => [non_neg_integer()]},
          postings: %{String.t() => binary()},
          lengths: tuple(),
          average_length: float(),
          files: [String.t()]
        }

  # Bumped whenever what an index holds changes shape, so a cache written by an
  # older harness is rebuilt rather than misread.
  @version 3

  @doc "The shape version an index carries."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  What, beside the files, an index depends on: its shape version, the
  compiled code of this module and `Noetic.Harness.KB.Text`, and the project's
  `kb` section (`Noetic.Harness.Project`), which says which files
  are read and how a recorded source path resolves. Part of the content hash,
  and of the stat manifest `Noetic.Harness.KB` keeps beside the cached index.
  """
  @spec fingerprint() :: iodata()
  def fingerprint,
    do: [
      "v#{@version}",
      __MODULE__.module_info(:md5),
      Text.module_info(:md5),
      :erlang.term_to_binary(Project.get()["kb"], [:deterministic])
    ]

  @doc "How many records the index holds."
  @spec size(t()) :: non_neg_integer()
  def size(index), do: tuple_size(index.meta)

  @doc "Record `n`, decoded from its blob."
  @spec record(t(), non_neg_integer()) :: kb_record()
  def record(index, n), do: :erlang.binary_to_term(elem(index.records, n))

  @doc "Record `n`'s id, kind, short group and group name, without decoding it."
  @spec meta(t(), non_neg_integer()) :: meta()
  def meta(index, n), do: elem(index.meta, n)

  @doc """
  Fold `fun` over the postings of `term`: `fun.(n, tf, acc)` for each record
  that has it, in record order. Also returns how many there were, which is the
  term's document frequency.
  """
  @spec reduce_postings(t(), String.t(), acc, (non_neg_integer(), float(), acc -> acc)) ::
          {non_neg_integer(), acc}
        when acc: term()
  def reduce_postings(index, term, acc, fun) do
    packed = Map.get(index.postings, term, <<>>)

    {div(byte_size(packed), 6),
     for(<<n::32, tf2::16 <- packed>>, reduce: acc, do: (acc -> fun.(n, tf2 / 2, acc)))}
  end

  @doc "The document frequency of `term`: how many records have it."
  @spec df(t(), String.t()) :: non_neg_integer()
  def df(index, term), do: div(byte_size(Map.get(index.postings, term, <<>>)), 6)

  @doc "The kinds the schema names, singular."
  @spec kinds() :: [String.t()]
  def kinds, do: @known_kinds |> Map.values() |> Enum.sort()

  @doc """
  The files an index is built from, relative to `root`, sorted. The order is
  part of the content hash, so it has to be stable.
  """
  @spec source_files(Path.t()) :: [String.t()]
  def source_files(root) do
    # The project's paths (`Noetic.Harness.Project`): the
    # extraction, the glossary and its parts. One it does not name adds none.
    [
      glob(Project.kb("extraction"), "*.json"),
      Project.kb("glossary"),
      glob(Project.kb("glossary_parts"), "*.json")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  @doc """
  The content hash of the files an index is built from: sha256 over each
  file's relative path and bytes, in order — and over the compiled code of
  this module and `Noetic.Harness.KB.Text`, because an index is what the code
  made of the files, and a change to the stemmer or to how a source path is
  resolved changes the index as surely as an edit to the extraction. Without
  it the cache went on serving an index built by the previous code, which is
  how this line came to be written.
  """
  @spec content_hash(Path.t(), [String.t()]) :: String.t()
  def content_hash(root, files) do
    init = :crypto.hash_init(:sha256) |> :crypto.hash_update(fingerprint())

    files
    |> Enum.reduce(init, fn file, acc ->
      acc
      |> :crypto.hash_update(file)
      |> :crypto.hash_update(<<0>>)
      |> :crypto.hash_update(File.read!(Path.join(root, file)))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Build the index. `refdoc` is the list of repository-relative paths under
  `_refdoc/` that sources are resolved against; `build/3` lists them itself
  when it is not given.
  """
  @spec build(Path.t(), [String.t()], String.t(), [String.t()] | nil) ::
          {:ok, t()} | {:error, String.t()}
  def build(root, files, hash, refdoc \\ nil) do
    with {:ok, groups} <- read(root, files) do
      refdoc = refdoc || refdoc_files(root)
      resolver = resolver(refdoc)

      documents =
        for {_file, data} <- groups,
            doc <- list(data, "documents"),
            is_map(doc),
            into: %{},
            do: {doc["id"] || doc["path"], doc["path"]}

      records = Enum.flat_map(groups, fn {file, data} -> records(file, data) end)

      # Resolved once per distinct path: a few hundred documents are cited by
      # thousands of records.
      resolved =
        records
        |> Enum.flat_map(
          &(&1.own_paths ++ Enum.map(refs(&1), fn ref -> Map.get(documents, ref, ref) end))
        )
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Map.new(&{&1, resolve_path(&1, resolver, root)})

      records = Enum.map(records, &resolve_sources(&1, documents, resolved))

      {:ok, index(records, files, hash)}
    end
  end

  defp read(root, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      with {:ok, bytes} <- File.read(Path.join(root, file)),
           {:ok, data} when is_map(data) <- JSON.decode(bytes) do
        {:cont, {:ok, [{file, data} | acc]}}
      else
        {:ok, _other} -> {:halt, {:error, "#{file} is not a JSON object"}}
        {:error, reason} -> {:halt, {:error, "#{file} could not be read: #{inspect(reason)}"}}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, Enum.reverse(groups)}
      error -> error
    end
  end

  defp list(data, key) do
    case data[key] do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # ---- records ---------------------------------------------------------------

  defp records(file, data) do
    group_name = group_name(file, data)
    group = short_group(group_name)

    data
    |> Enum.filter(fn {_key, value} -> is_list(value) end)
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.flat_map(fn {key, items} ->
      kind = Map.get(@known_kinds, key, singular(key))

      items
      |> Enum.filter(&is_map/1)
      |> Enum.with_index()
      |> Enum.map(fn {item, n} ->
        item
        |> fields(kind)
        |> then(&Map.merge(%{status: nil, link: nil, names: []}, &1))
        |> Map.merge(%{kind: kind, group: group, group_name: group_name, file: file})
        |> Map.update!(:id, &(&1 || "#{kind}:#{group}:#{n + 1}"))
        |> Map.update!(:title, &clip/1)
        |> Map.update!(:statement, &clip/1)
        |> Map.update!(:attributes, &clip/1)
      end)
    end)
  end

  defp group_name(file, data) do
    case data["group"] do
      name when is_binary(name) and name != "" -> name
      _ -> file |> Path.basename(".json")
    end
  end

  @doc """
  A group's short code — `G4` for `G4_lighthouse`, `G9b` for
  `G9b_tide_tables` — or the whole name when it has none (`glossary`).
  """
  @spec short_group(String.t()) :: String.t()
  def short_group(name) do
    case Regex.run(~r/^(G\d+[a-z]?)(?:_|$)/, name) do
      [_, short] -> short
      nil -> name
    end
  end

  defp singular(key) do
    cond do
      String.ends_with?(key, "ies") -> String.slice(key, 0..-4//1) <> "y"
      String.ends_with?(key, "s") -> String.slice(key, 0..-2//1)
      true -> key
    end
  end

  defp fields(item, "document") do
    %{
      id: item["id"],
      title: flat([item["title"], slug_words(item["id"])]),
      statement: str(item["summary"]),
      attributes: flat([item["key_terms"], item["kind"], item["language"], item["version"]]),
      source_refs: [],
      own_paths: [item["path"]]
    }
  end

  defp fields(item, "concept") do
    %{
      id: item["id"],
      title: flat([item["name"], item["aliases"], slug_words(item["id"])]),
      statement: str(item["definition"]),
      attributes: flat([item["domain"], item["attributes"]]),
      source_refs: item["sources"],
      own_paths: []
    }
  end

  defp fields(item, "relation") do
    from = item["from"]
    to = item["to"]

    %{
      id: if(from && to, do: "rel:#{from}>#{item["type"]}>#{to}"),
      # Not the title: a relation's words are the ids of the two records it
      # joins, and in the title they outranked those records themselves.
      title: "",
      statement: str(item["note"]),
      attributes: flat([slug_words(from), item["type"], slug_words(to)]),
      source_refs: item["sources"],
      own_paths: []
    }
  end

  defp fields(item, "data_model") do
    %{
      id: if(item["entity"], do: "entity:#{item["entity"]}"),
      title: str(item["entity"]),
      statement:
        flat(
          for field <- List.wrap(item["fields"]),
              is_map(field),
              do: [field["name"], field["type"], field["note"]]
        ),
      attributes: flat([item["kind"], item["source_format"]]),
      source_refs: item["sources"],
      own_paths: []
    }
  end

  defp fields(item, "contradiction") do
    %{
      id: item["id"],
      title: str(slug_words(item["id"])),
      statement: str(item["text"]),
      attributes: flat([item["resolution_proposal"]]),
      source_refs: item["between"],
      own_paths: []
    }
  end

  defp fields(item, "quote") do
    %{
      id: item["id"],
      title: "",
      statement: str(item["text"]),
      attributes: "",
      source_refs: [item["source"]],
      own_paths: []
    }
  end

  defp fields(item, kind) when kind in ~w(requirement decision visual_directive gap) do
    %{
      id: item["id"],
      title: str(slug_words(item["id"])),
      statement: flat([item["text"], item["rationale"]]),
      attributes:
        flat([
          item["kind"],
          item["priority"],
          item["component"],
          item["status"],
          item["severity"],
          item["suggestion"]
        ]),
      source_refs: item["sources"],
      own_paths: []
    }
  end

  # A glossary term (`docs/kb/glossary.json`). Its names are its
  # title, so that a query in either language finds it; its status and its
  # link travel with it, because a term is only as good as whether it is
  # decided.
  defp fields(item, "term") do
    %{
      id: item["id"],
      title: flat([item["en"], item["ru"], item["aliases"]]),
      statement: str(item["definition"]),
      attributes: flat([item["domain"], item["in_repo"], item["note"]]),
      source_refs: List.wrap(item["sources"]),
      own_paths: [],
      status: item["status"],
      link: Glossary.link(item["id"]),
      names: Glossary.keys(item)
    }
  end

  # Anything else the schema does not name.
  defp fields(item, _kind) do
    title_key = Enum.find(~w(term name title id), &is_binary(item[&1]))
    statement_key = Enum.find(~w(definition text summary description), &is_binary(item[&1]))

    %{
      id: item["id"] || (title_key && item[title_key]),
      title: flat([title_key && item[title_key], item["aliases"]]),
      statement: str(statement_key && item[statement_key]),
      attributes:
        item
        |> Map.drop(
          Enum.reject(["id", title_key, statement_key, "aliases", "sources"], &is_nil/1)
        )
        |> Map.values()
        |> flat(),
      source_refs: List.wrap(item["sources"]),
      own_paths: []
    }
  end

  # `req:lighthouse-nine-lights` is, read as words, a good English title for
  # a Russian requirement: the extractors wrote ids in English.
  defp slug_words(nil), do: nil

  defp slug_words(id) when is_binary(id) do
    id |> String.split(":", parts: 2) |> List.last() |> String.replace(~r/[-_]+/, " ")
  end

  defp str(nil), do: ""
  defp str(value) when is_binary(value), do: value
  defp str(value), do: flat([value])

  defp flat(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(&leaves/1)
    |> Enum.join(" · ")
  end

  defp leaves(nil), do: []
  defp leaves(value) when is_binary(value), do: [value]
  defp leaves(value) when is_number(value) or is_boolean(value), do: [to_string(value)]
  defp leaves(list) when is_list(list), do: Enum.flat_map(list, &leaves/1)

  defp leaves(map) when is_map(map),
    do: map |> Enum.sort() |> Enum.flat_map(fn {k, v} -> [to_string(k) | leaves(v)] end)

  defp leaves(_), do: []

  defp clip(text) when byte_size(text) <= @max_field_chars, do: text
  defp clip(text), do: String.slice(text, 0, @max_field_chars)

  # ---- sources ---------------------------------------------------------------

  defp resolve_sources(record, documents, resolved) do
    sources =
      (record.own_paths ++ Enum.map(refs(record), &Map.get(documents, &1, &1)))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.map(&Map.fetch!(resolved, &1))
      |> Enum.uniq()

    record |> Map.drop([:source_refs, :own_paths]) |> Map.put(:sources, sources)
  end

  defp refs(record), do: record.source_refs |> List.wrap() |> Enum.filter(&is_binary/1)

  defp glob(nil, _pattern), do: nil
  defp glob(dir, pattern), do: Path.join(dir, pattern)

  # The corpus sources resolve against: the project's `kb.corpus`, or none.
  defp refdoc_files(root), do: refdoc_files(root, Project.kb("corpus"))

  defp refdoc_files(_root, nil), do: []

  defp refdoc_files(root, corpus) do
    case System.cmd("git", ["-C", root, "ls-files", "-z", "--", corpus], stderr_to_stdout: true) do
      {out, 0} ->
        out |> String.split(<<0>>, trim: true)

      _ ->
        root
        |> Path.join(corpus <> "/**")
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, root))
    end
  rescue
    _ -> []
  end

  @doc false
  def resolver(refdoc) do
    by_name = Enum.group_by(refdoc, &Path.basename/1)

    archives =
      refdoc
      |> Enum.flat_map(fn path ->
        case Regex.run(~r/^(.+)\.(?:zip|tar\.gz|tgz)$/, Path.basename(path)) do
          [_, stem] -> [{stem, path}]
          nil -> []
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    %{set: MapSet.new(refdoc), by_name: by_name, archives: archives, roots: roots()}
  end

  # A recorded absolute path is cut back at the first of the project's top
  # directories (`kb.source_roots`); with none, it is not cut at all.
  defp roots do
    case Project.kb_source_roots() do
      [] -> nil
      names -> Regex.compile!("/((?:" <> Enum.map_join(names, "|", &Regex.escape/1) <> ")/.+)$")
    end
  end

  @doc """
  A source path from an extraction, as a repository path when one can be found.

  `%{path: path, resolved: true}` names a file in the repository. A source
  read from inside an archive the corpus keeps (`engine.tar.gz`) is the
  archive, with the path inside it as `member`. `resolved: false` is the path
  the extraction recorded, exactly as it recorded it.
  """
  @spec resolve_path(String.t(), map(), Path.t()) :: map()
  def resolve_path(path, resolver, root) do
    relative = repository_relative(path, root, Map.get(resolver, :roots))

    cond do
      relative &&
          (MapSet.member?(resolver.set, relative) or File.exists?(Path.join(root, relative))) ->
        %{path: relative, resolved: true}

      found = by_tail(path, resolver) ->
        %{path: found, resolved: true}

      found = in_archive(path, resolver) ->
        found

      true ->
        %{path: path, resolved: false}
    end
  end

  # `/tmp/unpacked/engine/src/lexer.ts` was read from an unpacked
  # `_refdoc/sources/engine.tar.gz`: the last directory of the path that is an
  # archive's name, and what follows it.
  defp in_archive(path, %{archives: archives}) do
    parts = Path.split(path)

    parts
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {part, i} ->
      case Map.get(archives, part) do
        nil ->
          nil

        found ->
          member = parts |> Enum.drop(i + 1) |> Path.join()
          %{path: shallowest(found), resolved: true, member: member}
      end
    end)
  end

  # `/srv/checkout/docs/plan/x.md` from a checkout at another path, or at
  # this one: the part from the first directory this repository has.
  defp repository_relative(path, root, roots) do
    cond do
      Path.type(path) == :relative ->
        path

      String.starts_with?(path, root <> "/") ->
        Path.relative_to(path, root)

      match = roots && Regex.run(roots, path) ->
        Enum.at(match, 1)

      true ->
        nil
    end
  end

  # The longest tail of the path that names a `_refdoc/` file, then a `.docx`
  # of the same stem: `ref/docx_md/X.md` was converted from `X.docx`.
  #
  # A corpus can hold a pack twice (`_refdoc/pack_one/` and
  # `_refdoc/extra/pack_one/`), so a tail
  # of two or more parts that matches several files takes the shallowest,
  # which is the top-level copy. A bare file name must be unique: `README.md`
  # alone names forty files and none of them.
  defp by_tail(path, %{by_name: by_name}) do
    parts = Path.split(path)
    name = List.last(parts)

    candidates = Map.get(by_name, name, [])

    tail_match =
      Enum.find_value(length(parts)..1//-1, fn n ->
        tail = parts |> Enum.take(-n) |> Path.join()

        case Enum.filter(candidates, &String.ends_with?(&1, "/" <> tail)) do
          [] -> nil
          [one] -> one
          many when n >= 2 -> shallowest(many)
          _ -> nil
        end
      end)

    tail_match ||
      case Map.get(by_name, Path.rootname(name) <> ".docx", []) do
        [one] -> one
        # Several copies of one .docx (the corpus has them): the shortest path,
        # which is the top-level one, rather than none.
        [_ | _] = many -> shallowest(many)
        [] -> nil
      end
  end

  defp shallowest(paths), do: Enum.min_by(paths, &{length(Path.split(&1)), &1})

  # ---- the index -------------------------------------------------------------

  defp index(records, files, hash) do
    records = Enum.with_index(records)

    # A glossary term's names, keyed by their stems joined, so that a query
    # that *is* a term's name, in any of its languages and inflections, can be
    # found without scoring. Kept here rather than on the record.
    names =
      for {record, n} <- records,
          key <- record.names,
          reduce: %{} do
        acc -> Map.update(acc, Enum.join(key, " "), [n], &(&1 ++ [n]))
      end

    records = Enum.map(records, fn {record, n} -> {Map.delete(record, :names), n} end)

    weighted =
      Enum.map(records, fn {record, n} ->
        tf =
          Enum.reduce(@weights, %{}, fn {field, weight}, acc ->
            record
            |> Map.fetch!(field)
            |> Text.terms()
            |> Enum.reduce(acc, fn term, acc -> Map.update(acc, term, weight, &(&1 + weight)) end)
          end)

        {n, tf}
      end)

    # `weighted` is in record order, so each term's entries are too, and a
    # term's binary is built by appending in that order.
    postings =
      weighted
      |> Enum.flat_map(fn {n, tf} -> Enum.map(tf, fn {term, w} -> {term, {n, w}} end) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {term, entries} ->
        {term, for({n, w} <- entries, into: <<>>, do: <<n::32, min(round(w * 2), 65_535)::16>>)}
      end)

    lengths = Enum.map(weighted, fn {_n, tf} -> tf |> Map.values() |> Enum.sum() end)
    count = max(length(lengths), 1)

    %{
      version: @version,
      hash: hash,
      records: records |> Enum.map(&:erlang.term_to_binary(elem(&1, 0))) |> List.to_tuple(),
      meta:
        records
        |> Enum.map(fn {r, _n} -> {r.id, r.kind, r.group, r.group_name} end)
        |> List.to_tuple(),
      ids: Map.new(records, fn {record, n} -> {record.id, n} end),
      names: names,
      postings: postings,
      lengths: List.to_tuple(lengths),
      average_length: Enum.sum(lengths) / count,
      files: files
    }
  end
end
