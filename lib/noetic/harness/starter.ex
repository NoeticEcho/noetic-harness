defmodule Noetic.Harness.Starter do
  @moduledoc """
  The starter pack, and writing it into a repository that has no `.agents/`.

  The pack is `priv/starter/.agents/`: archetypes, trust levels, schemas, about
  twenty signals, ten workflows, three lanes, thirty roles and nine skills. It
  names no language, and nothing in it came from the upstream specification
  drops whose origin is still open:
  every sentence was written for the starter. `StarterPackTest` holds that it
  names none of this repository's products, stack or people.

  An add-on is `priv/starter-addons/<name>/.agents/`. Its files are added to
  the pack's, and a JSON file the pack also has is a **fragment**: merged into
  the pack's file of the same name rather than replacing it.

  - a list of objects with an `"id"` gains the fragment's entries, and an entry
    whose id the pack already has is replaced by the fragment's;
  - a list of anything else gains the fragment's items it does not already hold;
  - an object is merged key by key, the same way;
  - anything else is the fragment's value.

  So the Elixir add-on adds a domain, three roles and three signals without
  restating the pack's thirty roles, and a pack change reaches every add-on.

  `full` is the full catalogue, `priv/full/.agents/`: the roles, capabilities,
  domains, skills and workflows the starter does not have, cut for the public
  tree. It is generated, not written by hand; `Noetic.Harness.Cut.FullPack`
  in the development repository says from what and how.

  ## Why the project commands are files under `.agents/bin/`

  The pack's gates must mean something in any language, and a gate's command is
  a string in `gates.json`. So `format`, `lint`, `build` and `test` run
  `.agents/bin/<name>`, and each requires a tool whose probe is `test -x` on
  that file. A repository that has not written one gets `unavailable` from the
  gate and `partial` from the lane, which is the truth about it; a default that
  passed would be a claim nobody checked. An add-on supplies the scripts for its
  language.

  ## What `install/2` does not do

  It never deletes. With `force: true` it overwrites the files the pack has and
  leaves every other file under `.agents/` alone: runs, memory, a role overlay
  written by hand. It writes nothing outside `.agents/`; the client adapters
  are `harness sync`'s, run when the user chooses.
  """

  alias Noetic.Harness.Loader

  @type file :: {String.t(), binary(), boolean()}

  @doc "Where the pack is."
  @spec source() :: Path.t()
  def source, do: Path.join([priv(), "starter", ".agents"])

  @doc """
  The add-ons there are, by name: those under `priv/starter-addons/`, and
  `full`, the full catalogue in `priv/full/`, when it is there.
  """
  @spec addons() :: [String.t()]
  def addons do
    dir = Path.join(priv(), "starter-addons")

    named =
      case File.ls(dir) do
        {:ok, names} -> Enum.filter(names, &File.dir?(Path.join(dir, &1)))
        {:error, _} -> []
      end

    full = if File.dir?(addon_source("full")), do: ["full"], else: []
    Enum.sort(named ++ full)
  end

  @doc """
  The files `install/2` would write, relative to the target's `.agents/`, as
  `{path, content, executable?}`, sorted by path.

  `:with` names add-ons; an unknown one is an error that lists the known ones.
  `:name` is written into `registry/project.json`.
  """
  @spec files(keyword()) :: {:ok, [file()]} | {:error, String.t()}
  def files(opts \\ []) do
    with {:ok, addons} <- known_addons(Keyword.get(opts, :with, [])) do
      base = read_tree(source())

      merged =
        Enum.reduce(addons, base, fn addon, acc ->
          addon
          |> addon_source()
          |> read_tree()
          |> Enum.reduce(acc, fn {path, {content, exec}}, tree ->
            Map.update(tree, path, {content, exec}, fn {existing, existing_exec} ->
              {merge_file(path, existing, content), existing_exec or exec}
            end)
          end)
        end)

      merged = if addons == [], do: merged, else: supplied_skills(merged)

      merged =
        case Keyword.get(opts, :name) do
          nil -> merged
          name -> Map.update!(merged, project_file(), fn {c, e} -> {named(c, name), e} end)
        end

      {:ok, merged |> Enum.map(fn {path, {c, e}} -> {path, c, e} end) |> Enum.sort()}
    end
  end

  @doc """
  Write the pack into `target`'s `.agents/`.

  Refuses when `target/.agents` exists and `force: true` was not given, and
  says which of the pack's files are already there. Returns what it wrote, and
  which of those replaced a file.
  """
  @spec install(Path.t(), keyword()) ::
          {:ok, %{written: [Path.t()], replaced: [Path.t()]}}
          | {:error, {:exists, [Path.t()]}}
          | {:error, String.t()}
  def install(target, opts \\ []) do
    agents = Path.join(target, ".agents")

    with :ok <- directory(target),
         {:ok, files} <- files(Keyword.put_new(opts, :name, Path.basename(Path.expand(target)))) do
      present = for {path, _, _} <- files, File.exists?(Path.join(agents, path)), do: path

      cond do
        File.exists?(agents) and not Keyword.get(opts, :force, false) ->
          {:error, {:exists, present}}

        true ->
          Enum.each(files, fn {path, content, exec} ->
            write(Path.join(agents, path), content, exec)
          end)

          {:ok, %{written: Enum.map(files, &elem(&1, 0)), replaced: present}}
      end
    end
  end

  # ---- reading --------------------------------------------------------------

  @doc """
  The engine's `priv/`: where the starter pack, its add-ons and the Claude
  Code plugin are. The application's priv directory once it is loaded, and
  the one beside this file's source before that.
  """
  @spec priv() :: Path.t()
  def priv do
    case :code.priv_dir(:noetic_harness) do
      {:error, _} -> Path.expand("../../../priv", __DIR__)
      dir -> List.to_string(dir)
    end
  end

  defp addon_source("full"), do: Path.join([priv(), "full", ".agents"])
  defp addon_source(name), do: Path.join([priv(), "starter-addons", name, ".agents"])

  defp known_addons(requested) do
    case requested -- addons() do
      [] ->
        {:ok, requested}

      unknown ->
        {:error,
         "no add-on named #{Enum.join(unknown, ", ")}. Known: #{Enum.join(addons(), ", ")}"}
    end
  end

  defp read_tree(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path ->
      %File.Stat{mode: mode} = File.stat!(path)
      {Path.relative_to(path, root), {File.read!(path), Bitwise.band(mode, 0o111) != 0}}
    end)
  end

  defp project_file, do: Path.join("registry", "project.json")

  # A role holds every skill its capabilities supply (`harness validate`). Two
  # packs can define one capability, and the later one wins, so after the
  # merge a role can hold a capability whose skills are not the ones its pack
  # gave it. The rule is derivable, so it is derived here, and the roles file
  # is rewritten only when a role gains a skill.
  defp supplied_skills(tree) do
    agents_path = Path.join("registry", "agents.json")
    caps_path = Path.join("registry", "capabilities.json")

    with {agents, exec} <- Map.get(tree, agents_path),
         {caps, _} <- Map.get(tree, caps_path) do
      supplied =
        caps
        |> JSON.decode!()
        |> Map.get("capabilities", [])
        |> Map.new(&{&1["id"], &1["skills"] || []})

      registry = JSON.decode!(agents)

      roles =
        Enum.map(registry["agents"], fn role ->
          skills = Enum.flat_map(role["capabilities"] || [], &Map.get(supplied, &1, []))
          Map.update(role, "skills", skills, &Enum.uniq(&1 ++ skills))
        end)

      if roles == registry["agents"],
        do: tree,
        else:
          Map.put(tree, agents_path, {Loader.pretty!(Map.put(registry, "agents", roles)), exec})
    else
      _ -> tree
    end
  end

  defp named(content, name) do
    content |> JSON.decode!() |> Map.put("name", name) |> Loader.pretty!()
  end

  # ---- merging --------------------------------------------------------------

  defp merge_file(path, base, fragment) do
    if Path.extname(path) == ".json",
      do: base |> JSON.decode!() |> merge(JSON.decode!(fragment)) |> Loader.pretty!(),
      else: fragment
  end

  @doc false
  def merge(base, fragment) when is_map(base) and is_map(fragment) do
    Map.merge(base, fragment, fn _key, b, f -> merge(b, f) end)
  end

  def merge(base, fragment) when is_list(base) and is_list(fragment) do
    if Enum.all?(base ++ fragment, &(is_map(&1) and Map.has_key?(&1, "id"))) do
      ids = MapSet.new(fragment, & &1["id"])
      Enum.reject(base, &MapSet.member?(ids, &1["id"])) ++ fragment
    else
      base ++ Enum.reject(fragment, &(&1 in base))
    end
  end

  def merge(_base, fragment), do: fragment

  # ---- writing --------------------------------------------------------------

  defp directory(target) do
    if File.dir?(target), do: :ok, else: {:error, "#{target} is not a directory"}
  end

  defp write(path, content, exec) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    if exec, do: File.chmod!(path, 0o755)
  end
end
