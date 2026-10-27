defmodule Noetic.Harness.Context do
  @moduledoc """
  Assembling the smallest sufficient context for one task.

  ## The failure this prevents

  Two failures, in opposite directions. Dumping the repository into every agent
  buries the three files that mattered under four hundred that did not. Giving
  an agent only the file it was told to edit produces a change that is locally
  correct and breaks a caller nobody looked at. Both are common; this module
  aims between them.

  ## What relevance means here

  Context is selected by the capabilities the router extracted, not by the task
  text. A `typedb.schema` capability pulls the live schema, the TypeQL files,
  A design decision and the TypeDB memory records. A `qa.regression` capability pulls the
  failing test, the git history around it and the recorded failures. The
  capability already encodes what kind of work this is, so the context follows
  from it rather than from a second guess at the same question.

  Each capability declares its `context` keys in
  `.agents/registry/capabilities.json`; this module resolves those keys against
  the repository. A key with no resolver is reported as unresolved rather than
  silently dropped — an agent should know that the schema it expected was not
  attached.

  ## Provenance survives assembly

  Every section records where it came from and how it was selected. An agent
  that acts on context cannot audit it afterwards unless the bundle says what it
  is and why it is here.
  """

  alias Noetic.Harness.{Git, Memory, Project, Registry, Skills}

  @type section :: %{
          key: String.t(),
          title: String.t(),
          why: String.t(),
          items: [%{path: String.t(), excerpt: String.t() | nil}],
          truncated: boolean()
        }

  @type bundle :: %{
          task: map(),
          capabilities: [String.t()],
          sections: [section()],
          unresolved: [String.t()],
          skills: [map()],
          memory: [map()],
          generated_at: String.t()
        }

  # A bundle is a budget, not a collection. These caps are deliberately small:
  # the point of context assembly is that somebody decided what mattered.
  #
  # Prior art, arrived at independently and from far more evidence: SoL-Pi
  # (arXiv:2609.20519) archives any tool result over 10 KiB and replaces it,
  # from the third request onward, with a stable handle and a ~1 KB excerpt of
  # head and tail lines — retrievable in full on demand. The excerpt size below
  # is the same order, which is mild corroboration that a kilobyte is about
  # where an excerpt stops being an excerpt.
  #
  # What we do *not* have is their retrieval half: a section truncated here is
  # truncated, and the agent has to go and read the file. That is a real
  # difference and the reason `unresolved` exists — a bundle says what it left
  # out rather than pretending the excerpt was the whole thing.
  @max_items_per_section 8
  @max_excerpt_bytes 1_200

  # What a bundle says under *Not attached* when the project has not said
  # where a piece of its knowledge base is: not configured is a
  # different statement from configured and missing.
  @unconfigured %{
    "glossary" => "kb.glossary in .agents/registry/project.json",
    "reading_maps" => "no kb.reading_maps in .agents/registry/project.json"
  }

  @doc """
  Build a context bundle for a work item and its capabilities.

  Options:

    * `:capabilities` — the capabilities to resolve context for. Required in
      practice; without them the bundle is repository trivia.
    * `:paths` — files the change touches.
    * `:limit` — items per section (default #{@max_items_per_section}).
    * `:kb` — how the knowledge-base hits every bundle carries may get their
      index: `:build` (the default) builds it when no cache holds it, which
      is seconds; `:cached` uses it only when it is in memory or on disk, and
      otherwise leaves the hits out and says so under *Not attached*. A
      caller on a hook path passes `:cached`.
  """
  @spec build(map(), keyword()) :: {:ok, bundle()} | {:error, String.t()}
  def build(work, opts \\ []) do
    with {:ok, registry} <- Registry.load() do
      capabilities = Keyword.get(opts, :capabilities, [])
      paths = Keyword.get(opts, :paths, work[:paths] || [])
      limit = Keyword.get(opts, :limit, @max_items_per_section)

      keys =
        capabilities
        |> Enum.flat_map(fn id -> get_in(registry.capabilities, [id, "context"]) || [] end)
        |> Enum.uniq()

      {sections, unresolved} =
        Enum.reduce(keys, {[], []}, fn key, {sections, unresolved} ->
          case resolve(key, work, paths, registry, limit) do
            {:ok, section} -> {[section | sections], unresolved}
            :handled_elsewhere -> {sections, unresolved}
            :unresolved -> {sections, [key | unresolved]}
          end
        end)

      # Earlier changes, K3-HAR-10 (A): every bundle for a real
      # task carries the reading map of the profile doing it, the glossary
      # terms its work names, and the knowledge-base records its title
      # matches, whatever its capabilities. They come first: they say what
      # to read, what the words mean and what the corpus already says, before
      # anything else in the bundle.
      {vocabulary, missing} =
        if capabilities == [],
          do: {[], []},
          else:
            vocabulary(work, paths, Keyword.get(opts, :profile, profile()), limit,
              kb: Keyword.get(opts, :kb, :build),
              pointers: "kb" in keys
            )

      {:ok,
       %{
         task: Map.take(work, [:id, :title, :body, :kind, :risk]),
         capabilities: capabilities,
         sections: (vocabulary ++ Enum.reverse(sections)) |> Enum.reject(&(&1.items == [])),
         unresolved: Enum.sort(missing ++ unresolved),
         skills: relevant_skills(registry, capabilities),
         memory: Memory.relevant(capabilities ++ (work[:scope] || []), limit: limit),
         generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  @doc "Render a bundle as the markdown that goes into a prompt."
  @spec render(bundle()) :: String.t()
  def render(bundle) do
    sections =
      Enum.map_join(bundle.sections, "\n", fn section ->
        items =
          Enum.map_join(section.items, "\n", fn item ->
            label =
              if item[:score], do: "- `#{item.path}` — #{item.score}", else: "- `#{item.path}`"

            case item.excerpt do
              nil -> label
              excerpt -> "#{label}\n\n```\n#{excerpt}\n```\n"
            end
          end)

        truncated = if section.truncated, do: "\n_(truncated; more exist)_\n", else: ""
        "### #{section.title}\n\n_#{section.why}_\n\n#{items}\n#{truncated}"
      end)

    unresolved =
      case bundle.unresolved do
        [] ->
          ""

        keys ->
          "\n### Not attached\n\nThese context sources were requested by the task's " <>
            "capabilities and could not be resolved here: " <>
            Enum.map_join(keys, ", ", &"`#{&1}`") <>
            ".\nIf you need one, say so rather than proceeding without it.\n"
      end

    memory =
      case bundle.memory do
        [] ->
          ""

        records ->
          body =
            Enum.map_join(records, "\n", fn record ->
              "- **#{record["title"]}** (#{record["kind"]}, #{record["confidence"]}, " <>
                "relevance #{record["relevance"]}) — #{record["body"]}"
            end)

          "\n### From project memory\n\n#{body}\n"
      end

    String.trim(sections <> unresolved <> memory)
  end

  # ---- resolvers -----------------------------------------------------------
  #
  # Each returns {:ok, section} | :unresolved | :handled_elsewhere.
  # One clause per context key declared in capabilities.json. A key with no
  # clause falls through to :unresolved, which is reported. Adding a capability
  # with a new context key and forgetting the resolver is therefore visible in
  # the bundle rather than being a silently thinner context.

  defp resolve("policies", _work, _paths, _registry, limit),
    do:
      glob_section(
        "policies",
        "Harness policies",
        "the policies that bind this work",
        [".agents/policies/*.md"],
        limit
      )

  defp resolve("target_module", _work, paths, _registry, limit),
    do:
      paths_section(
        "target_module",
        "The code this change touches",
        "files named by the work item",
        paths,
        limit
      )

  defp resolve("diff", _work, _paths, _registry, _limit) do
    case Git.diff_stat() do
      {:ok, ""} -> :unresolved
      {:ok, diff} -> {:ok, inline("diff", "Working tree", "what has already changed", diff)}
      :error -> :unresolved
    end
  end

  defp resolve("git_history", _work, paths, _registry, limit) do
    case Git.recent_commits(paths, limit) do
      {:ok, []} ->
        :unresolved

      {:ok, lines} ->
        {:ok,
         inline(
           "git_history",
           "Recent history",
           "commits touching these paths",
           Enum.join(lines, "\n")
         )}

      :error ->
        :unresolved
    end
  end

  defp resolve("callers", _work, paths, _registry, limit) do
    modules = paths |> Enum.flat_map(&module_names/1) |> Enum.uniq()

    # Git.grep/2 folds "matched nothing" into {:ok, []}, because `git grep`
    # exits 1 on no match and that is a result rather than a failure; `:error`
    # is git failing. Neither gives the bundle a section to show.
    case Git.grep(modules, limit) do
      {:ok, []} ->
        :unresolved

      :error ->
        :unresolved

      {:ok, lines} ->
        {:ok,
         inline(
           "callers",
           "Callers",
           "references to the modules this change touches",
           Enum.join(lines, "\n")
         )}
    end
  end

  defp resolve("tests", _work, paths, _registry, limit) do
    tests =
      paths
      |> Enum.map(&test_path_for/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&File.exists?(full(&1)))

    paths_section(
      "tests",
      "Existing tests",
      "the tests for the files this change touches",
      tests,
      limit
    )
  end

  defp resolve("existing_tests", work, paths, registry, limit),
    do: resolve("tests", work, paths, registry, limit)

  # The records that answer the work's title, when there are any,
  # in place of two pointers to documents about the knowledge base. A pointer
  # says the corpus exists; a hit says what it says about this work. When the
  # title matches nothing — or there is no `docs/kb/extraction/` — the
  # pointers are what is left, and they are still worth having.
  #
  # Since an earlier change every bundle carries the hits (`kb_section/4`), so the key
  # is handled there; what asking for it still adds is the pointers.
  defp resolve("kb", _work, _paths, _registry, _limit), do: :handled_elsewhere

  defp resolve("workflows", _work, _paths, _registry, limit),
    do:
      glob_section(
        "workflows",
        "Workflows",
        "the workflow definitions",
        [".agents/workflows/*.json"],
        limit
      )

  defp resolve("registry", _work, _paths, _registry, _limit),
    do:
      file_section("registry", "Registry derivation", "how roles get their capabilities", [
        ".agents/registry/role_rules.json"
      ])

  defp resolve("harness_context_rules", _work, _paths, _registry, _limit),
    do:
      file_section(
        "harness_context_rules",
        "Capability vocabulary",
        "what each capability pulls into context",
        [".agents/registry/capabilities.json"]
      )

  # Memory is attached as its own part of the bundle rather than as a section,
  # so these keys are satisfied elsewhere. They are named here so that they are
  # not reported as unresolved, which would be a lie in the other direction.
  defp resolve("memory", _work, _paths, _registry, _limit), do: :handled_elsewhere
  defp resolve("recent_failures", _work, _paths, _registry, _limit), do: :handled_elsewhere

  defp resolve("beads", _work, _paths, _registry, limit) do
    case Noetic.Harness.Beads.ready(limit) do
      {:ok, ""} ->
        :unresolved

      {:ok, output} ->
        {:ok, inline("beads", "Work graph", "what beads says is ready", output)}

      # A tracker that is stuck is not a tracker with nothing to say, and the
      # difference matters here more than anywhere: this is the block an agent
      # reads as "what work exists". 
      :timeout ->
        {:ok,
         inline(
           "beads",
           "Work graph",
           "what beads says is ready",
           "`bd` did not answer within #{div(Noetic.Harness.Beads.timeout(), 1000)}s. This " <>
             "section is empty because the tracker is stuck, not because there is no work."
         )}

      :error ->
        :unresolved

      # `beads` off in project.json: no work graph, reported as
      # not attached like any source that could not be.
      :off ->
        :unresolved
    end
  end

  defp resolve("memory:" <> _scope, _work, _paths, _registry, _limit), do: :handled_elsewhere

  # Every other key is the project's to answer: its sources are
  # `.agents/registry/project.json`'s `context` table, which is the table the
  # development repository had in this module, moved unchanged. A key the project does
  # not declare is `:unresolved`, and reported, as an unknown key always was.
  defp resolve(key, work, paths, _registry, limit) do
    case Project.context_source(key) do
      %{"kind" => "docs", "key" => at} = source ->
        docs_section(at, source["title"], source["why"], source["glob"], work, paths, limit)

      %{"kind" => "files", "key" => at} = source ->
        file_section(at, source["title"], source["why"], source["paths"])

      %{"kind" => "glob", "key" => at} = source ->
        glob_section(at, source["title"], source["why"], source["globs"], limit)

      nil ->
        :unresolved
    end
  end

  # ---- the glossary and the reading map ---------------------------
  #
  # The cap, and why it is this size:
  #   - terms: at most five, each shown as its id, names, status and link,
  #     with at most 300 bytes of its definition. About 2.2 KB at the
  #     outside, which is the budget the `kb` section keeps (below): the cost
  #     of the two document headlines a section used to be. A title names two
  #     or three terms of this project's own; past five, the matches are
  #     common words that happen to be a term's name ("world", "call").
  #   - the reading map: one file, with its "If you read only five" list as
  #     the excerpt, at most `@max_excerpt_bytes` like any other headline.
  #     The map is a pointer; reading it is the agent's next act.
  #   - both obey the bundle's `:limit` as well, whatever the profile, and
  #     say so when they cut. Without a profile the reading-map section lists
  #     every map, one per profile, and six maps against a limit of two was
  #     a section over its budget with `truncated: false` (returned from
  #     landing: the lane ran with `HARNESS_AGENT` set and never saw it).
  @terms_max 5
  @term_definition_bytes 300

  defp vocabulary(work, paths, profile, limit, kb) do
    {terms, terms_missing} = terms_section(work, paths, limit)
    {map, map_missing} = reading_map_section(profile, limit)
    {hits, kb_missing} = kb_section(work, limit, kb[:kb], kb[:pointers])

    {Enum.reject([map, terms, hits], &is_nil/1), terms_missing ++ map_missing ++ kb_missing}
  end

  defp terms_section(work, paths, limit) do
    text = Enum.join([work[:title] || "" | Enum.map(paths, &path_words/1)], " ")

    case Noetic.Harness.KB.Glossary.terms() do
      {:ok, terms} ->
        case Noetic.Harness.KB.Glossary.named_in(terms, text) do
          [] ->
            {nil, []}

          named ->
            kept = Enum.take(named, min(limit, @terms_max))

            {%{
               key: "terms",
               title: "Terms",
               why:
                 "glossary terms the title and paths name (#{Noetic.Harness.KB.Glossary.path()}); " <>
                   "a contested term is a question for the person, not an answer",
               items: Enum.map(kept, fn {term, _key} -> term_item(term) end),
               truncated: length(named) > length(kept)
             }, []}
        end

      # Said, not silent: a bundle without the terms section because there is
      # no glossary reads the same as one whose title names no term, unless
      # the bundle says which.
      {:error, :absent} ->
        {nil, ["terms (no #{Noetic.Harness.KB.Glossary.path() || @unconfigured["glossary"]})"]}

      {:error, reason} ->
        {nil, ["terms (#{reason})"]}
    end
  end

  # A path names what its file and the directory it sits in name, not what
  # its route there does: every file under `apps/my_app/` would otherwise
  # name a term called `my_app`.
  defp path_words(path) do
    parts = Path.split(path)
    dir = parts |> Enum.drop(-1) |> List.last()
    Enum.join([dir || "", Path.rootname(List.last(parts) || "")], " ")
  end

  defp term_item(term) do
    %{
      path: "#{term.id} — #{term.en} · #{term.ru} (#{term.status}) → #{term.link}",
      excerpt: clip(term.definition, @term_definition_bytes),
      score: nil
    }
  end

  # The profile is `HARNESS_AGENT`, which a cloud worker's environment sets
  # (CLAUDE.md, *If you are a cloud worker*). A local session has none, and is
  # shown where the maps are rather than none of them.
  defp profile do
    case System.get_env("HARNESS_AGENT") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  # No `kb.reading_maps` in the project is no maps, and says so only where a
  # profile asked for one: without a profile, no maps was always silent.
  defp reading_map_section(profile, limit) do
    case Project.kb("reading_maps") do
      nil when is_nil(profile) -> {nil, []}
      nil -> {nil, ["reading_map (#{@unconfigured["reading_maps"]})"]}
      dir -> reading_map_section(profile, limit, dir)
    end
  end

  defp reading_map_section(nil, limit, dir) do
    case wildcard(Path.join(dir, "*.md")) do
      [] ->
        {nil, []}

      maps ->
        {%{
           key: "reading_map",
           title: "Reading maps",
           why:
             "no HARNESS_AGENT, so no profile: one map per profile, " <>
               "each naming what to read before building, decided or proposed",
           items:
             maps
             |> Enum.take(limit)
             |> Enum.map(&%{path: relative(&1), excerpt: nil, score: nil}),
           truncated: length(maps) > limit
         }, []}
    end
  end

  defp reading_map_section(profile, _limit, dir) do
    path = Path.join(dir, "#{profile}.md")

    case File.read(full(path)) do
      {:ok, content} ->
        {%{
           key: "reading_map",
           title: "Reading map: #{profile}",
           why: "what the #{profile} profile reads before it builds, and which of it is decided",
           items: [%{path: path, excerpt: first_five(content), score: nil}],
           truncated: false
         }, []}

      {:error, _} ->
        {nil, ["reading_map (no #{path})"]}
    end
  end

  # The map's own "If you read only five" section, when it has one; its
  # headline otherwise. Cut at a line, never inside one, under the cap.
  defp first_five(content) do
    lines =
      case Regex.run(~r/^## If you read only five\s*\n(.*?)(?=^---|^## )/ms, content) do
        [_, block] -> block |> String.trim() |> String.split("\n")
        nil -> content |> String.split("\n") |> Enum.reject(&(&1 == "")) |> Enum.take(12)
      end

    {kept, _} =
      Enum.reduce_while(lines, {[], 0}, fn line, {acc, size} ->
        if size + byte_size(line) + 1 > @max_excerpt_bytes,
          do: {:halt, {["…" | acc], size}},
          else: {:cont, {[line | acc], size + byte_size(line) + 1}}
      end)

    kept |> Enum.reverse() |> Enum.join("\n")
  end

  # ---- the knowledge base ----------------------------------------------------

  # The cap on the `kb` section, and why it is this size: at most five hits,
  # each shown as its id, group and first source with at most 240 bytes of
  # matched text. That is ~2 KB at the
  # outside, which is less than the two headlines it replaces
  # (2 × `@max_excerpt_bytes`, 2.4 KB): answering the question must not make
  # the bundle bigger than pointing at where the answer might be. More is one
  # `noetic-harness kb` away, and the section's `why` says so.
  #
  # Every bundle carries it since an earlier change, not only the four capabilities
  # that ask for `kb`, and it keeps the bundle's `:limit` like every other
  # section. What that costs, measured over five routed titles at the default
  # limit: the section rendered at 1 627–1 950 bytes, five hits each, in
  # bundles of 8.5–31 KB; the five together were 3 594 tokens of a model's
  # context, read from its own usage between turns, so ~720 tokens a bundle.
  # The corpus is half Russian, ~2.5 bytes a token, and at the cap the
  # section is ~2.2 KB, ~880 tokens.
  @kb_hits 5
  @kb_excerpt_bytes 240

  # The section, and what to say under *Not attached* when it is missing for
  # a reason the reader should know. `pointers` is whether a capability asked
  # for `kb`: those bundles keep the two files that say how the corpus is
  # organised when the title matches nothing, as they did before.
  defp kb_section(work, limit, mode, pointers) do
    case kb_hits(work, min(limit, @kb_hits), mode) do
      {:ok, section} ->
        {section, []}

      {:none, missing} ->
        {if(pointers, do: kb_pointers()), missing}
    end
  end

  defp kb_pointers do
    case Enum.reject([Project.kb("readme"), Project.kb("guide")], &is_nil/1) do
      [] ->
        nil

      files ->
        case file_section(
               "kb",
               "Knowledge base",
               "how the corpus is organised and queried",
               files
             ) do
          {:ok, section} -> section
          :unresolved -> nil
        end
    end
  end

  defp kb_hits(work, limit, mode) do
    title = work[:title]

    with true <- is_binary(title) and String.trim(title) != "",
         {:ok, %{hits: [_ | _] = hits} = result} <-
           Noetic.Harness.KB.query(title, limit: limit, probe: false, cached: mode == :cached) do
      {:ok,
       %{
         key: "kb",
         title: "Knowledge base",
         why:
           "records of #{Project.kb("extraction")} matching the title, from the files " <>
             "(index #{String.slice(result.index.hash, 0, 12)}); " <>
             "`noetic-harness kb \"<words>\"` asks for more",
         items: Enum.map(hits, &kb_item/1),
         truncated: result.total > length(hits)
       }}
    else
      # Said, not silent: a hook-path bundle without hits because nothing had
      # built the index reads the same as one whose title matched nothing,
      # unless the bundle says which.
      {:error, :not_cached} ->
        {:none,
         [
           "kb (no cached index, and this bundle does not build one: " <>
             "`noetic-harness kb <words>` builds it)"
         ]}

      _ ->
        {:none, []}
    end
  end

  defp kb_item(hit) do
    source =
      case hit.sources do
        [%{path: path} | _] -> " ← #{path}"
        [] -> ""
      end

    %{
      path: "#{hit.id} (#{hit.kind}, #{hit.group})#{source}",
      excerpt: clip(hit.matched, @kb_excerpt_bytes),
      score: "score #{hit.score}"
    }
  end

  # Cut on a character boundary: the text is mostly Russian, two bytes a
  # letter, and `binary_part/3` would split one.
  defp clip(text, bytes) when byte_size(text) <= bytes, do: text

  defp clip(text, bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, size} ->
      if size + byte_size(g) > bytes - 3,
        do: {:halt, {acc, size}},
        else: {:cont, {acc <> g, size + byte_size(g)}}
    end)
    |> elem(0)
    |> Kernel.<>("…")
  end

  # ---- section builders ----------------------------------------------------

  defp docs_section(key, title, why, glob, work, paths, limit) do
    terms = terms(work, paths)

    matches =
      glob
      |> wildcard()
      |> Enum.map(&{&1, score(&1, terms)})
      |> Enum.reject(fn {_path, score} -> score == 0 end)
      |> Enum.sort_by(fn {_path, score} -> -score end)
      |> Enum.map(fn {path, score} -> {path, "matched #{score} of #{length(terms)} terms"} end)

    build_section(key, title, why, matches, limit, :headline)
  end

  defp glob_section(key, title, why, globs, limit) do
    matches = globs |> Enum.flat_map(&wildcard/1) |> Enum.uniq() |> Enum.sort()
    build_section(key, title, why, matches, limit, :none)
  end

  defp file_section(key, title, why, files) do
    matches = files |> Enum.map(&full/1) |> Enum.filter(&File.exists?/1)
    build_section(key, title, why, matches, length(files), :headline)
  end

  defp paths_section(key, title, why, paths, limit) do
    matches = paths |> Enum.map(&full/1) |> Enum.filter(&File.exists?/1)
    build_section(key, title, why, matches, limit, :headline)
  end

  defp build_section(_key, _title, _why, [], _limit, _mode), do: :unresolved

  defp build_section(key, title, why, matches, limit, mode) do
    kept = Enum.take(matches, limit)

    {:ok,
     %{
       key: key,
       title: title,
       why: why,
       items: Enum.map(kept, &item(&1, mode)),
       truncated: length(matches) > length(kept)
     }}
  end

  # A ranked section used to keep the order and drop the number
  # that produced it, so nobody could see that the top document matched two
  # terms of nine. `score` is that number, in words; `nil` where nothing ranked.
  defp item({path, score}, mode),
    do: %{path: relative(path), excerpt: excerpt(path, mode), score: score}

  defp item(path, mode), do: %{path: relative(path), excerpt: excerpt(path, mode), score: nil}

  defp inline(key, title, why, body) do
    %{
      key: key,
      title: title,
      why: why,
      items: [%{path: "(command output)", excerpt: String.slice(body, 0, @max_excerpt_bytes)}],
      truncated: byte_size(body) > @max_excerpt_bytes
    }
  end

  # The headline of a document is its first heading plus the paragraph under it:
  # enough for an agent to decide whether to open the file, which is the whole
  # job of a context bundle.
  defp excerpt(_path, :none), do: nil

  defp excerpt(path, :headline) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(12)
        |> Enum.join("\n")
        |> String.slice(0, @max_excerpt_bytes)

      _ ->
        nil
    end
  end

  defp relevant_skills(registry, capabilities) do
    wanted =
      capabilities
      |> Enum.flat_map(fn id -> get_in(registry.capabilities, [id, "skills"]) || [] end)
      |> Enum.uniq()
      |> MapSet.new()

    Skills.list() |> Enum.filter(&MapSet.member?(wanted, &1.name))
  end

  defp terms(work, paths) do
    ([work[:title], work[:body]] ++ paths)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    # Four characters here and three in `Memory`, on purpose (an earlier change asked
    # why they disagree). These terms are counted against whole documents,
    # where "the", "run" and "bug" occur in nearly every file and would rank
    # by length. `Memory` matches against a record's declared scope, whose
    # vocabulary *is* three letters — `otp`, `ash`, `sql`, `bd`'s neighbours.
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.uniq()
  end

  defp score(path, terms) do
    case File.read(path) do
      {:ok, content} ->
        haystack = String.downcase(content)
        Enum.count(terms, &String.contains?(haystack, &1))

      _ ->
        0
    end
  end

  defp module_names(path) do
    case File.read(full(path)) do
      {:ok, content} ->
        Regex.scan(~r/^defmodule\s+([\w.]+)/m, content) |> Enum.map(&Enum.at(&1, 1))

      _ ->
        []
    end
  end

  # Where a module's test is: the project's layout (`Project.layout/0`) — `…/lib/x.ex` is `…/test/x_test.exs` here. No layout, no
  # tests to name.
  defp test_path_for(path), do: test_path_for(path, Project.layout())

  defp test_path_for(_path, nil), do: nil

  defp test_path_for(path, layout) do
    lib = "/" <> layout.lib <> "/"

    cond do
      String.ends_with?(path, layout.test_suffix) ->
        nil

      String.contains?(path, lib) ->
        path
        |> String.replace(lib, "/" <> layout.test <> "/")
        |> String.replace(~r/\.ex$/, layout.test_suffix)

      true ->
        nil
    end
  end

  # In a git work tree, the files git would show — tracked, or untracked and
  # not ignored — rather than a walk of the disk. `**/*.tql` through
  # `Path.wildcard/1` took 3.7 s here: Erlang lists every directory under
  # `deps/`, `_build/` and `node_modules/` through the one file-server
  # process, and nine async context tests queued on it until one passed
  # ExUnit's 60 s. It also found `.tql` copies in `deps/` and test scratch
  # directories, which are not this repository's schema. `Git.grep/2` is
  # `git grep` for the same reason. Outside a work tree — a fixture root —
  # the disk is all there is.
  defp wildcard(glob) do
    case Git.files(glob) do
      {:ok, paths} -> Enum.map(paths, &full/1)
      :error -> Path.wildcard(full(glob))
    end
  end

  defp full(path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(Noetic.Harness.root(), path)
  end

  defp relative(path), do: Path.relative_to(path, Noetic.Harness.root())
end
