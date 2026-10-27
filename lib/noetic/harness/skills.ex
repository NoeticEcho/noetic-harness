defmodule Noetic.Harness.Skills do
  @moduledoc """
  Skill discovery across both client roots.

  Skills are executable knowledge: what this repository has already decided
  about a domain, written so an agent reads it instead of reconstructing it from
  a general prior. They live in two places for a reason that is not ideological:

  | Root | Read by | Why |
  |---|---|---|
  | `.agents/skills/` | every client, and the harness | The canonical location. Codex, CI and a future machine find it. |
  | `.claude/skills/` | Claude Code natively | Skills Claude Code loads by itself, authored in place. |

  **There is no index file.** Discovery is a directory walk, because an index is
  a second place for the truth to live and it goes stale the first time someone
  adds a skill without updating it. `noetic-harness skills` walks the tree; the
  validator checks that every skill a role names is found by that walk.

  ## Progressive disclosure

  `list/0` returns names and descriptions — enough for a prompt to say what is
  available. `read/1` returns the body, and it is called when an agent actually
  needs the skill. Injecting every skill into every agent is how a context
  window fills with things nobody is going to read.
  """

  @type skill :: %{
          name: String.t(),
          description: String.t(),
          path: Path.t(),
          root: :agents | :claude,
          bytes: non_neg_integer()
        }

  @doc """
  Every skill found under either root, sorted by name.

  A skill is a directory containing `SKILL.md` with YAML front matter carrying
  `name` and `description`. A `SKILL.md` without front matter is reported with
  its directory name and an empty description rather than skipped — a
  malformed skill should be visible, not invisible.
  """
  @spec list() :: [skill()]
  def list do
    key = {__MODULE__, :list, Noetic.Harness.root()}

    case Process.get(key) do
      nil ->
        skills =
          [{:agents, Noetic.Harness.agents_path("skills")}, {:claude, claude_root()}]
          |> Enum.flat_map(fn {root, dir} -> discover(dir, root) end)
          |> Enum.sort_by(& &1.name)

        Process.put(key, skills)
        skills

      cached ->
        cached
    end
  end

  @doc "Skill names only."
  @spec names() :: [String.t()]
  def names, do: list() |> Enum.map(& &1.name)

  @doc "One skill by name."
  @spec fetch(String.t()) :: {:ok, skill()} | :error
  def fetch(name) do
    case Enum.find(list(), &(&1.name == name)) do
      nil -> :error
      skill -> {:ok, skill}
    end
  end

  @doc "The body of a skill, front matter stripped."
  @spec read(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(name) do
    case fetch(name) do
      {:ok, skill} -> {:ok, skill.path |> File.read!() |> strip_front_matter()}
      :error -> {:error, "no skill named #{name}"}
    end
  end

  @doc """
  Which of the given names are not on disk.

  The validator's whole use of this module: a role naming a skill that does not
  exist is the drift this design is meant to make impossible to ship.
  """
  @spec missing([String.t()]) :: [String.t()]
  def missing(wanted) do
    available = MapSet.new(names())
    wanted |> Enum.uniq() |> Enum.reject(&MapSet.member?(available, &1)) |> Enum.sort()
  end

  defp claude_root, do: Path.join(Noetic.Harness.root(), ".claude/skills")

  defp discover(dir, root) do
    dir
    |> Path.join("*/SKILL.md")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      raw = File.read!(path)
      meta = front_matter(raw)

      %{
        name: Map.get(meta, "name", Path.basename(Path.dirname(path))),
        description: Map.get(meta, "description", ""),
        path: path,
        root: root,
        bytes: byte_size(raw)
      }
    end)
  end

  # A deliberately small front-matter reader: `key: value` pairs between the
  # first two `---` lines. Skills use nothing more, and a YAML dependency to
  # parse four lines would be the harness acquiring a dependency to read its own
  # configuration.
  defp front_matter("---\n" <> rest) do
    case String.split(rest, "\n---", parts: 2) do
      [block, _body] ->
        block
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp front_matter(_), do: %{}

  defp strip_front_matter("---\n" <> rest) do
    case String.split(rest, "\n---", parts: 2) do
      [_block, body] -> String.trim_leading(body)
      _ -> rest
    end
  end

  defp strip_front_matter(raw), do: raw
end
