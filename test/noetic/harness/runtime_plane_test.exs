defmodule Noetic.Harness.RuntimePlaneTest do
  @moduledoc """
  The runtime plane on a runtime pack: the `plane` field and its validation,
  and an editorial team as a fixture pack, composed by the same
  `Prompt.compose/2` the development roles use.

  The pack is `test/support/runtime_pack/.agents/`: eight runtime roles, their
  eight capabilities, two workflows, runtime tools and gates that are never
  commands, and under `runtime/` the runtime constitution and prompt
  templates. It names no client, brand, rule or data. Each test builds a root
  of its own from it and the starter pack's schemas
  (`Noetic.Harness.RuntimePack`). A root holding both planes is
  `PlanesApartTest`'s.

  What §8.5's readiness criterion asks, and where it is held:

  - **The roles validate with one new field.** `plane` is the only key the
    editorial roles have that a development role does not, and every
    definition file of the pack passes the starter's schemas.
  - **No development text in a runtime prompt.** Nothing a development pack
    can put into a prompt (its constitution, what its templates and
    archetypes and trust levels write, the composer's development defaults,
    its tool, gate, lane, capability, role, skill and workflow ids) is in any
    runtime role's prompt, standing or at any step it can take.
  - **Each refusal fails validate, and its removal passes.** Every branch of
    the `planes` check, each by its exact message.

  **What `validate` cannot do yet on a runtime pack**: seven checks and seven
  files belong to the development process (the evaluator fence, pipelines,
  failure routing, dispatch, MCP, identity and the model families a review
  needs). The pack does not carry them, so the checks that read only
  definitions are the ones run here, and the schema check is held to report
  exactly those seven files missing and nothing else.
  """

  # async: false: moves the harness root, sets NOETIC_HARNESS_ROOT for one
  # test, and runs a Mix task, whose shell is global.
  use ExUnit.Case, async: false

  import Noetic.Harness.RuntimePack, only: [root!: 1, root!: 2, edit!: 3, update_role: 3]

  alias Noetic.Harness.{Prompt, RuntimePack, Starter, Validation}

  # The checks that read a pack's definitions. The rest read the development
  # process: the evaluator fence, pipelines, failure routing, the generated
  # coding-client adapters, MCP and the model families.
  @definition_checks ~w(registry overlays overlay_tool_claims overlay_authority skills tools
                        planes gates workflows prompts memory questions profiles)a

  @process_files ~w(policies/failure.json policies/evaluators.json policies/models.json
                    policies/dispatch.json policies/mcp.json policies/identity.json
                    pipelines/pipelines.json)

  @shell_gate %{
    "id" => "shell",
    "name" => "a shell command",
    "kind" => "command",
    "command" => "true",
    "severity" => "blocking"
  }

  @git_write %{
    "id" => "git.write",
    "kind" => "cli",
    "min_trust" => "T1",
    "present" => true,
    "doc" => "Commit to a branch."
  }

  setup do
    previous = Noetic.Harness.root_override()

    on_exit(fn ->
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
    end)
  end

  defp errors(checks \\ @definition_checks) do
    {:ok, findings} = Validation.run(checks)
    for {:error, message} <- findings, do: message
  end

  defp add(doc, key, items), do: Map.update!(doc, key, &(&1 ++ items))

  # WF-102 as a development workflow, WF-103, beside the runtime ones.
  defp development_copy!(agents, fun \\ & &1) do
    edit!(agents, "workflows/WF-102-letter.json", fn doc ->
      doc |> Map.delete("plane") |> Map.put("id", "WF-103") |> fun.()
    end)

    File.rename!(
      Path.join(agents, "workflows/WF-102-letter.json"),
      Path.join(agents, "workflows/WF-103-letter.json")
    )
  end

  describe "the editorial pack" do
    test "validates: its definitions are consistent, and every file passes the schemas" do
      root!("valid")
      assert errors() == []

      missing =
        for message <- errors([:schemas]) do
          assert message =~ "not found", message
          message |> String.replace(~r/^\.agents\/|: not found$/, "")
        end

      assert Enum.sort(missing) == Enum.sort(@process_files)
    end

    test "has eight runtime roles, whose only key a development role lacks is plane" do
      root!("roles")
      roles = Noetic.Harness.agents_path("registry/agents.json") |> File.read!() |> JSON.decode!()

      starter_keys =
        Path.join(Starter.source(), "registry/agents.json")
        |> File.read!()
        |> JSON.decode!()
        |> Map.fetch!("agents")
        |> Enum.flat_map(&Map.keys/1)
        |> MapSet.new()

      assert Enum.map(roles["agents"], & &1["id"]) == RuntimePack.roles()

      for role <- roles["agents"] do
        assert role["plane"] == "runtime"
        assert role["max_trust"] in ~w(T0 T1)

        assert MapSet.difference(MapSet.new(Map.keys(role)), starter_keys) ==
                 MapSet.new(["plane"])
      end
    end
  end

  describe "validate refuses" do
    test "a development tool on a runtime role, and passes again without it" do
      root!("git-write", fn agents ->
        edit!(agents, "policies/tools.json", &add(&1, "tools", [@git_write]))

        edit!(agents, "registry/agents.json", fn doc ->
          update_role(
            doc,
            "editorial.card_copywriter",
            &Map.update!(&1, "tools", fn t -> t ++ ["git.write"] end)
          )
        end)
      end)

      assert "editorial.card_copywriter: a runtime definition holds the development tool git.write" in errors()

      # The same tool defined, and no role holding it: valid.
      root!("git-write-defined", fn agents ->
        edit!(agents, "policies/tools.json", &add(&1, "tools", [@git_write]))
      end)

      assert errors() == []
    end

    test "a trust above draft on a runtime role, and passes again at draft" do
      root!("trust", fn agents ->
        edit!(agents, "registry/agents.json", fn doc ->
          update_role(doc, "editorial.guardian", &Map.put(&1, "max_trust", "T2"))
        end)
      end)

      assert "editorial.guardian: a runtime role may hold at most T1 (draft), not T2" in errors()

      root!("trust-draft", fn agents ->
        edit!(agents, "registry/agents.json", fn doc ->
          update_role(doc, "editorial.guardian", &Map.put(&1, "max_trust", "T1"))
        end)
      end)

      assert errors() == []
    end

    test "a development capability on a runtime role" do
      root!("dev-capability", fn agents ->
        edit!(agents, "registry/capabilities.json", fn doc ->
          add(doc, "capabilities", [
            %{"id" => "code.implementation", "doc" => "Change the code.", "tools" => []}
          ])
        end)

        edit!(agents, "registry/agents.json", fn doc ->
          update_role(
            doc,
            "editorial.seo_editor",
            &Map.update!(&1, "capabilities", fn c -> c ++ ["code.implementation"] end)
          )
        end)
      end)

      assert "editorial.seo_editor: a runtime role holds the development capability code.implementation" in errors()
    end

    test "a command gate on a runtime role or in a runtime workflow's step" do
      root!("command", fn agents ->
        edit!(agents, "policies/gates.json", &add(&1, "gates", [@shell_gate]))

        edit!(agents, "registry/agents.json", fn doc ->
          update_role(
            doc,
            "editorial.proofreader",
            &Map.update!(&1, "gates", fn g -> g ++ ["shell"] end)
          )
        end)

        edit!(agents, "workflows/WF-102-letter.json", fn doc ->
          Map.update!(doc, "steps", fn [first | rest] ->
            [Map.put(first, "gates", ["shell"]) | rest]
          end)
        end)
      end)

      found = errors()
      assert "editorial.proofreader: a runtime definition names the command gate shell" in found
      assert "workflow WF-102: a runtime workflow runs the command gate shell" in found
    end

    # `validation.ex`'s supply check, reached for a capability rather than a role.
    test "a runtime capability supplying a development tool or a command gate, and passes without them" do
      root!("capability-supply", fn agents ->
        edit!(agents, "policies/tools.json", &add(&1, "tools", [@git_write]))
        edit!(agents, "policies/gates.json", &add(&1, "gates", [@shell_gate]))

        edit!(agents, "registry/capabilities.json", fn doc ->
          Map.update!(doc, "capabilities", fn caps ->
            Enum.map(caps, fn
              %{"id" => "rules.propose"} = c ->
                c
                |> Map.update!("tools", &(&1 ++ ["git.write"]))
                |> Map.update!("gates", &(&1 ++ ["shell"]))

              c ->
                c
            end)
          end)
        end)
      end)

      found = errors()

      assert "capability rules.propose: a runtime definition holds the development tool git.write" in found

      assert "capability rules.propose: a runtime definition names the command gate shell" in found

      root!("capability-supply-defined", fn agents ->
        edit!(agents, "policies/tools.json", &add(&1, "tools", [@git_write]))
        edit!(agents, "policies/gates.json", &add(&1, "gates", [@shell_gate]))
      end)

      assert errors() == []
    end

    test "a runtime workflow naming a development capability" do
      root!("runtime-workflow-dev-capability", fn agents ->
        edit!(agents, "registry/capabilities.json", fn doc ->
          add(doc, "capabilities", [
            %{"id" => "code.implementation", "doc" => "Change the code.", "tools" => []}
          ])
        end)

        edit!(agents, "workflows/WF-102-letter.json", fn doc ->
          Map.update!(doc, "steps", fn [first | rest] ->
            [Map.update!(first, "capabilities", &(&1 ++ ["code.implementation"])) | rest]
          end)
        end)
      end)

      assert "workflow WF-102: a runtime workflow names the development capability code.implementation" in errors()
    end

    # Reached only through the lane: no step and no role names the gate.
    test "a command gate a runtime workflow's default lane runs" do
      root!("runtime-lane-command", fn agents ->
        edit!(agents, "policies/gates.json", fn doc ->
          doc
          |> add("gates", [@shell_gate])
          |> Map.update!("lanes", fn lanes ->
            Enum.map(lanes, fn
              %{"id" => "letter"} = lane -> Map.update!(lane, "gates", &(&1 ++ ["shell"]))
              lane -> lane
            end)
          end)
        end)
      end)

      assert errors() == ["workflow WF-102: a runtime workflow runs the command gate shell"]
    end

    test "a development workflow that names a runtime role or capability" do
      root!("dev-workflow", fn agents ->
        development_copy!(agents, fn doc ->
          Map.update!(doc, "escalations", fn e ->
            e ++ [%{"when" => "a claim is unclear", "to" => "editorial.guardian"}]
          end)
        end)
      end)

      found = errors()

      assert "workflow WF-103: a development workflow names the runtime role editorial.guardian" in found

      assert "workflow WF-103: a development workflow names the runtime capability copy.draft" in found
    end

    # The proofreader is named by no escalation: only `proof.review`'s holder
    # names it.
    test "a development workflow whose step gate is held by a runtime role" do
      root!("dev-workflow-holder", fn agents -> development_copy!(agents) end)

      assert "workflow WF-103: a development workflow names the runtime role editorial.proofreader" in errors()
    end

    test "a runtime workflow whose independence names a step it does not have" do
      root!("independence", fn agents ->
        edit!(agents, "workflows/WF-101-product-card.json", fn doc ->
          Map.update!(doc, "steps", fn steps ->
            Enum.map(steps, fn
              %{"id" => "proofread"} = step -> Map.put(step, "independent_of", ["drafting"])
              step -> step
            end)
          end)
        end)
      end)

      assert Enum.any?(errors(), &(&1 =~ "WF-101/proofread: independent_of names step drafting"))
    end
  end

  describe "composed by the same Prompt.compose/2" do
    defp assert_no_development(vocabulary) do
      all = RuntimePack.compositions()
      assert length(all) > length(RuntimePack.roles())

      for {id, workflow, step, prompt} <- all do
        assert prompt =~ "# The constitution of a product's AI employees"

        assert {[], []} == RuntimePack.leaks(prompt, vocabulary),
               "#{id} #{workflow} #{step}"
      end
    end

    test "no runtime prompt carries anything the starter's development pack can write" do
      vocabulary = RuntimePack.development_vocabulary(Starter.source())

      # The vocabulary is the whole of it, not a sample: the composer's own
      # development lines are in it, and so is what the starter's
      # development templates, archetypes and trust levels write.
      assert "any contract, boundary or ADR change — propose it, do not land it;" in vocabulary.phrases
      assert "the commands you ran, with their output" in vocabulary.phrases
      assert "change the project's source" in vocabulary.phrases
      assert "edit" in vocabulary.ids

      root!("compose")
      assert_no_development(vocabulary)
    end

    @tag this_repository: true
    test "nor anything this repository's development pack can write" do
      real = Path.expand("../../../../../.agents", __DIR__)
      vocabulary = RuntimePack.development_vocabulary(real)
      assert length(vocabulary.ids) > 300

      root!("compose-repository")
      assert_no_development(vocabulary)
    end

    test "with NOETIC_HARNESS_ROOT pointed at the pack, as a product's build would" do
      dir = root!("env")
      Noetic.Harness.delete_root()
      previous = System.get_env("NOETIC_HARNESS_ROOT")
      System.put_env("NOETIC_HARNESS_ROOT", dir)

      on_exit(fn ->
        if previous,
          do: System.put_env("NOETIC_HARNESS_ROOT", previous),
          else: System.delete_env("NOETIC_HARNESS_ROOT")
      end)

      assert Noetic.Harness.root() == Path.expand(dir)

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Harness.Prompt.run(
            ~w(editorial.card_copywriter --workflow WF-101 --step draft)
          )
        end)

      assert out =~ "You are **Card Copywriter** (`editorial.card_copywriter`)"
      assert out =~ "`draft.write` (function, needs T1)"
      assert out =~ "**text.lint** (blocking)"
    end

    test "where a definition says nothing, a runtime prompt says what its own pack says" do
      root!("defaults")
      prompt = Prompt.compose!("editorial.guardian")

      assert prompt =~ "- publishing or sending anything outside the product;"
      assert prompt =~ "- anything your role does not do: to a person;"
      assert prompt =~ "in the lane **none**"
    end
  end
end
