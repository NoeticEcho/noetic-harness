defmodule Noetic.Harness.Plugin do
  @moduledoc """
  The Claude Code plugin in `priv/plugin/`, and the half of it that is
  generated from the starter pack.

  The plugin's subagents are the starter pack's nucleus roles, made the way
  `harness sync` makes a repository's `.claude/agents/`, with one difference.
  A repository's agent file tells the role to read `.agents/constitution.md`
  first, because the repository has one. A plugin is installed where there may
  be no `.agents/` at all. So each plugin agent carries its whole composed
  prompt, `Noetic.Harness.Prompt.compose/1` with the constitution first, which
  is what `harness prompt <id>` prints and what a dispatched role receives.

  How, so that nothing is re-implemented here:

  1. `Noetic.Harness.Starter.install/2` writes the pack into a temporary root;
  2. `Noetic.Harness.Adapters.sync/2` writes that root's `.claude/agents/`,
     and each file's `description` is kept as the adapter wrote it, written as
     a double-quoted string. The adapter writes it plain, and a plain
     description with `: ` in it is not YAML a strict parser accepts, which
     the plugin directory's checklist asks for;
  3. the body is `Prompt.compose/1` in that root, under a banner that names
     `harness plugin`.

  The skills, the manifest and the README are written by hand. `mix
  harness.plugin` rewrites the agents, and `--check` says which differ from
  what the starter pack makes now. `PluginTest` runs the same comparison.

  It moved here from `test/support/` in an earlier change, where it had been because
  the epic that built it had no grant for `lib/`: a release carries the tool
  that keeps its plugin in step with its pack.
  """

  alias Noetic.Harness.{Adapters, Prompt, Registry, Starter}

  @banner "<!-- GENERATED from the harness starter pack by `harness plugin`. " <>
            "Do not edit: change the starter pack and run it again. -->"

  @doc "Where the plugin is: the engine's `priv/plugin`."
  @spec dir() :: Path.t()
  def dir, do: Path.join(Starter.priv(), "plugin")

  @doc "The banner every generated file carries."
  @spec banner() :: String.t()
  def banner, do: @banner

  @doc """
  The generated files, `%{path under the plugin => content}`, built in a
  temporary root. The caller's harness root is restored afterwards.
  """
  @spec files() :: %{String.t() => String.t()}
  def files do
    root =
      Path.join(
        System.tmp_dir!(),
        "harness-plugin-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    previous = Noetic.Harness.root_override()

    try do
      {:ok, _} = Starter.install(root, name: "plugin")
      Noetic.Harness.put_root(root)
      registry = Registry.load!()
      {:ok, _} = Adapters.sync(registry, only: :claude)

      for agent <- Registry.nucleus(registry), into: %{} do
        id = agent["id"]
        adapter = File.read!(Path.join([root, ".claude", "agents", "#{id}.md"]))
        ["", front, _rest] = String.split(adapter, "---\n", parts: 3)
        [description] = Regex.run(~r/^description: (.*)$/m, front, capture: :all_but_first)

        {"agents/#{id}.md",
         "---\nname: #{id}\ndescription: #{JSON.encode!(description)}\n---\n\n" <>
           @banner <> "\n\n" <> Prompt.compose!(id)}
      end
    after
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
      File.rm_rf(root)
    end
  end

  @doc """
  The generated files that differ from `files/0` in `dir`, and those `dir`
  has that nothing generates any more, sorted. Empty when the plugin is in
  step with the starter pack.
  """
  @spec drift(Path.t()) :: [String.t()]
  def drift(dir \\ dir()) do
    expected = files()

    on_disk =
      Map.new(Path.wildcard(Path.join(dir, "agents/*.md")), &{rel(&1, dir), File.read!(&1)})

    stale = for {path, content} <- expected, on_disk[path] != content, do: path
    orphaned = for path <- Map.keys(on_disk), not Map.has_key?(expected, path), do: path
    Enum.sort(stale ++ orphaned)
  end

  @doc "Write `files/0` into `dir`, replacing `agents/` whole. Returns the paths written."
  @spec write!(Path.t()) :: [String.t()]
  def write!(dir \\ dir()) do
    files = files()
    File.rm_rf!(Path.join(dir, "agents"))

    for {path, content} <- Enum.sort(files) do
      target = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content)
      path
    end
  end

  defp rel(path, dir), do: Path.relative_to(path, dir)
end
