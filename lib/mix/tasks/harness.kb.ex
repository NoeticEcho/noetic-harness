defmodule Mix.Tasks.Harness.Kb do
  @moduledoc """
  Ask the knowledge base: the records of `docs/kb/extraction/` that answer a
  question, with their sources.

      noetic-harness kb память героя
      noetic-harness kb "hooded cloak" --group G3
      noetic-harness kb onlooker --kind concept --limit 5
      noetic-harness kb --query "semantic physics" --json

  The query is the positional words, or `--query` (which is how the MCP tool
  `harness_kb_query` passes it). Russian and English both work; a record is
  found by the words it uses, so an English query finds a Russian record only
  through its id, an alias or a key term.

  Options:

    * `--limit N` — hits shown (default 10);
    * `--group G3` — one group, by short code or whole name;
    * `--kind concept` — one kind: document, concept, relation, requirement,
      decision, data_model, visual_directive, gap, contradiction, quote;
    * `--json` — the result as JSON, for a program.

  Answered from the files, always; the first lines say so, say whether the
  knowledge store and Qdrant were reachable, and say whether the index came from memory,
  from `.agents/cache/kb/` or was built just now, and how long each part took.
  `Noetic.Harness.KB` has the why.
  """
  @shortdoc "Ask the knowledge base, from the files"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever
  # beams the last compile left, and answers for code that is not on disk.
  @requirements ["compile"]

  alias Noetic.Harness.KB

  @impl Mix.Task
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(args,
        strict: [query: :string, limit: :integer, group: :string, kind: :string, json: :boolean]
      )

    text = opts[:query] || Enum.join(rest, " ")

    case KB.query(text, limit: opts[:limit], group: opts[:group], kind: opts[:kind]) do
      {:error, message} -> Mix.raise(message)
      {:ok, result} -> if opts[:json], do: json(result), else: print(result)
    end
  end

  defp json(result) do
    result
    |> Map.update!(:index, &Map.update!(&1, :from, fn from -> to_string(from) end))
    |> JSON.encode!()
    |> Mix.shell().info()
  end

  defp print(result) do
    shell = Mix.shell()
    index = result.index

    shell.info(
      "kb: #{inspect(result.query)} — #{length(result.hits)} of #{result.total} hit(s) · " <>
        "answered by #{result.backend}"
    )

    shell.info(
      "index #{String.slice(index.hash, 0, 12)} · #{index.records} records from #{index.files} file(s) · " <>
        "#{index.from} in #{index.load_ms} ms · query #{result.query_ms} ms"
    )

    Enum.each(result.backends, &shell.info("  #{&1.name}: #{&1.note}"))
    shell.info("")

    case result.hits do
      [] ->
        shell.info(
          "(no record uses these words: #{Enum.join(result.terms, ", ")}. " <>
            "Try the corpus's own language, or fewer words.)"
        )

      hits ->
        hits
        |> Enum.with_index(1)
        |> Enum.each(fn {hit, n} -> print_hit(shell, hit, n) end)
    end
  end

  defp print_hit(shell, hit, n) do
    title = if hit.title, do: " — #{String.slice(hit.title, 0, 100)}", else: ""

    shell.info("#{n}. #{hit.id}#{title}")

    also = if hit.also_in == [], do: "", else: " (also in #{Enum.join(hit.also_in, ", ")})"

    shell.info(
      "   #{hit.kind} · #{hit.group_name}#{also} · score #{hit.score} · matched in #{hit.field}"
    )

    shell.info("   #{hit.matched}")

    # A glossary term's entry in `docs/kb/glossary.md`, which is where its
    # full definition and its sources are. Only a term has one.
    if hit[:link], do: shell.info("   → #{hit.link}")

    Enum.each(Enum.take(hit.sources, 3), &shell.info("   ← #{source(&1)}"))

    if length(hit.sources) > 3, do: shell.info("   ← and #{length(hit.sources) - 3} more")
    shell.info("")
  end

  defp source(%{member: member, path: path}), do: "#{path} → #{member}"
  defp source(%{resolved: true, path: path}), do: path

  defp source(%{path: path}),
    do: "#{path} (as the extraction recorded it; not in this checkout)"
end
