defmodule Noetic.Harness.PlanesApartTest do
  @moduledoc """
  A root holding both planes, and the engine keeping them apart in it.

  The root is the starter pack with the editorial runtime pack merged into its
  registry, policies and workflows (`Noetic.Harness.RuntimePack.mixed_root!/2`).
  `validate` refuses a definition that mixes the planes; these tests are about
  what reaches the engine anyway, through each door a development process
  has:

  - **composition**: each role from its own plane's constitution, templates,
    archetypes and trust levels, and a mix refused rather than resolved;
  - **sync**: no coding-client adapter for a runtime role, whatever its
    `nucleus` says;
  - **runs**: `Run.start/1`, `noetic-harness run --start`, the conductor and the
    dispatcher cannot start or advance a runtime workflow;
  - **routing and staffing**: the router refuses a runtime workflow and a
    runtime capability, and no development step is staffed by a runtime role.

  Before an earlier change every one of these went through: a runtime role in this
  root was composed with the development constitution, a `nucleus: true`
  runtime role got a `.claude/agents/` file, and `run --start WF-101` opened a
  run.
  """

  # async: false: moves the harness root, and runs Mix tasks, whose shell is
  # global.
  use ExUnit.Case, async: false

  import Noetic.Harness.RuntimePack,
    only: [mixed_root!: 1, mixed_root!: 2, edit!: 3, update_role: 3]

  alias Noetic.Harness.{
    Adapters,
    Conductor,
    Dispatcher,
    Prompt,
    Registry,
    Router,
    Run,
    RuntimePack,
    Starter,
    Validation,
    Workflow
  }

  @runtime_constitution "# The constitution of a product's AI employees"
  @development_constitution "# Agent constitution"

  setup do
    previous = Noetic.Harness.root_override()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
    end)
  end

  defp errors(checks) do
    {:ok, findings} = Validation.run(checks)
    for {:error, message} <- findings, do: message
  end

  defp refusal(id, opts \\ []) do
    assert {:error, message} = Prompt.compose(id, opts)
    message
  end

  describe "the mixed root" do
    test "passes the definition checks: both planes, each consistent" do
      mixed_root!("valid")

      assert errors(~w(registry tools planes gates workflows prompts)a) == []
    end

    test "composes each role from its own plane" do
      dir = mixed_root!("compose")

      development = Prompt.compose!("engineering.implementer")
      assert development =~ @development_constitution
      refute development =~ @runtime_constitution

      # The development prompt is the one it is without the runtime plane
      # beside it: nothing the runtime plane adds reaches it.
      alone = Noetic.Harness.TestTmp.dir!("planes-starter-alone")
      on_exit(fn -> File.rm_rf(alone) end)
      {:ok, _} = Starter.install(alone, name: "mixed")
      Noetic.Harness.put_root(alone)
      assert Prompt.compose!("engineering.implementer") == development

      Noetic.Harness.put_root(dir)
      vocabulary = RuntimePack.development_vocabulary(Starter.source())
      all = RuntimePack.compositions()
      assert length(all) > length(RuntimePack.roles())

      for {id, workflow, step, prompt} <- all do
        assert prompt =~ @runtime_constitution, "#{id} #{workflow} #{step}"
        refute prompt =~ @development_constitution, "#{id} #{workflow} #{step}"
        assert {[], []} == RuntimePack.leaks(prompt, vocabulary), "#{id} #{workflow} #{step}"
      end
    end
  end

  describe "composition refuses" do
    test "a runtime role with a development workflow, and a development role with a runtime one" do
      mixed_root!("cross-workflow")

      assert refusal("editorial.card_copywriter", workflow: "WF-003", step: "reproduce") ==
               "editorial.card_copywriter is a runtime role, and WF-003 is a development " <>
                 "workflow: a prompt is composed from one plane"

      assert refusal("engineering.implementer", workflow: "WF-101", step: "draft") ==
               "engineering.implementer is a development role, and WF-101 is a runtime " <>
                 "workflow: a prompt is composed from one plane"
    end

    test "a runtime role in a development lane, or holding a development tool" do
      mixed_root!("lane-and-tool", fn agents ->
        edit!(agents, "registry/agents.json", fn doc ->
          update_role(
            doc,
            "editorial.proofreader",
            &Map.update!(&1, "tools", fn t -> t ++ ["edit"] end)
          )
        end)
      end)

      # Strings, not a regex: the public tree's cut rewrites a citation in a
      # message and in a test's copy of it alike, and one inside a regex as
      # words.
      lane = refusal("editorial.guardian", lane: "focused")

      assert String.starts_with?(
               lane,
               "editorial.guardian is a runtime role, and its prompt would grant the command gate "
             )

      assert lane =~ "the command gate format, "
      assert String.ends_with?(lane, ": a runtime prompt never does")

      assert refusal("editorial.proofreader") ==
               "editorial.proofreader is a runtime role, and its prompt would grant the " <>
                 "development tool edit: a runtime prompt never does"
    end

    test "a runtime role in a root with no runtime templates" do
      mixed_root!("no-templates", fn agents ->
        File.rm_rf!(Path.join(agents, "runtime/templates"))
      end)

      assert refusal("editorial.guardian") =~ "this root has no runtime templates"

      assert refusal("editorial.guardian") =~
               "never composed from the development plane's"

      assert Prompt.compose!("engineering.implementer") =~ @development_constitution
    end

    test "a manifest that is not its plane's" do
      mixed_root!("manifest-plane", fn agents ->
        edit!(agents, "runtime/templates/prompt/MANIFEST.json", &Map.delete(&1, "plane"))
      end)

      assert refusal("editorial.guardian") =~
               ~r/^editorial\.guardian is a runtime role, and .+MANIFEST\.json is the development plane's manifest/
    end

    test "a runtime preamble that is the development constitution, or a copy of it" do
      mixed_root!("preamble-path", fn agents ->
        edit!(
          agents,
          "runtime/templates/prompt/MANIFEST.json",
          &Map.put(&1, "preamble", "../../../constitution.md")
        )
      end)

      assert refusal("editorial.guardian") =~ "development"
      assert refusal("editorial.guardian") =~ ""

      mixed_root!("preamble-copy", fn agents ->
        File.cp!(
          Path.join(agents, "constitution.md"),
          Path.join(agents, "runtime/constitution.md")
        )
      end)

      assert refusal("editorial.guardian") =~ "copy"
    end

    test "runtime defaults that are missing, or borrowed from the development plane" do
      mixed_root!("defaults-missing", fn agents ->
        edit!(agents, "runtime/templates/prompt/MANIFEST.json", &Map.delete(&1, "defaults"))
      end)

      missing = refusal("editorial.guardian")
      assert missing =~ "non_scope"
      assert missing =~ ""

      mixed_root!("defaults-borrowed", fn agents ->
        edit!(agents, "runtime/templates/prompt/MANIFEST.json", fn doc ->
          put_in(doc, ["defaults", "evidence"], Prompt.development_defaults()["evidence"])
        end)
      end)

      borrowed = refusal("editorial.guardian")
      assert borrowed =~ "evidence"
      assert borrowed =~ ""
    end

    test "a runtime role in a root whose only archetypes or trust levels are the development plane's" do
      mixed_root!("no-archetypes", fn agents ->
        File.rm!(Path.join(agents, "runtime/archetypes.json"))
      end)

      assert refusal("editorial.guardian") =~ "this root has no runtime archetypes"

      mixed_root!("no-trust", fn agents ->
        File.rm!(Path.join(agents, "runtime/trust_levels.json"))
      end)

      assert refusal("editorial.guardian") =~ "this root has no runtime trust levels"
      assert Prompt.compose!("engineering.implementer") =~ @development_constitution
    end
  end

  describe "sync" do
    test "writes no coding-client adapter for a runtime role, whatever its nucleus says" do
      dir =
        mixed_root!("sync", fn agents ->
          edit!(agents, "registry/agents.json", fn doc ->
            update_role(doc, "editorial.guardian", &Map.put(&1, "nucleus", true))
          end)
        end)

      {:ok, registry} = Registry.load()

      assert Enum.map(Registry.nucleus(registry), & &1["id"])
             |> Enum.all?(&(not String.starts_with?(&1, "editorial.")))

      {:ok, written} = Adapters.sync(registry)
      relative = Enum.map(written, &Path.relative_to(&1, dir))

      assert Enum.any?(relative, &String.contains?(&1, "engineering.implementer"))
      refute Enum.any?(relative, &String.contains?(&1, "editorial"))

      for path <- written, Path.extname(path) == ".md" do
        refute File.read!(path) =~ "editorial.", Path.relative_to(path, dir)
      end

      index = File.read!(Path.join(dir, ".agents/AGENTS_INDEX.md"))
      assert index =~ "8 runtime roles are not listed"
      assert index =~ "`harness export` is their door"
    end
  end

  describe "runs" do
    test "Run.start/1 opens no run of a runtime workflow" do
      dir = mixed_root!("run-start")

      assert {:error, "no workflow WF-101" <> _} = Run.start(workflow: "WF-101", title: "a card")
      assert Path.wildcard(Path.join(dir, ".agents/runs/*.json")) == []
      assert {:ok, %{"workflow" => "WF-003"}} = Run.start(workflow: "WF-003", title: "a bug")
    end

    test "noetic-harness run --start names the rule" do
      mixed_root!("run-task")

      assert catch_exit(Mix.Tasks.Harness.Run.run(~w(--start WF-101 --title card))) ==
               {:shutdown, 1}

      assert_received {:mix_shell, :error,
                       [
                         "WF-101 is a runtime workflow, and the development engine never starts one: " <>
                           "a product runs it from `harness export`"
                       ]}
    end

    test "the conductor and the dispatcher cannot advance a run that names one" do
      dir = mixed_root!("dispatch")
      id = "run-2026-10-02-wf-101-by-hand"
      runs = Path.join(dir, ".agents/runs")
      File.mkdir_p!(runs)

      File.write!(
        Path.join(runs, id <> ".json"),
        JSON.encode!(%{
          "id" => id,
          "workflow" => "WF-101",
          "title" => "a card, written by hand",
          "lane" => "card",
          "status" => "open",
          "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "steps" => [],
          "dispatches" => [],
          "parent_run" => nil,
          "ephemeral" => true
        })
      )

      assert {:error, message} = Conductor.next(id)
      assert message =~ "WF-101"

      assert {:refused, [%{rule: "run", why: why}]} = Dispatcher.prepare(id)
      assert why =~ "WF-101"
    end
  end

  describe "routing and staffing" do
    test "the router refuses a runtime workflow, by its rule" do
      mixed_root!("route-workflow")

      assert Router.route(title: "write a product card", workflow: "WF-101") ==
               {:error,
                "WF-101 is a runtime workflow, and the development engine never routes to one: " <>
                  "a product runs it from `harness export`"}
    end

    test "the router refuses work whose signals name a runtime capability" do
      mixed_root!("route-signal", fn agents ->
        edit!(agents, "registry/signals.json", fn doc ->
          Map.update!(doc, "signals", fn signals ->
            signals ++
              [%{"id" => "card", "text" => "product card", "capabilities" => ["copy.draft"]}]
          end)
        end)
      end)

      assert {:error, message} = Router.route(title: "write a product card")
      assert message =~ "the runtime capabilities copy.draft come from the signals card"
      assert message =~ ""

      assert {:ok, _} = Router.route(title: "fix a failing test")
    end

    test "no development step is staffed by a runtime role" do
      mixed_root!("staffing")
      {:ok, registry} = Registry.load()

      assert Router.compose_team(registry, ["copy.draft"]) == {[], ["copy.draft"]}
      assert Registry.supplying(registry, ["copy.draft"]) == []

      assert registry
             |> Registry.supplying(["copy.draft"], "runtime")
             |> Enum.map(& &1["id"])
             |> Enum.sort() ==
               ["editorial.card_copywriter", "editorial.letter_author"]

      assert Conductor.who(%{"capabilities" => ["copy.draft"]}) == :none
      assert {:ok, %{"id" => _}} = Conductor.who(%{"capabilities" => ["code.implementation"]})
    end

    test "Workflow.fetch/1 is the development engine's door" do
      mixed_root!("fetch")

      assert Workflow.fetch("WF-101") == :error
      assert {:ok, %{"plane" => "runtime"}} = Workflow.fetch("WF-101", "runtime")
      assert {:ok, %{"id" => "WF-003"}} = Workflow.fetch("WF-003")
      assert Workflow.fetch("WF-003", "runtime") == :error
    end
  end
end
