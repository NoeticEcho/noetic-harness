defmodule Noetic.Harness.Memory do
  @moduledoc """
  Project memory: append-only, provenance-carrying records that the Context
  Builder can inject automatically.

  ## Why this exists beside `bd remember`

  Beads holds insights a human or an agent will look up by hand. This store
  holds the ones the harness must be able to *retrieve without being asked* —
  by capability, by scope, when assembling context for a task that is about to
  repeat a mistake. A store nothing routes on is a diary; this one is indexed.

  ## Append-only, and why the rule is enforced here

  `append/1` writes a new file. `retire/3` sets `status` and `superseded_by` and
  touches nothing else. There is no update and no delete, because the value of
  the store is that you can see what this project used to believe and when it
  stopped. An LLM quietly rewriting project history is the specific failure this
  shape prevents.

  A record carries `confidence` — `observed`, `inferred` or `reported` — and
  that is not decoration. `observed` means a session watched it happen;
  `reported` means a document said so and nothing checked it. An agent citing a
  `reported` record has to say so.

  ## Storage

  One JSON file per record under `.agents/memory/records/`, named by id. Files
  rather than a database: they diff, they merge, they survive a container, and
  they are readable without the harness. There is no index file — the directory
  is the index, for the same reason skills have no index.
  """

  alias Noetic.Harness.Loader

  @kinds ~w(lesson decision rejected_approach failure benchmark constraint package_rule incident)
  @confidences ~w(observed inferred reported)

  @type memory_record :: map()

  @doc "Every record, newest first. `:all` includes retired ones."
  @spec list(keyword()) :: [memory_record()]
  def list(opts \\ []) do
    include_retired = Keyword.get(opts, :all, false)

    dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&Loader.load/1)
    |> Enum.flat_map(fn
      {:ok, record} -> [record]
      {:error, _} -> []
    end)
    |> Enum.filter(&(include_retired or &1["status"] == "current"))
    |> Enum.sort_by(& &1["created_at"], :desc)
  end

  @doc """
  Records whose scope matches any of the given terms.

  Matching is on the record's declared `scope`, then on its title and body — in
  that order of confidence. A record that named its scope is more likely to be
  about your task than one that merely mentions the word.
  """
  @spec relevant([String.t()], keyword()) :: [memory_record()]
  def relevant(terms, opts \\ [])

  def relevant([], _opts), do: []

  def relevant(terms, opts) do
    limit = Keyword.get(opts, :limit, 8)
    needles = terms |> Enum.flat_map(&tokens/1) |> Enum.uniq()

    list(opts)
    |> Enum.map(fn record -> {record, relevance(record, needles)} end)
    |> Enum.reject(fn {_record, score} -> score == 0 end)
    |> Enum.sort_by(fn {_record, score} -> -score end)
    |> Enum.take(limit)
    # The score that ordered these, kept on the record rather than
    # discarded. Never written back — `relevant/2` returns copies.
    |> Enum.map(fn {record, score} -> Map.put(record, "relevance", score) end)
  end

  @doc "Free-text search over every record, including retired ones."
  @spec search(String.t()) :: [memory_record()]
  def search(query) do
    needle = String.downcase(query)

    list(all: true)
    |> Enum.filter(fn record ->
      String.contains?(String.downcase(record["title"] <> " " <> record["body"]), needle) or
        Enum.any?(record["scope"] || [], &String.contains?(String.downcase(&1), needle))
    end)
  end

  @doc """
  Append a record.

  Required: `:kind`, `:title`, `:body`, `:scope`, `:confidence`. The id is
  derived from the date and a slug of the title, so two records written on the
  same day about the same thing collide — which is the right outcome, because
  the second one is almost always a restatement rather than new knowledge.
  """
  @spec append(map()) :: {:ok, Path.t()} | {:error, String.t()}
  def append(attrs) do
    with :ok <- require_keys(attrs, [:kind, :title, :body, :scope, :confidence]),
         :ok <- validate_enum(attrs[:kind], @kinds, "kind"),
         :ok <- validate_enum(attrs[:confidence], @confidences, "confidence") do
      now = DateTime.utc_now()
      id = attrs[:id] || build_id(now, attrs[:title])
      path = Path.join(dir(), "#{id}.json")

      if File.exists?(path) do
        {:error,
         "#{id} already exists. Memory is append-only; write a new record or retire this one."}
      else
        record = %{
          "id" => id,
          "kind" => attrs[:kind],
          "title" => attrs[:title],
          "body" => attrs[:body],
          "scope" => List.wrap(attrs[:scope]),
          "provenance" =>
            Map.merge(
              %{"source" => "run"},
              stringify(attrs[:provenance] || %{})
            ),
          "confidence" => attrs[:confidence],
          "status" => "current",
          "superseded_by" => nil,
          "retired_reason" => nil,
          "created_at" => DateTime.to_iso8601(now),
          "version" => 1
        }

        File.mkdir_p!(dir())
        File.write!(path, Loader.pretty!(record))
        {:ok, path}
      end
    end
  end

  @doc """
  Retire a record: set its status, say why, and point at what replaced it.

  The body is left exactly as written. Retiring is how a fact stops being
  current; it is not how it stops having been believed.
  """
  @spec retire(String.t(), String.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, String.t()}
  def retire(id, reason, superseded_by \\ nil) do
    path = Path.join(dir(), "#{id}.json")

    with {:ok, record} <- Loader.load(path) do
      updated =
        record
        |> Map.put("status", "retired")
        |> Map.put("retired_reason", reason)
        |> Map.put("superseded_by", superseded_by)
        |> Map.update("version", 2, &(&1 + 1))

      File.write!(path, Loader.pretty!(updated))
      {:ok, path}
    end
  end

  @doc "Structural problems across the whole store."
  @spec validate() :: [String.t()]
  def validate do
    records = list(all: true)

    duplicates =
      records
      |> Enum.frequencies_by(& &1["id"])
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(fn {id, _} -> "memory: duplicate id #{id}" end)

    dangling =
      for record <- records,
          superseded = record["superseded_by"],
          superseded not in [nil, ""],
          not Enum.any?(records, &(&1["id"] == superseded)) do
        "memory: #{record["id"]} is superseded_by #{superseded}, which does not exist"
      end

    unreasoned =
      for record <- records,
          record["status"] == "retired",
          record["retired_reason"] in [nil, ""] do
        "memory: #{record["id"]} is retired with no reason — a retirement without a reason is a deletion"
      end

    duplicates ++ dangling ++ unreasoned
  end

  defp dir, do: Path.join(Noetic.Harness.agents_path("memory"), "records")

  defp relevance(record, needles) do
    scope = record["scope"] |> Enum.map(&String.downcase/1)
    text = String.downcase(record["title"] <> " " <> record["body"])

    scope_hits =
      Enum.count(needles, fn needle -> Enum.any?(scope, &String.contains?(&1, needle)) end)

    text_hits = Enum.count(needles, &String.contains?(text, &1))

    scope_hits * 3 + text_hits
  end

  defp tokens(term) do
    term
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    # Three, where `Context` uses four: a scope is short by nature (`otp`,
    # `ash`, `sql`), and a four-character floor would make those records
    # unfindable by the only word that names them. See `Context.terms/2`.
    |> Enum.reject(&(String.length(&1) < 3))
  end

  defp build_id(now, title) do
    date = now |> DateTime.to_date() |> Date.to_iso8601()

    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 48)

    "mem-#{date}-#{slug}"
  end

  defp require_keys(attrs, keys) do
    case Enum.reject(keys, &(attrs[&1] not in [nil, "", []])) do
      [] ->
        :ok

      missing ->
        {:error, "missing required fields: #{Enum.map_join(missing, ", ", &to_string/1)}"}
    end
  end

  defp validate_enum(value, allowed, field) do
    if value in allowed,
      do: :ok,
      else: {:error, "#{field} must be one of #{Enum.join(allowed, ", ")}, got #{inspect(value)}"}
  end

  # Nil-valued provenance keys are dropped rather than stored. A record with
  # `"agent": null` reads as "no agent" but validates as a type error, and the
  # schema caught exactly that on the first record written without --agent.
  defp stringify(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end
end
