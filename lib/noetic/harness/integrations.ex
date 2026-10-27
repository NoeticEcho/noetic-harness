defmodule Noetic.Harness.Integrations do
  @moduledoc """
  What the harness may reach outside itself: switches in
  `.agents/registry/project.json`'s `integrations`.

  | Switch | What it turns on | Off |
  |---|---|---|
  | `beads` | `bd`: the work graph SessionStart and `context` show, `route --bead`, `prompt --task`, telemetry's `--file`, the bead side of `assign` | every `bd` call answers `:off` and its caller says so; nothing runs `bd` |
  | `knowledge_base` | probing the knowledge store (Postgres) and Qdrant beside a `kb` answer | `kb` answers from the files, as it always does, and says the stores were not asked |
  | `jido` | the `jido` dispatch adapter, whose module lives in another application | a dispatch configured for `jido` is unavailable, and says why |
  | `workers` | the coordinator and cloud-worker protocol: `assign`, its coordination records, profiles | `assign` says so and does nothing; `validate` does not check profiles or coordination records |

  ## On only when the project says so

  A repository with no `project.json`, or none of these, has every one of
  them off, as it has no knowledge base and no layout (`Noetic.Harness.Project`):
  an integration is a thing the project has, and the engine does not assume
  the development repository's. There all four are on, and the harness
  answers as it did.

  ## Off is said, never silent

  Each place that needs an integration names it when it is off, in one
  sentence (`off/1`), rather than failing the way a missing `bd` fails.
  `route`, `context`, `gates`, `run` and `conduct` need none of them, and
  `Noetic.Harness.BareRepositoryTest` holds that on a repository with every
  one off.

  ## A switch that was renamed

  A switch keeps its old name for one release after a rename (`@renamed`),
  so that a `project.json` written before it still means what it meant:
  - the old name alone is read as the new one, and the first read of it
    warns once on stderr, naming the new name;
  - both names at once are refused: the switch is off, the first read says
    so naming both, and `validate` reports it as an error (`findings/1`).
    Neither is picked, because the file says two things and the engine
    cannot know which was meant;
  - `validate` warns about the old name alone, so the warning a long-lived
    process printed once is not the only place it is said.

  The warning is once per project file per BEAM (`:persistent_term`), not
  once per call: the hook and the resident harness ask on every prompt.
  """

  alias Noetic.Harness.Project

  @names ~w(beads knowledge_base jido workers)

  # {new name, old name, the first release that does not read the old name}.
  @renamed []

  @doc "The switches there are."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc """
  Whether `name` is on: `true` in `project.json`'s `integrations`, and
  nothing else. A renamed switch's old name is read as described in
  "A switch that was renamed".
  """
  @spec enabled?(String.t()) :: boolean()
  def enabled?(name) when name in @names do
    integrations =
      case get_in(Project.get(), ["integrations"]) do
        %{} = integrations -> integrations
        _ -> %{}
      end

    case read(integrations, name) do
      {:ok, value} ->
        value == true

      {:deprecated, old, until, value} ->
        warn_once({:deprecated, old}, deprecated(name, old, until))
        value == true

      {:conflict, old} ->
        warn_once({:conflict, old}, conflict(name, old) <> "; it is off until one is removed")
        false
    end
  end

  defp read(integrations, name) do
    case List.keyfind(@renamed, name, 0) do
      {^name, old, until} ->
        case {Map.has_key?(integrations, name), Map.has_key?(integrations, old)} do
          {true, true} -> {:conflict, old}
          {false, true} -> {:deprecated, old, until, integrations[old]}
          _ -> {:ok, integrations[name]}
        end

      nil ->
        {:ok, integrations[name]}
    end
  end

  @doc """
  What `validate` says about the renamed switches in a decoded `project.json`,
  at `label`: an error where both names are given, a warning where only the
  old one is. The schema says whether the names are switches at all.
  """
  @spec findings(map(), String.t()) :: [{:error | :warning, String.t()}]
  def findings(project, label) do
    case project do
      %{"integrations" => %{} = integrations} ->
        for {new, old, until} <- @renamed,
            Map.has_key?(integrations, old) do
          if Map.has_key?(integrations, new),
            do: {:error, "#{label}.integrations: " <> conflict(new, old)},
            else: {:warning, "#{label}.integrations: " <> deprecated(new, old, until)}
        end

      _ ->
        []
    end
  end

  defp deprecated(new, old, until),
    do:
      "#{old} is the old name of the #{new} switch, and #{until} will not read it; " <>
        "rename it to #{new}"

  defp conflict(new, old),
    do: "both #{new} and #{old} are given, and #{old} is the old name of #{new}: remove #{old}"

  defp warn_once(what, message) do
    key = {__MODULE__, :warned, Project.path(), what}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      IO.puts(:stderr, "warning: .agents/registry/project.json: " <> message)
    end

    :ok
  end

  @doc "What a caller that needs `name` says when it is off."
  @spec off(String.t()) :: String.t()
  def off(name) when name in @names, do: "#{name} is off in .agents/registry/project.json"
end
