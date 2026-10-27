defmodule Noetic.Harness.Brief do
  @moduledoc """
  The *Terms* section of a coordinator's brief: the glossary entries an epic's
  scope names, so that a worker starts from the person's words and not from
  its own guesses at them (K3-HAR-10).

  Two halves, both over `docs/kb/glossary.json` through
  `Noetic.Harness.KB.Glossary`:

    * `terms/2` and `render/1` make the section. Its input is the brief's first
      line — `EPIC <id>: branch …, scope …, grants …` — and its title, the
      same text the coordinator already writes. `noetic-harness context --format
      brief-terms --title "<that line>"` prints it, for the coordinator to
      paste under `## Terms` (`.agents/templates/worker/brief.md`).
    * `check/1` reads a brief and says what is wrong with its section: that
      there is none, that a line of it names no glossary id, or that an id it
      names is not in the glossary. `noetic-harness context --check-brief <file>`
      runs it over a brief, or over a coordination record's `brief`.

  ## What "the scope names" means here

  The words of the line, matched the way `Noetic.Harness.Context` matches a
  title: whole words, folded by `Noetic.Harness.KB.Text`, longest name first.
  A path contributes the directory it sits in and its file name, not its whole
  route, so `apps/my_app/lib/**` does not name every term whose name is
  `my_app`. A glob contributes nothing for its `*`, and a dot-directory
  (`.agents/`, `.claude/`) nothing at all: `.agents/templates/**` named a
  term called agents by its `.agents` until it was left out. Nor does an
  umbrella app's directory, the segment after `apps/`, or any segment of the
  same name, such as `apps/my_app/lib/my_app/`: an app's name is a code name,
  and an app named for the product used to name the product's own term,
  until an earlier change.

  ## Words, not senses, and what the coordinator does about it

  Matching finds names, and a name can be in the scope line in another sense:
  «the MCP context *path*» named `term:path`, the road. The coordinator leaves
  such a term out by writing `-term:<id>` anywhere in the text, as in
  `--title "EPIC …, the MCP context path -term:path"`. The token is taken out
  of the text and its term out of the section.

  Leaving out every term outside the epic's profile's domain was the other
  way, and it was rejected on the evidence. An earlier change was a `memory` epic, and
  eight of the ten terms its brief named were right, all of them in the
  glossary's `harness` domain. A profile filter would have kept none of them.
  It would still keep a wrong sense that happens to share the profile's
  domain. A profile says who does the work, not which words the work is about.

  ## Why a line must carry the id

  A term is checked by its id (`term:spectators`), because an id is what the
  glossary guarantees is unique and stable. A name is not: «зрители» and
  `spectators` are the same entry, and a name can be retired and reused. A
  line the coordinator wrote by hand without an id cannot be checked, so it is
  reported, not trusted.
  """

  alias Noetic.Harness.KB.Glossary

  @heading "## Terms"
  @max_terms 12
  @definition_chars 160

  @doc "The heading the section is written under."
  @spec heading() :: String.t()
  def heading, do: @heading

  @doc """
  The glossary terms `text` names, most specific first, at most
  #{@max_terms}. `text` is a brief's first line and title; paths in it count
  by their directory and file name.
  """
  @spec terms(String.t(), keyword()) ::
          {:ok, [Glossary.term_entry()], truncated :: boolean()} | {:error, :absent | String.t()}
  def terms(text, opts \\ []) when is_binary(text) do
    max = Keyword.get(opts, :max, @max_terms)
    {text, excluded} = exclusions(text)
    excluded = MapSet.new(Keyword.get(opts, :exclude, []) ++ excluded)

    with {:ok, glossary} <- Glossary.terms() do
      named =
        glossary
        |> Glossary.named_in(words(text))
        |> Enum.map(&elem(&1, 0))
        |> Enum.reject(&MapSet.member?(excluded, &1.id))

      {:ok, Enum.take(named, max), length(named) > max}
    end
  end

  # `-term:<id>` tokens: the coordinator's exclusions, taken out of the text.
  defp exclusions(text) do
    {excluded, kept} =
      text
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.split_with(&String.starts_with?(&1, "-term:"))

    {Enum.join(kept, " "), Enum.map(excluded, &String.trim_leading(&1, "-"))}
  end

  # Words stay words; a token with a `/` in it is a path and says only its
  # directory and its file name.
  defp words(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map_join(" ", fn token ->
      if String.contains?(token, "/"), do: path_words(token), else: token
    end)
  end

  defp path_words(token) do
    parts =
      token
      |> String.trim("`")
      |> Path.split()
      |> Enum.reject(&(String.contains?(&1, "*") or String.starts_with?(&1, ".")))
      |> drop_app()

    dir = parts |> Enum.drop(-1) |> List.last()
    Enum.join([dir || "", Path.rootname(List.last(parts) || "")], " ")
  end

  # The segment after the apps directory names an app, which is code, not a
  # word of the domain; so does every other segment with the same name, such
  # as the `lib/acme/` namespace directory of `apps/acme`. Which directory
  # holds the apps is the project's layout (`Project.layout/0`).
  defp drop_app(parts) do
    case Noetic.Harness.Project.layout() do
      nil -> parts
      %{apps: apps} -> drop_app(parts, apps)
    end
  end

  defp drop_app(parts, apps) do
    case Enum.drop_while(parts, &(&1 != apps)) do
      [^apps, app | _] -> Enum.reject(parts, &(&1 == app))
      _ -> parts
    end
  end

  @doc """
  The section, as markdown: the heading, one line saying where it came from,
  and one line per term — its id, its names, its status, the start of its
  definition and its link into `docs/kb/glossary.md`.
  """
  @spec render([Glossary.term_entry()], boolean()) :: String.t()
  def render(terms, truncated \\ false) do
    lines =
      case terms do
        [] -> ["- (the scope names no glossary term)"]
        _ -> Enum.map(terms, &line/1)
      end

    more =
      if truncated,
        do: ["", "_More terms are named; the #{@max_terms} most specific are kept._"],
        else: []

    Enum.join(
      [
        @heading,
        "",
        "The glossary entries this epic's scope names (`#{Glossary.path()}`, from " <>
          "`noetic-harness context --format brief-terms`). A `contested` or `proposed` term " <>
          "is a question for the person, not an answer.",
        ""
        | lines
      ] ++ more,
      "\n"
    )
  end

  defp line(term) do
    "- `#{term.id}` — **#{term.en}** · #{term.ru} (#{term.status}): " <>
      "#{clip(term.definition)} → #{term.link}"
  end

  defp clip(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) <= @definition_chars,
      do: text,
      else: String.slice(text, 0, @definition_chars) <> "…"
  end

  @doc """
  What is wrong with a brief's *Terms* section, as sentences; `[]` when
  nothing is. `glossary` defaults to the repository's own.

      iex> Noetic.Harness.Brief.check("EPIC bd-1: branch claude/bd-1-x", [])
      ["the brief has no `## Terms` section: `noetic-harness context --format brief-terms --title \\"<its first line>\\"` makes one"]
  """
  @spec check(String.t(), [Glossary.term_entry()] | nil) :: [String.t()]
  def check(brief, glossary \\ nil) when is_binary(brief) do
    case section(brief) do
      nil ->
        [
          "the brief has no `#{@heading}` section: `noetic-harness context --format brief-terms " <>
            "--title \"<its first line>\"` makes one"
        ]

      [] ->
        [
          "the brief's `#{@heading}` section lists nothing: an unfilled template is not " <>
            "a brief, and a scope that names no term says so in a line of its own"
        ]

      lines ->
        known = known_ids(glossary)
        Enum.flat_map(lines, &check_line(&1, known))
    end
  end

  defp known_ids(nil) do
    case Glossary.terms() do
      {:ok, terms} -> known_ids(terms)
      {:error, _} -> MapSet.new()
    end
  end

  defp known_ids(terms), do: MapSet.new(terms, & &1.id)

  # The bullets under the heading, up to the next heading.
  defp section(brief) do
    case String.split(brief, ~r/^#{Regex.escape(@heading)}[ \t]*$/m, parts: 2) do
      [_, rest] ->
        rest
        |> String.split(~r/^\#{1,6} /m, parts: 2)
        |> hd()
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(String.trim_leading(&1), "- "))

      [_] ->
        nil
    end
  end

  defp check_line(line, known) do
    case Regex.scan(~r/term:[a-z0-9][a-z0-9_.-]*[a-z0-9]/, line) do
      [] ->
        if line =~ "the scope names no glossary term",
          do: [],
          else: ["a line of `#{@heading}` names no glossary id: #{String.trim(line)}"]

      ids ->
        for [id] <- Enum.uniq(ids), not MapSet.member?(known, id) do
          "`#{id}` is not in #{Glossary.path()}"
        end
    end
  end

  @doc """
  The brief in `path`: the file's text, or the `brief` field when the file is
  a coordination record (`.agents/coordination/*.json`). A relative path is
  the repository's, like every path the harness takes: `noetic-harness` runs its
  tasks from `apps/noetic_harness`, where a path relative to the working
  directory would not be found.
  """
  @spec read(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(path) do
    with {:ok, text} <- File.read(Path.expand(path, Noetic.Harness.root())) do
      case JSON.decode(text) do
        {:ok, %{"brief" => brief}} when is_binary(brief) -> {:ok, brief}
        {:ok, %{}} -> {:error, "#{path} is JSON with no `brief` field"}
        _ -> {:ok, text}
      end
    else
      {:error, reason} -> {:error, "#{path} could not be read: #{inspect(reason)}"}
    end
  end
end
