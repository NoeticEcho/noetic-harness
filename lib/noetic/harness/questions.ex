defmodule Noetic.Harness.Questions do
  @moduledoc """
  The questions a decision model may be asked about this repository's own
  work, as versioned files (the addendum's Gaps 10, 14).

  A decision is comparable to another only when the *same question* produced
  both. "The same wording" is not that: a changed instruction, a changed
  option, a changed criterion is a new question, and an answer to the old one
  says nothing about the new. So every file under
  `.agents/decisions/questions/` carries its versions, each with the
  **fingerprint** of what made it that version — type, instructions, options
  and criteria, canonically encoded and hashed.

  `harness validate` recomputes the fingerprint of every question as it stands
  and compares it with the one recorded for its current version. A mismatch is
  an **error**, not a warning: the question was edited without being bumped,
  and every answer recorded against that version now claims to answer text it
  never saw. `noetic-harness questions --bump <id>` is the one way to change a
  question: it appends the new version with its fingerprint and leaves the old
  ones, because an old decision citing a version nobody can find is worse than
  one citing nothing — the knowledge store's rule, and the environments' (`source_paths`
  pinned, never rewritten).

  Pure data and `:crypto`; no dependency, like everything in this app.
  """

  @fingerprinted ~w(type instructions options criteria)

  @doc "Where the question files live."
  @spec dir() :: String.t()
  def dir, do: Noetic.Harness.agents_path(["decisions", "questions"])

  @doc "Every question file, decoded, in id order."
  @spec list() :: [map()]
  def list do
    dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      case Noetic.Harness.Loader.load(path) do
        {:ok, question} -> [Map.put(question, "_path", path)]
        {:error, _} -> []
      end
    end)
  end

  @doc """
  The fingerprint of a question's content: sha256 over the canonical JSON of
  #{Enum.map_join(@fingerprinted, ", ", &"`#{&1}`")}. Canonical means object
  keys sorted at every depth, so re-saving a file with its keys reordered does
  not change what it is.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(question) do
    question |> Map.take(@fingerprinted) |> Noetic.Harness.Canonical.hash()
  end

  @doc "The recorded version entry for the question's current `version`, or `nil`."
  @spec current(map()) :: map() | nil
  def current(question) do
    Enum.find(question["versions"] || [], &(&1["version"] == question["version"]))
  end

  @doc """
  What `harness validate` reports: an error for a question whose content does
  not match its current version, and for a current version with no record.
  """
  @spec check([map()]) :: [{:error, String.t()}]
  def check(questions \\ list()) do
    Enum.flat_map(questions, fn q ->
      id = q["id"]

      case current(q) do
        nil ->
          [
            {:error,
             "question #{id}: version #{inspect(q["version"])} has no entry in `versions`"}
          ]

        %{"fingerprint" => recorded} ->
          if recorded == fingerprint(q) do
            []
          else
            [
              {:error,
               "question #{id}@#{q["version"]} was edited without a new version: its content " <>
                 "no longer matches the fingerprint recorded for that version, so every answer " <>
                 "recorded against it now claims to answer text it never saw. " <>
                 "`noetic-harness questions --bump #{id}` makes the edit a new version."}
            ]
          end
      end
    end)
  end

  @doc """
  Record the question's current content as a new version, or as the first
  one. Returns the new version string. Refuses when nothing changed: a version
  bump with no change would make two versions of one question.
  """
  @spec bump(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def bump(id, reason) do
    case Enum.find(list(), &(&1["id"] == id)) do
      nil ->
        {:error, "no question #{id} in #{dir()}"}

      q ->
        print = fingerprint(q)
        versions = q["versions"] || []

        cond do
          Enum.any?(versions, &(&1["fingerprint"] == print)) ->
            {:error, "#{id}'s content is already recorded as a version; nothing to bump"}

          true ->
            next =
              versions
              |> Enum.map(&String.to_integer(&1["version"]))
              |> Enum.max(fn -> 0 end)
              |> Kernel.+(1)
              |> Integer.to_string()

            entry = %{
              "version" => next,
              "fingerprint" => print,
              "at" => Date.utc_today() |> Date.to_iso8601(),
              "why" => reason
            }

            updated =
              q
              |> Map.delete("_path")
              |> Map.put("version", next)
              |> Map.put("versions", versions ++ [entry])

            File.write!(q["_path"], Noetic.Harness.Loader.pretty!(updated))
            {:ok, next}
        end
    end
  end
end
