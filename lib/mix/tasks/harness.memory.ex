defmodule Mix.Tasks.Harness.Memory do
  @moduledoc """
  Project memory: what earlier work here learned.

      noetic-harness memory                            current records
      noetic-harness memory --all                      including retired ones
      noetic-harness memory --query typedb             search
      noetic-harness memory --add --kind lesson --title "..." --body "..." \
                         --scope typedb,storage --confidence observed
      noetic-harness memory --retire <id> --reason "..." --superseded-by <id>

  Append-only. There is no edit and no delete: a fact that stops being true is
  retired — dated, reasoned, pointed at its replacement — because the value of
  the store is that you can see what this project used to believe and why it
  stopped.
  """
  @shortdoc "Read and append project memory"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]
  alias Noetic.Harness.Memory

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          all: :boolean,
          query: :string,
          add: :boolean,
          retire: :string,
          kind: :string,
          title: :string,
          body: :string,
          scope: :string,
          confidence: :string,
          agent: :string,
          task: :string,
          reason: :string,
          superseded_by: :string
        ]
      )

    shell = Mix.shell()

    cond do
      opts[:add] -> add(shell, opts)
      id = opts[:retire] -> retire(shell, id, opts)
      query = opts[:query] -> print(shell, Memory.search(query))
      true -> print(shell, Memory.list(all: !!opts[:all]))
    end
  end

  defp print(shell, []), do: shell.info("(no records)")

  defp print(shell, records) do
    Enum.each(records, fn record ->
      marker = if record["status"] == "retired", do: "RETIRED ", else: ""

      shell.info("#{marker}#{record["id"]}")

      shell.info(
        "  #{record["kind"]} / #{record["confidence"]} / scope: #{Enum.join(record["scope"], ", ")}"
      )

      shell.info("  #{record["title"]}")
      shell.info("  #{record["body"]}")

      if record["status"] == "retired" do
        shell.info("  retired: #{record["retired_reason"]}#{superseded(record)}")
      end

      shell.info("")
    end)

    shell.info("#{length(records)} record(s)")
  end

  defp superseded(%{"superseded_by" => nil}), do: ""
  defp superseded(%{"superseded_by" => id}), do: " → #{id}"

  defp add(shell, opts) do
    attrs = %{
      kind: opts[:kind],
      title: opts[:title],
      body: opts[:body],
      scope: String.split(opts[:scope] || "", [",", " "], trim: true),
      confidence: opts[:confidence],
      provenance: %{source: "run", agent: opts[:agent], task: opts[:task]}
    }

    case Memory.append(attrs) do
      {:ok, path} -> shell.info("wrote #{Path.relative_to(path, Noetic.Harness.root())}")
      {:error, message} -> Mix.raise(message)
    end
  end

  defp retire(shell, id, opts) do
    reason =
      opts[:reason] ||
        Mix.raise("--reason is required: a retirement without a reason is a deletion")

    case Memory.retire(id, reason, opts[:superseded_by]) do
      {:ok, path} -> shell.info("retired #{Path.relative_to(path, Noetic.Harness.root())}")
      {:error, message} -> Mix.raise(message)
    end
  end
end
