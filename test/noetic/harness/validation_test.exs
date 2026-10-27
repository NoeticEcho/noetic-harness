defmodule Noetic.Harness.ValidationTest do
  @moduledoc """
  The validator validates this repository. If these fail, the harness's
  definitions are inconsistent and every claim downstream of them is suspect.
  """
  # `async: true` since an earlier change. It was sync because the fixture root was
  # `NOETIC_HARNESS_ROOT`, a VM-global, so a fixture tree here was visible to
  # every other test in the VM. `Noetic.Harness.put_root/1` scopes it to this
  # process and the `Task`s it spawns, so the isolation is per test.
  use ExUnit.Case, async: true

  alias Noetic.Harness.{FileServerBudget, Fixture, Validation}

  # The two whole-repository runs are in `ValidationRepositoryTest`, which is
  # sync; see its moduledoc for why.

  # A plant goes into a copy of `.agents`, never into the real file.
  #
  # The two tests that plant used to overwrite a tracked file in the real
  # repository from this async module, and put it back in `on_exit`. While a
  # plant was in place, every other async test in the VM saw it, and so did
  # `git status`. GatesTest's `paths: nil` test read that status twice, got
  # ` M .agents/policies/failure.json` on one read and a clean tree on the
  # other, and failed on 2 of 5 CI runs.
  #
  # A test killed mid-plant would also have left the change in a file that is
  # committed. `put_root/1` is per process, so the copy is visible to this
  # test and the Tasks it spawns, and to nothing else. Everything but the one
  # planted file is a symlink to the real tree, so the validator still reads
  # the real policy around it.
  defp planted_root(dir, file) do
    real = Noetic.Harness.agents_path()

    root =
      Noetic.Harness.TestTmp.path("validation-plant")

    agents = Path.join(root, ".agents")
    File.mkdir_p!(Path.join(agents, dir))

    for entry <- File.ls!(real), entry != dir do
      File.ln_s!(Path.join(real, entry), Path.join(agents, entry))
    end

    for entry <- File.ls!(Path.join(real, dir)), entry != file do
      File.ln_s!(Path.join([real, dir, entry]), Path.join([agents, dir, entry]))
    end

    File.cp!(Path.join([real, dir, file]), Path.join([agents, dir, file]))
    Noetic.Harness.put_root(root)
    on_exit(fn -> File.rm_rf!(root) end)

    Path.join([agents, dir, file])
  end

  @tag this_repository: true
  test "the environment suite warns only about weaknesses it has named" do
    {:ok, findings} = Validation.run([:environments])
    warnings = for {:warning, message} <- findings, do: message

    known = [
      ~r/is not scoring anything until it verifies again/,
      ~r/failed before the fix with a compile error/,
      ~r/reverse-patched by environments in .* and /,
      ~r/measuring the benchmark's task family twice/,
      ~r/verified and in no set/,
      ~r/never verified/,
      ~r/no statement/,
      ~r/set is empty/,
      # An earlier change's heuristic, and it is a heuristic on purpose: it flags a
      # sentence opening with an instruction verb, which catches four of the
      # five statements that were work orders and also fires on two that are
      # fine. `env-crossing-visible` ends "Make the crossing happen while it is
      # happening", which names an outcome and not a mechanism, and
      # `env-smg-components-render` ends the same way. Both are judgement calls
      # recorded in a design note rather than reworded to go quiet —
      # which is what the warning's own text asks for.
      ~r/the statement tells the solver what to do/
    ]

    for warning <- warnings do
      assert Enum.any?(known, &Regex.match?(&1, warning)),
             "unrecognised environment warning, which means a new weakness appeared and " <>
               "nobody wrote down what it is: #{warning}"
    end
  end

  @tag this_repository: true
  test "the failure policy's two copies are checked against each other" do
    # It exists twice on purpose — prose an agent reads in its prompt, data the
    # conductor dispatches on — and duplication without a check is how the two
    # quietly stop agreeing. Plant a row in the JSON that the Markdown does not
    # have and watch it be named.
    path = planted_root("policies", "failure.json")

    {:ok, policy} = Noetic.Harness.Loader.load(path)

    planted =
      update_in(policy["classes"], fn classes ->
        classes ++
          [
            %{
              "id" => "planted",
              "observed" => "Something failure.md never mentions",
              "match" => "planted",
              "route" => "nowhere",
              "why" => "a test"
            }
          ]
      end)

    # `check_failure` reads through `Loader.load/1`, not the memoising
    # `cached_load/1`, so the planted file is what it sees.
    File.write!(path, Noetic.Harness.Loader.pretty!(planted))

    {:ok, findings} = Validation.run([:failure])
    errors = for {:error, message} <- findings, do: message

    assert Enum.any?(errors, &(&1 =~ "Something failure.md never mentions"))
  end

  @tag this_repository: true
  test "an overlay cannot require completion evidence its role may not produce" do
    # The defect this was built for, restored verbatim. `release.ci_cd_engineer`
    # is capped at T3; T3's `may_not` names "change gate definitions or CI
    # workflow files"; and the overlay's first version closed with "Completion
    # evidence: the edited workflow". Nothing objected, because no sentence in
    # it mentioned a tool.
    path = planted_root("roles", "release.ci_cd_engineer.md")
    original = File.read!(path)

    assert {:ok, findings} = Validation.run([:overlay_authority])
    assert findings == [], "the overlays are expected to be clean before the plant"

    File.write!(
      path,
      String.replace(
        original,
        "Completion evidence: the proposed diff",
        "Completion evidence: the edited workflow"
      )
    )

    {:ok, planted} = Validation.run([:overlay_authority])
    warnings = for {:warning, message} <- planted, do: message

    assert Enum.any?(
             warnings,
             &(&1 =~ "release.ci_cd_engineer" and &1 =~ "an edited CI workflow")
           ),
           "the authority check did not name the artifact it was written for: #{inspect(warnings)}"

    File.write!(path, original)
    assert {:ok, []} = Validation.run([:overlay_authority])
  end

  @tag this_repository: true
  test "the overlay check names roles the registry cannot tell apart, and only those" do
    {:ok, findings} = Validation.run([:overlays])
    warnings = for {:warning, message} <- findings, do: message

    for warning <- warnings do
      assert warning =~ "sharing one archetype, capability set and tool set",
             "unrecognised overlay warning: #{warning}"
    end

    # A role with a hand-authored overlay is distinguished by it, so it must not
    # be named — these five share every grant with `security.secure_coding_auditor`
    # and stopped being interchangeable when they were written.
    joined = Enum.join(warnings, "\n")

    for id <- ~w(security.mcp_security_auditor security.secret_leakage_auditor
                 security.agent_sandbox_auditor security.abuse_case_designer
                 security.dependency_security_agent security.license_auditor) do
      refute joined =~ id
    end
  end

  # This is the whole validator, check by check, and its
  # time is its calls to OTP's file server: ~4,400 when this was written, 2,944
  # since `Loader` reads raw, most of the rest `schemas`' walk. Idle that is a second. Under load it timed out
  # at 60 s twice on the workstation, and ran 182 s here beside `stress-ng` at
  # load 15-21, stuck each time in a file-server call. The calls are in
  # `Validation` (fenced), `Prompt` and `Registry`, not here, so the test
  # states them: at most `@calls`, asserted on every machine, and a timeout of
  # `@calls` at the allowance a loaded call is given (`FileServerBudget`).
  # When the validator's I/O grows past the budget it is the count that fails,
  # here and idle, saying so, and not a timeout on a busy machine.
  @calls 3_500
  @tag timeout: FileServerBudget.timeout(@calls)
  @tag this_repository: true
  test "every named check runs" do
    {_, calls} =
      FileServerBudget.calls(fn ->
        for check <- Validation.checks() do
          assert {:ok, _findings} = Validation.run([check])
        end
      end)

    assert calls <= @calls,
           "the checks made #{calls} file-server calls against a budget of #{@calls}; " <>
             "raise @calls only with the timeout it implies in view, or make the calls raw"
  end

  test "ok?/1 is false for any error and true for warnings alone" do
    refute Validation.ok?([{:error, "x"}, {:warning, "y"}])
    assert Validation.ok?([{:warning, "y"}])
    assert Validation.ok?([])
  end

  @tag :fixture
  test "a skill a role names but which is not on disk is an error" do
    tree =
      update_in(Fixture.minimal()["registry/agents.json"]["agents"], fn [agent] ->
        [Map.put(agent, "skills", ["a-skill-that-does-not-exist"])]
      end)

    Fixture.with_tree(tree, fn _root ->
      {:ok, findings} = Validation.run([:skills])

      assert Enum.any?(findings, fn {severity, message} ->
               severity == :error and message =~ "a-skill-that-does-not-exist"
             end)
    end)
  end

  @tag :fixture
  test "a skill a capability supplies but a role holding it does not record is an error" do
    # The staleness this exists to catch: `agents.json` stores each role's
    # skills as a list produced once by the generator, and nothing recomputes
    # it. Adding a skill to a capability therefore reaches no role at all,
    # passes the orphan check because something references it, and appears in
    # zero prompts. It happened twice before this check existed.
    tree =
      Fixture.minimal()
      |> update_in(["registry/capabilities.json", "capabilities"], fn capabilities ->
        Enum.map(capabilities, fn capability ->
          if capability["id"] == "elixir.implementation" do
            Map.put(capability, "skills", (capability["skills"] || []) ++ ["elixir-idioms"])
          else
            capability
          end
        end)
      end)
      |> update_in(["registry/agents.json", "agents"], fn [agent] ->
        [agent |> Map.put("capabilities", ["elixir.implementation"]) |> Map.put("skills", [])]
      end)

    Fixture.with_tree(tree, fn _root ->
      {:ok, findings} = Validation.run([:skills])

      assert Enum.any?(findings, fn {severity, message} ->
               severity == :error and message =~ "elixir-idioms" and
                 message =~ "build_registry.py"
             end),
             "the error must name the command that fixes it, or it reads as a mystery"
    end)
  end

  @tag :fixture
  test "an evolution candidate is checked against its schema, live or archived" do
    # The one schema nothing loaded. The first committed candidate
    # failed it the moment it was loaded, on a `target.kind` the code writes
    # and the schema did not list.
    schema =
      Path.join([Noetic.Harness.Pack.source(), "schemas", "evolution_candidate.schema.json"])
      |> File.read!()

    bad = %{"id" => "cand-2026-09-23-broken", "target" => %{"kind" => "nonsense", "ref" => "x"}}

    tree =
      Map.merge(Fixture.minimal(), %{
        "schemas/evolution_candidate.schema.json" => schema,
        "evolution/candidates/cand-2026-09-23-broken.json" => bad,
        "evolution/archive/cand-2026-09-23-old.json" => Map.delete(bad, "target")
      })

    Fixture.with_tree(tree, fn _root ->
      {:ok, findings} = Validation.run([:schemas])
      errors = for {:error, message} <- findings, message =~ "evolution/", do: message

      assert Enum.any?(errors, &(&1 =~ "candidates/cand-2026-09-23-broken.json.target.kind"))
      assert Enum.any?(errors, &(&1 =~ "archive/cand-2026-09-23-old.json" and &1 =~ "target"))
    end)
  end

  test "a gate whose holder is not a role is an error" do
    tree =
      update_in(Fixture.minimal()["policies/gates.json"]["gates"], fn gates ->
        gates ++
          [
            %{
              "id" => "review",
              "name" => "review",
              "kind" => "review",
              "holder" => "nobody.at_all",
              "severity" => "blocking"
            }
          ]
      end)

    Fixture.with_tree(tree, fn _root ->
      {:ok, findings} = Validation.run([:gates])

      assert Enum.any?(findings, fn {severity, message} ->
               severity == :error and message =~ "nobody.at_all"
             end)
    end)
  end

  @tag :fixture
  test "the schema subset evaluator reports what it cannot check rather than passing it" do
    schema = %{"type" => "object", "anyOf" => [%{"type" => "string"}]}
    findings = Noetic.Harness.Validation.Schema.validate(%{}, schema, "example")

    assert Enum.any?(findings, &(&1 =~ "does not implement"))
    assert Enum.any?(findings, &(&1 =~ "NOT checked"))
  end

  test "the schema evaluator catches the constraints it does implement" do
    schema = %{
      "type" => "object",
      "required" => ["id"],
      "properties" => %{"id" => %{"type" => "string", "pattern" => "^x-"}}
    }

    assert ["$: missing required key id"] = Noetic.Harness.Validation.Schema.validate(%{}, schema)
    assert [finding] = Noetic.Harness.Validation.Schema.validate(%{"id" => "y-1"}, schema)
    assert finding =~ "does not match"
  end

  describe "models" do
    defp models_policy(review),
      do: %{
        "version" => 1,
        "doc" => "d",
        "default" => "null",
        "adapters" => [%{"id" => "null", "name" => "n", "needs" => [], "why" => "w"}],
        "by_trust" => [],
        "review" => %{"models" => review, "why" => "w"}
      }

    test "a review list of one family makes the independence refusal unsatisfiable: an error" do
      tree =
        Map.put(
          Fixture.minimal(),
          "policies/models.json",
          models_policy(["opus", "claude-opus-5-5"])
        )

      Fixture.with_tree(tree, fn _root ->
        {:ok, findings} = Validation.run([:models])
        assert [{:error, message}] = findings
        assert message =~ "at least two families"
      end)
    end

    test "two families pass" do
      tree =
        Map.put(
          Fixture.minimal(),
          "policies/models.json",
          models_policy(["claude-opus-5-5", "claude-sonnet-5"])
        )

      Fixture.with_tree(tree, fn _root ->
        assert {:ok, []} = Validation.run([:models])
      end)
    end
  end
end
