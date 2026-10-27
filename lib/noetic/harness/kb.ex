defmodule Noetic.Harness.KB do
  @moduledoc """
  The knowledge base, asked from inside a session.

  `noetic-harness kb <query>` and the MCP tool `harness_kb_query` return the
  records of `docs/kb/extraction/` that answer a question — concepts,
  requirements, decisions, gaps, contradictions and the rest of
  `docs/kb/KB_SCHEMA.md` — each with its id, its group, the matched text and
  the source files it was extracted from. `noetic-harness context` puts the top
  few in front of an agent whose work asks for the `kb` context.

  ## Why the harness reads files and not the knowledge store

  The corpus is also loaded into Postgres, TypeDB and Qdrant by
  `mix kb.load`, and `mix kb.query` asks those. The harness does
  not, for two reasons that are the same reason:

    * it may not depend on the product's applications — the hooks boot it
      on every prompt, and it has to answer when the product apps do not
      compile (`Noetic.Harness` moduledoc, CLAUDE.md §5a-bis);
    * a cloud VM's stores start empty, and the files are in every checkout.

  So the answer comes from the files, and says so: `backend` is `"files"`,
  and `backends` reports whether the knowledge store and Qdrant were reachable
  (`Noetic.Harness.KB.Backends`, which says why neither is queried yet).

  ## The index, built once per content hash

  Building the index reads ~12 MB of JSON and tokenises ~17 000 records, which
  is seconds, not the tens of milliseconds a prompt hook can spend. So it is
  built once for each content hash of its source files and kept in three
  places, cheapest first:

    1. **in memory**, in `:persistent_term`, for a long-lived BEAM — the
       resident harness and the MCP server. Checked against the files' sizes
       and mtimes, so a warm query does not even hash them;
    2. **on disk**, at `.agents/cache/kb/<hash>.etf` (git-ignored), for a
       fresh BEAM — `noetic-harness kb` from a shell. The hash is sha256 over the
       files' paths and bytes, so an edit anywhere in the extraction, or a new
       group file, is a new hash and a rebuild, and the stale file is removed.
       Beside it, `stat.manifest` records the sizes and mtimes that hash was
       computed from, so a fresh BEAM whose files have not changed skips the
       hashing too;
    3. **built**, when neither holds the current hash.

  Every answer says which of the three it came from and how long that took,
  so a regression in the warm path is visible in the output rather than
  inferred from a slow session.

  ## Ranking

  BM25 (k1 = 1.2, b = 0.75) over three weighted fields — title ×3, statement
  ×1, attributes ×½ (`Noetic.Harness.KB.Index`) — on terms from
  `Noetic.Harness.KB.Text`, which handles Russian and English. A query that is
  a record id exactly puts that record first. Lexical ranking finds the words
  you used; a Russian record answers an English query only where the record
  carries English (its id, an alias, a key term), and that is a limit of this
  design, not an accident of the data.
  """

  alias Noetic.Harness.KB.{Backends, Glossary, Index, Text}
  alias Noetic.Harness.Project

  @default_limit 10
  @k1 1.2
  @b 0.75
  @snippet_chars 240

  @type hit :: %{
          id: String.t(),
          kind: String.t(),
          group: String.t(),
          group_name: String.t(),
          title: String.t() | nil,
          status: String.t() | nil,
          link: String.t() | nil,
          score: float(),
          field: String.t(),
          matched: String.t(),
          sources: [map()],
          also_in: [String.t()]
        }

  @type result :: %{
          query: String.t(),
          terms: [String.t()],
          hits: [hit()],
          total: non_neg_integer(),
          backend: String.t(),
          backends: [Backends.status()],
          index: %{
            hash: String.t(),
            records: non_neg_integer(),
            files: non_neg_integer(),
            from: :memory | :disk | :built,
            load_ms: non_neg_integer()
          },
          query_ms: non_neg_integer()
        }

  @doc """
  Ask the knowledge base.

  Options:

    * `:limit` — hits returned (default #{@default_limit});
    * `:group` — only this group: its short code (`G3`) or its whole name
      (`G3_harbour_lights`), case-insensitively;
    * `:kind` — only this kind: `concept`, `requirement`, `decision` … (a
      plural is accepted);
    * `:probe` — whether to ask if the knowledge store and Qdrant are up (default
      `true`; `Context` passes `false`, because a bundle has no use for it),
      or the addresses to ask at (`Noetic.Harness.KB.Backends.probe/1`);
    * `:cached` — answer only from an index already in memory or on disk,
      and return `{:error, :not_cached}` rather than build one (`index/1`).
  """
  @spec query(String.t(), keyword()) :: {:ok, result()} | {:error, String.t() | :not_cached}
  def query(text, opts \\ []) when is_binary(text) do
    limit = Keyword.get(opts, :limit) || @default_limit

    with :ok <- check_text(text),
         {:ok, index, info} <- index(cached: Keyword.get(opts, :cached, false)),
         {:ok, filter} <- filter(index, opts[:group], opts[:kind]) do
      started = System.monotonic_time()
      terms = text |> Text.terms() |> Enum.uniq()

      # One hit per id. Groups overlap — the same concept or relation was
      # extracted from G8 and again from G9 — and a list of the same record
      # twice is a list with one answer in it. The best-scoring copy is shown,
      # and `also_in` names the groups of the others.
      ranked =
        index
        |> score(terms, text)
        |> Enum.filter(fn {n, _score} -> filter.(Index.meta(index, n)) end)
        |> Enum.sort_by(fn {n, score} -> {-score, n} end)
        |> Enum.group_by(fn {n, _} -> index |> Index.meta(n) |> elem(0) end)
        |> Enum.map(fn {_id, [best | rest]} ->
          {best, Enum.map(rest, fn {n, _} -> index |> Index.meta(n) |> elem(2) end)}
        end)
        |> Enum.sort_by(fn {{n, score}, _} -> {-score, n} end)

      # Only the hits shown are decoded (`Noetic.Harness.KB.Index`).
      hits =
        ranked
        |> Enum.take(limit)
        |> Enum.map(fn {{n, score}, also_in} ->
          index
          |> Index.record(n)
          |> hit(score, text, terms)
          |> Map.put(:also_in, Enum.uniq(also_in))
        end)

      query_ms = ms_since(started)

      {:ok,
       %{
         query: text,
         terms: terms,
         hits: hits,
         total: length(ranked),
         backend: "files",
         backends: backends(Keyword.get(opts, :probe, true)),
         index: info,
         query_ms: query_ms
       }}
    end
  end

  defp backends(false), do: []

  # `knowledge_base` off in project.json: the stores are not asked, and the
  # answer says so where it would have said whether they were up.
  defp backends(probe) do
    if Noetic.Harness.Integrations.enabled?("knowledge_base"),
      do: probe_backends(probe),
      else: [
        %{
          name: "postgres",
          address: "",
          up: false,
          note:
            Noetic.Harness.Integrations.off("knowledge_base") <>
              ": the knowledge store and Qdrant are not asked"
        }
      ]
  end

  defp probe_backends(true), do: Backends.probe()
  defp probe_backends(addresses) when is_list(addresses), do: Backends.probe(addresses)

  defp check_text(text) do
    if String.trim(text) == "",
      do: {:error, "a query is needed: a word or a phrase, in Russian or English"},
      else: :ok
  end

  # ---- the index, cached -----------------------------------------------------

  @doc """
  The current index and where it came from: `:memory`, `:disk` or `:built`.

  With `cached: true` it is never built: an index that is in neither memory
  nor `.agents/cache/kb/` is `{:error, :not_cached}`. That is the mode for a
  caller on a hook path. A build is 5.5 s, past every ceiling in
  `Noetic.Harness.Hooks`, while memory is a few milliseconds and the disk
  cache 70–130 ms in a fresh BEAM. A cached miss still costs the
  content hash, ~40 ms, when the stat manifest does not already know it.
  """
  @spec index(keyword()) :: {:ok, Index.t(), map()} | {:error, String.t() | :not_cached}
  def index(opts \\ []) do
    root = Noetic.Harness.root()
    cached_only = Keyword.get(opts, :cached, false)
    started = System.monotonic_time()

    case Index.source_files(root) do
      [] ->
        {:error, absent(root)}

      files ->
        stat = stat(root, files)

        with {:ok, index, from} <- cached(root, files, stat, cached_only) do
          {:ok, index,
           %{
             hash: index.hash,
             records: Index.size(index),
             files: length(files),
             from: from,
             load_ms: ms_since(started)
           }}
        end
    end
  end

  @doc "Where the on-disk index for `root` lives."
  @spec cache_dir(Path.t()) :: Path.t()
  def cache_dir(root \\ Noetic.Harness.root()), do: Path.join([root, ".agents", "cache", "kb"])

  @doc "Forget the in-memory index for the current root. For tests."
  @spec forget() :: :ok
  def forget do
    _ = :persistent_term.erase(memory_key(Noetic.Harness.root()))
    :ok
  end

  defp cached(root, files, stat, cached_only) do
    case :persistent_term.get(memory_key(root), nil) do
      %{stat: ^stat, index: index} ->
        {:ok, index, :memory}

      _ ->
        hash = known_hash(root, stat) || Index.content_hash(root, files)

        # What is returned is the copy in `:persistent_term`, not the one
        # just decoded or built. That one is garbage once this returns, so the
        # query that follows does not carry the whole index on its heap into
        # its first garbage collection.
        with {:ok, index, from} <- from_disk_or_build(root, files, hash, cached_only) do
          :persistent_term.put(memory_key(root), %{stat: stat, index: index})
          write_manifest(root, stat, hash)
          %{index: shared} = :persistent_term.get(memory_key(root))
          {:ok, shared, from}
        end
    end
  end

  defp from_disk_or_build(root, files, hash, cached_only) do
    path = Path.join(cache_dir(root), "#{hash}.etf")

    case read_cache(path, hash) do
      {:ok, index} ->
        {:ok, index, :disk}

      :miss when cached_only ->
        {:error, :not_cached}

      :miss ->
        with {:ok, index} <- Index.build(root, files, hash) do
          write_cache(root, path, index)
          {:ok, index, :built}
        end
    end
  end

  defp read_cache(path, hash) do
    with {:ok, bytes} <- File.read(path),
         %{version: version, hash: ^hash} = index <- :erlang.binary_to_term(bytes),
         true <- version == Index.version() do
      {:ok, index}
    else
      _ -> :miss
    end
  rescue
    # A truncated or foreign file is a cache miss, not a failure.
    ArgumentError -> :miss
  end

  # Written to a temporary name and renamed, so two sessions building at once
  # cannot leave a half-written file that the next one reads. Older hashes are
  # removed: the directory holds one index, not a history. A cache that cannot
  # be written is not an error — the next query builds again, and says so.
  defp write_cache(root, path, index) do
    dir = cache_dir(root)
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, :erlang.term_to_binary(index)),
         :ok <- File.rename(tmp, path) do
      dir
      |> Path.join("*.etf")
      |> Path.wildcard()
      |> Enum.reject(&(&1 == path))
      |> Enum.each(&File.rm/1)
    else
      _ -> File.rm(tmp)
    end
  end

  # The stat manifest: the sizes and mtimes the current hash was
  # computed from, beside the cached index. A fresh BEAM whose files still
  # have those sizes and mtimes takes the hash from here instead of reading
  # and hashing ~12 MB, which was 40 ms of a 120 ms load. It is the trust the
  # in-memory cache already places in a stat; an edit that keeps a file's
  # size and lands in the same second as the last one would be missed by
  # both. Its name is not `*.etf`, so `write_cache/3`'s sweep keeps it.
  defp known_hash(root, stat) do
    fingerprint = IO.iodata_to_binary(Index.fingerprint())

    with {:ok, bytes} <- File.read(manifest(root)),
         %{fingerprint: ^fingerprint, stat: ^stat, hash: hash} <- :erlang.binary_to_term(bytes) do
      hash
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp write_manifest(root, stat, hash) do
    manifest = manifest(root)
    tmp = "#{manifest}.#{System.unique_integer([:positive])}.tmp"
    term = %{fingerprint: IO.iodata_to_binary(Index.fingerprint()), stat: stat, hash: hash}

    with :ok <- File.mkdir_p(Path.dirname(manifest)),
         :ok <- File.write(tmp, :erlang.term_to_binary(term)),
         :ok <- File.rename(tmp, manifest) do
      :ok
    else
      _ -> File.rm(tmp)
    end
  end

  defp manifest(root), do: Path.join(cache_dir(root), "stat.manifest")

  defp stat(root, files) do
    Enum.map(files, fn file ->
      case File.stat(Path.join(root, file), time: :posix) do
        {:ok, %File.Stat{size: size, mtime: mtime}} -> {file, size, mtime}
        {:error, _} -> {file, nil, nil}
      end
    end)
  end

  defp memory_key(root), do: {__MODULE__, root}

  # ---- filters ---------------------------------------------------------------

  # A filter sees a record's `Index.meta/2`: `{id, kind, group, group_name}`.
  defp filter(_index, group, kind) when group in [nil, ""] and kind in [nil, ""],
    do: {:ok, fn _ -> true end}

  defp filter(index, group, kind) do
    metas = Tuple.to_list(index.meta)

    with {:ok, group_filter} <- group_filter(metas, group),
         {:ok, kind_filter} <- kind_filter(metas, kind) do
      {:ok, fn meta -> group_filter.(meta) and kind_filter.(meta) end}
    end
  end

  defp group_filter(_metas, blank) when blank in [nil, ""], do: {:ok, fn _ -> true end}

  defp group_filter(metas, group) do
    wanted = String.downcase(group)
    groups = metas |> Enum.map(fn {_, _, short, name} -> {short, name} end) |> Enum.uniq()

    if Enum.any?(groups, fn {short, name} ->
         String.downcase(short) == wanted or String.downcase(name) == wanted
       end) do
      {:ok,
       fn {_, _, short, name} ->
         String.downcase(short) == wanted or String.downcase(name) == wanted
       end}
    else
      {:error,
       "no group #{inspect(group)}. Groups: " <>
         (groups |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(", "))}
    end
  end

  defp kind_filter(_metas, blank) when blank in [nil, ""], do: {:ok, fn _ -> true end}

  defp kind_filter(metas, kind) do
    kinds = metas |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
    wanted = String.downcase(kind)

    wanted =
      Enum.find(kinds, fn k -> k == wanted or k <> "s" == wanted or k <> "es" == wanted end) ||
        Enum.find(kinds, fn k ->
          String.ends_with?(k, "y") and String.slice(k, 0..-2//1) <> "ies" == wanted
        end)

    if wanted,
      do: {:ok, &(elem(&1, 1) == wanted)},
      else: {:error, "no kind #{inspect(kind)}. Kinds: #{Enum.join(kinds, ", ")}"}
  end

  # ---- scoring ---------------------------------------------------------------

  defp score(index, terms, text) do
    count = Index.size(index)
    average = max(index.average_length, 1.0)

    scores =
      Enum.reduce(terms, %{}, fn term, acc ->
        df = Index.df(index, term)
        idf = :math.log(1 + (count - df + 0.5) / (df + 0.5))

        {_df, acc} =
          Index.reduce_postings(index, term, acc, fn n, tf, acc ->
            norm = 1 - @b + @b * elem(index.lengths, n) / average

            Map.update(
              acc,
              n,
              idf * tf * (@k1 + 1) / (tf + @k1 * norm),
              &(&1 + idf * tf * (@k1 + 1) / (tf + @k1 * norm))
            )
          end)

        acc
      end)

    top = scores |> Map.values() |> Enum.max(fn -> 0.0 end)

    # A query that is a glossary term's name, in either language and any
    # inflection, is a request for that term: it ranks above everything
    # scoring found. Before this, «зрители» ranked two corpus
    # concepts about viewers above `term:spectators`, whose Russian name it
    # is, because the term's long attributes lengthened it and BM25 shortened
    # its score.
    named =
      case Glossary.key(text) do
        nil -> []
        key -> Map.get(Map.get(index, :names, %{}), Enum.join(key, " "), [])
      end

    scores = Enum.reduce(named, scores, &Map.put(&2, &1, top + 1.0))

    # A query that is an id is a request for that record, above even a name.
    case Map.fetch(index.ids, String.trim(text)) do
      {:ok, n} -> Map.put(scores, n, top + 2.0)
      :error -> scores
    end
  end

  # ---- hits ------------------------------------------------------------------

  defp hit(record, score, text, terms) do
    needles = Enum.uniq(terms ++ Text.words(text))

    field =
      Enum.find([:title, :statement, :attributes], :statement, fn field ->
        haystack = record |> Map.fetch!(field) |> Text.normalise()
        haystack != "" and Enum.any?(needles, &String.contains?(haystack, &1))
      end)

    # A match in the title is shown with the statement, which is what the
    # title names: «Мономиф» is found by its name and explained by its
    # definition.
    shown = if field == :title and record.statement != "", do: :statement, else: field

    %{
      id: record.id,
      kind: record.kind,
      group: record.group,
      group_name: record.group_name,
      title: title(record),
      status: record[:status],
      link: record[:link],
      score: Float.round(score * 1.0, 2),
      field: to_string(field),
      matched: Text.snippet(Map.fetch!(record, shown), needles, @snippet_chars),
      sources: record.sources
    }
  end

  # A term shows its two names and its status, which is the first thing a
  # reader of a term needs: a `contested` term is a question, not an answer.
  defp title(%{kind: "term", title: title, status: status}) do
    names = title |> String.split(" · ") |> Enum.take(2) |> Enum.join(" · ")
    if status, do: "#{names} (#{status})", else: names
  end

  defp title(%{kind: kind, title: title}) when kind in ~w(document concept data_model relation),
    do: title

  defp title(_record), do: nil

  defp ms_since(started),
    do: System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

  # What a repository with no index says: where the project keeps its
  # extraction and how it is made, or that it names none.
  defp absent(root) do
    case {Project.kb("extraction"), Project.kb("readme")} do
      {nil, _} ->
        "no knowledge base here: .agents/registry/project.json names no kb.extraction"

      {extraction, readme} ->
        "no knowledge base here: #{Path.join(root, extraction)} has no *.json." <>
          if(readme, do: " `#{readme}` says how it is made.", else: "")
    end
  end
end
