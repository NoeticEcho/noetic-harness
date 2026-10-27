defmodule Noetic.Harness.RuntimePack do
  @moduledoc """
  The editorial runtime pack, `test/support/runtime_pack/.agents/`, and the
  roots the runtime-plane tests build from it (`RuntimePlaneTest`,
  `PlanesApartTest`).

  - `root!/2` is the pack alone, with the starter's schemas: a product's
    pack, runtime and nothing else.
  - `mixed_root!/2` is the starter pack with the editorial pack merged into
    it: one registry, one tool vocabulary, one gate file and one workflow
    directory holding both planes, and the runtime plane's constitution,
    templates, archetypes and trust levels under `.agents/runtime/`. It is the
    root a design decision says the field must keep apart, which before an earlier change
    nothing but `validate` did.

  `development_vocabulary/1` is what a development pack can put into a
  prompt, and `leaks/2` finds any of it in one.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Noetic.Harness.{Prompt, Registry, Starter}

  @fixture Path.expand("runtime_pack/.agents", __DIR__)

  @roles ~w(researcher inci_normaliser card_copywriter seo_editor guardian proofreader
            letter_author rule_clerk)

  @doc "The pack's directory."
  def fixture, do: @fixture

  @doc "The eight role ids."
  def roles, do: Enum.map(@roles, &("editorial." <> &1))

  @doc "A root of its own: the pack and the starter's schemas. `change` edits its `.agents/`."
  def root!(tag, change \\ fn _ -> :ok end) do
    dir = fresh!("runtime-plane-" <> tag)
    File.cp_r!(@fixture, Path.join(dir, ".agents"))
    File.cp_r!(Path.join(Starter.source(), "schemas"), Path.join(dir, ".agents/schemas"))
    change.(Path.join(dir, ".agents"))
    Noetic.Harness.put_root(dir)
    dir
  end

  @doc """
  A root holding both planes: the starter pack, and the editorial pack merged
  into its registry, policies and workflows, with the runtime plane's own
  constitution, templates, archetypes and trust levels under `.agents/runtime/`.
  """
  def mixed_root!(tag, change \\ fn _ -> :ok end) do
    dir = fresh!("planes-" <> tag)
    {:ok, _} = Starter.install(dir, name: "mixed")
    agents = Path.join(dir, ".agents")

    append!(agents, "registry/agents.json", "agents")
    append!(agents, "registry/capabilities.json", "capabilities")
    append!(agents, "registry/domains.json", "domains")
    append!(agents, "policies/tools.json", "tools")
    append!(agents, "policies/gates.json", "gates")
    append!(agents, "policies/gates.json", "lanes")

    for file <- File.ls!(Path.join(@fixture, "workflows")) do
      File.cp!(Path.join([@fixture, "workflows", file]), Path.join([agents, "workflows", file]))
    end

    File.cp_r!(Path.join(@fixture, "runtime"), Path.join(agents, "runtime"))

    File.cp!(
      Path.join(@fixture, "registry/archetypes.json"),
      Path.join(agents, "runtime/archetypes.json")
    )

    File.cp!(
      Path.join(@fixture, "policies/trust_levels.json"),
      Path.join(agents, "runtime/trust_levels.json")
    )

    change.(agents)
    Noetic.Harness.put_root(dir)
    dir
  end

  defp fresh!(tag) do
    dir = Noetic.Harness.TestTmp.dir!(tag)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp append!(agents, file, key) do
    from = @fixture |> Path.join(file) |> File.read!() |> JSON.decode!() |> Map.fetch!(key)
    edit!(agents, file, &Map.update!(&1, key, fn list -> list ++ from end))
  end

  @doc "Decode `file` under `agents`, apply `fun`, write it back."
  def edit!(agents, file, fun) do
    path = Path.join(agents, file)

    path
    |> File.read!()
    |> JSON.decode!()
    |> fun.()
    |> JSON.encode!()
    |> then(&File.write!(path, &1))
  end

  @doc "Apply `fun` to the role `id` in an agents document."
  def update_role(doc, id, fun) do
    Map.update!(doc, "agents", fn agents ->
      Enum.map(agents, &if(&1["id"] == id, do: fun.(&1), else: &1))
    end)
  end

  @doc """
  Every runtime role's prompt, standing and at each workflow step its
  capabilities let it take, in the current root: `{id, workflow, step, prompt}`.
  """
  def compositions do
    {:ok, registry} = Registry.load()

    for role <- Registry.on_plane(registry, "runtime"),
        {workflow, step} <- [{nil, nil} | steps_for(role)] do
      opts = if workflow, do: [workflow: workflow, step: step], else: []
      {role["id"], workflow, step, Prompt.compose!(role["id"], opts)}
    end
  end

  defp steps_for(role) do
    held = MapSet.new(role["capabilities"])

    for file <- Path.wildcard(Noetic.Harness.agents_path("workflows/*.json")),
        workflow = file |> File.read!() |> JSON.decode!(),
        workflow["plane"] == "runtime",
        step <- workflow["steps"],
        Enum.any?(step["capabilities"], &MapSet.member?(held, &1)),
        do: {workflow["id"], step["id"]}
  end

  @doc """
  What a development pack at `agents` (an `.agents/` directory) can put into
  a prompt.

  - **lines**: every line of its constitution, matched as a whole line.
  - **phrases**, matched anywhere: every line of three words or more of its
    constitution, of what its prompt templates write themselves (placeholders
    taken out), and of the text its archetypes and trust levels give a role;
    and every line of `Prompt.development_defaults/0`.
  - **ids**: its tools, gates, lanes, capabilities, roles, skills and
    workflows. A prompt writes an id in backticks or in bold, so those are
    the forms looked for; an id with a dot or a hyphen in it is distinctive
    enough to be looked for anywhere.
  """
  def development_vocabulary(agents) do
    read = fn file -> agents |> Path.join(file) |> File.read!() end
    json = fn file -> file |> read.() |> JSON.decode!() end

    templates =
      for file <- Path.wildcard(Path.join(agents, "templates/prompt/*.md")),
          line <- file |> File.read!() |> String.split("\n"),
          text = line |> String.replace(~r/\{\{[a-z0-9_.]+\}\}/, "") |> clean(),
          length(String.split(text)) >= 3,
          do: text

    archetypes =
      for archetype <- json.("registry/archetypes.json")["archetypes"],
          text <-
            [archetype["stance"], archetype["completion"]] ++
              archetype["evidence_required"] ++
              archetype["prohibited"] ++ Map.values(archetype["loop_notes"] || %{}),
          is_binary(text),
          do: clean(text)

    levels =
      for level <- json.("policies/trust_levels.json")["levels"],
          text <- [level["summary"]] ++ (level["may"] || []) ++ (level["may_not"] || []),
          is_binary(text),
          do: clean(text)

    defaults =
      Prompt.development_defaults()
      |> Map.values()
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.map(&clean/1)

    constitution =
      for line <- read.("constitution.md") |> String.split("\n"),
          text = clean(line),
          text =~ ~r/\p{L}/u,
          do: text

    long = fn texts -> Enum.filter(texts, &(length(String.split(&1)) >= 3)) end

    gates = json.("policies/gates.json")

    ids =
      Enum.map(json.("policies/tools.json")["tools"], & &1["id"]) ++
        Enum.map(gates["gates"], & &1["id"]) ++
        Enum.map(gates["lanes"], & &1["id"]) ++
        Enum.map(json.("registry/capabilities.json")["capabilities"], & &1["id"]) ++
        Enum.map(json.("registry/agents.json")["agents"], & &1["id"]) ++
        skill_names(agents) ++
        (agents |> Path.join("workflows/*.json") |> Path.wildcard() |> Enum.map(&workflow_id/1))

    %{
      lines: MapSet.new(constitution),
      phrases:
        (long.(constitution) ++ templates ++ long.(archetypes) ++ long.(levels) ++ defaults)
        |> Enum.uniq(),
      ids: Enum.uniq(ids)
    }
  end

  defp skill_names(agents) do
    agents
    |> Path.join("skills/*/SKILL.md")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
  end

  defp workflow_id(path), do: path |> Path.basename() |> String.slice(0, 6)

  # A line as a prompt carries it: no list or heading marker, no emphasis, one
  # space between words.
  defp clean(text) do
    text
    |> String.replace(~r/^\s*(?:[-*>]|#+|\d+\.)\s+/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  The development vocabulary found in `prompt`: `{lines and phrases, ids}`,
  both empty when there is none.
  """
  def leaks(prompt, %{lines: lines, phrases: phrases, ids: ids}) do
    flat = String.replace(prompt, ~r/\s+/, " ")

    found_lines =
      prompt
      |> String.split("\n")
      |> Enum.map(&clean/1)
      |> Enum.filter(&MapSet.member?(lines, &1))

    found_phrases = Enum.uniq(found_lines ++ Enum.filter(phrases, &String.contains?(flat, &1)))

    found_ids =
      for id <- ids,
          String.contains?(prompt, "`#{id}`") or String.contains?(prompt, "**#{id}**") or
            (id =~ ~r/[.-]/ and prompt =~ ~r/(?<![\w.-])#{Regex.escape(id)}(?![\w-])/),
          do: id

    {found_phrases, found_ids}
  end
end
