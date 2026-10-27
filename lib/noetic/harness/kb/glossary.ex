defmodule Noetic.Harness.KB.Glossary do
  @moduledoc """
  The glossary, `docs/kb/glossary.json`, as the harness reads it:
  which of its terms a piece of work names, and which term a query names
  exactly.

  ## What "names a term" means

  A term has names: its English name, its Russian name and its aliases. A
  piece of work names it when one of those names occurs in the work's title
  or paths, as a run of whole words. Both sides go through
  `Noetic.Harness.KB.Text.terms/1`, which folds case, `ё`, Russian
  inflection and English plurals, and drops function words:
  - «зрителям» names «зрители»;
  - "the sources of truth" names "source of truth";
  - "recall" does not name "call", because a name matches whole words and
    never a part of one.

  A name is written for people, so two things are taken off it before it is
  matched:
  - the parenthetical that tells two senses apart, as in "`dna` (DSL)" and
    "agent (of a persona)";
  - the code quotes.

  A name that leaves fewer than three letters after that is not matched. "AI"
  would name every title that happens to contain those two letters.

  ## Why not the index

  `Noetic.Harness.KB` also indexes the glossary, and uses these same keys to
  rank an exact match first. The context reads the file directly instead,
  because it needs only the terms, not 17 000 records. Decoding 500 KB of JSON
  takes milliseconds; loading the whole index from disk into a fresh BEAM takes
  hundreds. The parsed glossary is kept in `:persistent_term`, checked against
  the file's size and mtime, the way the index is.
  """

  alias Noetic.Harness.KB.Text
  alias Noetic.Harness.Project

  @type term_entry :: %{
          id: String.t(),
          en: String.t(),
          ru: String.t(),
          aliases: [String.t()],
          status: String.t(),
          domain: String.t() | nil,
          definition: String.t(),
          link: String.t(),
          keys: [[String.t()]]
        }

  @doc """
  Where the glossary is, relative to the repository root: the project's
  `kb.glossary` (`Noetic.Harness.Project`), or `nil` when it names none.
  """
  @spec path() :: String.t() | nil
  def path, do: Project.kb("glossary")

  # Where a term's link points: the rendered glossary, or the file itself
  # when the project names no rendering.
  defp markdown, do: Project.kb("glossary_markdown") || path()

  @doc """
  The glossary's terms, each with its match keys, or `{:error, :absent}` when
  there is no glossary file, or the project names none. The path is the
  project's (`path/0`, read at the root in effect); `root` is where it is
  looked for.
  """
  @spec terms(Path.t()) :: {:ok, [term_entry()]} | {:error, :absent | String.t()}
  def terms(root \\ Noetic.Harness.root()) do
    case path() do
      nil -> {:error, :absent}
      relative -> terms(root, relative)
    end
  end

  defp terms(root, relative) do
    file = Path.join(root, relative)

    case File.stat(file, time: :posix) do
      {:error, _} ->
        {:error, :absent}

      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        # The links are made from the project's rendering path, so a cache
        # kept across a change of it would serve the old links.
        stat = {size, mtime, relative, markdown()}

        case :persistent_term.get({__MODULE__, root}, nil) do
          %{stat: ^stat, terms: terms} ->
            {:ok, terms}

          _ ->
            with {:ok, terms} <- read(file, relative, elem(stat, 3)) do
              :persistent_term.put({__MODULE__, root}, %{stat: stat, terms: terms})
              {:ok, terms}
            end
        end
    end
  end

  defp read(file, relative, markdown) do
    with {:ok, bytes} <- File.read(file),
         {:ok, %{"terms" => items}} when is_list(items) <- JSON.decode(bytes) do
      {:ok, items |> Enum.filter(&is_map/1) |> Enum.map(&entry(&1, markdown))}
    else
      {:ok, _} -> {:error, "#{relative} has no `terms` list"}
      {:error, reason} -> {:error, "#{relative} could not be read: #{inspect(reason)}"}
    end
  end

  defp entry(item, markdown) do
    %{
      id: item["id"],
      en: str(item["en"]),
      ru: str(item["ru"]),
      aliases: item["aliases"] |> List.wrap() |> Enum.filter(&is_binary/1),
      status: str(item["status"]),
      domain: item["domain"],
      definition: str(item["definition"]),
      link: link(item["id"], markdown),
      keys: keys(item)
    }
  end

  defp str(value) when is_binary(value), do: value
  defp str(_), do: ""

  @doc """
  The link to a term's entry in the rendered glossary (`kb.glossary_markdown`,
  `docs/kb/glossary.md` here). The builder anchors an entry at its id with `:`
  turned into `-` (`docs/kb/builders/glossary.py`, `slug/1`). `link/2` takes
  the rendering's path, for a caller linking many terms: the project is read
  once, not once a term.
  """
  @spec link(String.t() | nil) :: String.t() | nil
  def link(id), do: link(id, markdown())

  @doc false
  @spec link(String.t() | nil, String.t() | nil) :: String.t() | nil
  def link(_id, nil), do: nil
  def link(nil, markdown), do: markdown
  def link(id, markdown), do: "#{markdown}##{String.replace(id, ":", "-")}"

  @doc """
  A term's match keys: one list of stems for each of its names, with names too
  short to match dropped.
  """
  @spec keys(map()) :: [[String.t()]]
  def keys(item) do
    [item["en"], item["ru"] | List.wrap(item["aliases"])]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&key/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  One name's key: its stems after its parenthetical and code quotes are taken
  off, or `nil` when fewer than three letters are left.

      iex> Noetic.Harness.KB.Glossary.key("`dna` (DSL)")
      ["dna"]

      iex> Noetic.Harness.KB.Glossary.key("the sources of truth")
      ["sourc", "truth"]

      iex> Noetic.Harness.KB.Glossary.key("AI")
      nil
  """
  @spec key(String.t()) :: [String.t()] | nil
  def key(name) do
    stems =
      name
      |> String.replace(~r/\([^)]*\)/u, " ")
      |> String.replace("`", "")
      |> Text.terms()

    if stems == [] or String.length(Enum.join(stems)) < 3, do: nil, else: stems
  end

  @doc """
  The terms a piece of text names, as `{term, the name's key}`, most specific
  first: the longest key, then the order the glossary gives.
  """
  @spec named_in([term_entry()], String.t()) :: [{term_entry(), [String.t()]}]
  def named_in(terms, text) do
    words = Text.terms(text)

    terms
    |> Enum.with_index()
    |> Enum.flat_map(fn {term, n} ->
      case Enum.filter(term.keys, &sublist?(&1, words)) do
        [] -> []
        keys -> [{term, Enum.max_by(keys, &length/1), n}]
      end
    end)
    |> Enum.sort_by(fn {_term, key, n} -> {-length(key), n} end)
    |> Enum.map(fn {term, key, _n} -> {term, key} end)
  end

  @doc "Whether `needle` occurs in `haystack` as a contiguous run."
  @spec sublist?([String.t()], [String.t()]) :: boolean()
  def sublist?([], _haystack), do: false

  def sublist?(needle, haystack) do
    size = length(needle)

    haystack
    |> Enum.chunk_every(size, 1, :discard)
    |> Enum.any?(&(&1 == needle))
  end

  @doc "Forget the parsed glossary for a root. For tests."
  @spec forget(Path.t()) :: :ok
  def forget(root \\ Noetic.Harness.root()) do
    _ = :persistent_term.erase({__MODULE__, root})
    :ok
  end
end
