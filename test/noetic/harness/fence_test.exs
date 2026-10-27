defmodule Noetic.Harness.FenceTest do
  @moduledoc """
  The fence is the only thing that will stand between an autonomous loop and
  its own scoreboard, so it is tested for what it refuses rather than for what
  it permits.

  A design decision and constitution §4/§23.
  """

  # `async: true` since an earlier change. It was sync because the fixture root was
  # `NOETIC_HARNESS_ROOT`, a VM-global, so a fixture tree here was visible to
  # every other test in the VM. `Noetic.Harness.put_root/1` scopes it to this
  # process and the `Task`s it spawns, so the isolation is per test.
  use ExUnit.Case, async: true

  alias Noetic.Harness.Fence

  describe "what it refuses" do
    @tag this_repository: true
    test "every path named in the policy is refused, with its reason" do
      {:ok, entries} = Fence.entries()

      assert entries != [], "an empty fence is a fence that permits everything"

      for %{"glob" => glob, "why" => why} <- entries do
        assert why != "", "#{glob} is fenced with no reason recorded"

        # A glob stands for itself once `**` and `*` are given something to
        # match. This is the weakest possible reading and it is deliberate: a
        # stronger one would be testing the test's idea of the pattern.
        sample = glob |> String.replace("**", "x/y") |> String.replace("*", "x")

        assert Fence.fenced?(sample),
               "#{glob} is in the policy and #{sample} is not refused"
      end
    end

    test "the files this repository's own gates execute are refused" do
      for path <- ["scripts/ci-local.sh", ".github/workflows/ci.yml"] do
        assert Fence.fenced?(path), "#{path} decides what passing means and is not fenced"
      end
    end

    test "the modules that implement the judging are refused" do
      # Each of these decides something about whether work is acceptable. An
      # agent that can edit one can edit its own verdict.
      for module <-
            ~w(validation gates conductor dispatcher environments evolution scoring tree run git) do
        path = "apps/noetic_harness/lib/noetic/harness/#{module}.ex"

        assert Fence.fenced?(path),
               "#{path} is part of what judges a run and is not fenced"
      end
    end

    @tag this_repository: true
    test "ordinary product code and prose are not refused" do
      # A fence that refuses everything stops dispatch from being worth
      # building, which is the other way to get this wrong.
      for path <- [
            "apps/acme/lib/acme/nex.ex",
            "apps/acme_web/assets/js/world/hook.ts",
            "docs/decisions/DR-022-the-harness-dispatches-inside-a-fence.md",
            "CHANGELOG.md"
          ] do
        refute Fence.fenced?(path), "#{path} is not an evaluator and is being refused"
      end
    end

    test "a role overlay is fenced, and this test used to assert the opposite" do
      # It did, deliberately, and the decision changed rather than the code
      # drifting: an earlier change asked whether `.agents/roles/**` belongs on the
      # fence and answered yes. An overlay's completion-evidence lines say
      # what that role must produce before its work counts as done — a
      # judgement criterion written in prose rather than in a gate, and no
      # less load-bearing for it. An agent that could edit its own overlay
      # could edit its own finish line, in the same run as the work.
      #
      # Kept as its own test rather than as a line moved between two lists,
      # because the next person to read it should see that this was decided
      # and not merely swept up.
      assert Fence.fenced?(".agents/roles/security.license_auditor.md")
      assert Fence.fenced?(".agents/roles/qa.qa_architect.md")
    end

    test "a leading ./ does not change the answer" do
      # `git diff --name-only` and a hand-typed path must agree, or the fence
      # is one shell quirk away from being bypassed.
      assert Fence.fenced?("scripts/ci-local.sh")
      assert Fence.fenced?("./scripts/ci-local.sh")
    end

    @tag this_repository: true
    test "a directory glob does not leak past its directory" do
      assert Fence.fenced?(".agents/policies/trust_levels.json")
      assert Fence.fenced?(".agents/policies/nested/deep.json")
      refute Fence.fenced?(".agents/policiesX/trust_levels.json")
      refute Fence.fenced?("other/.agents/policies/trust_levels.json")
    end
  end

  describe "refuse/1" do
    @tag this_repository: true
    test "a clear change returns an empty refusal, not a permission" do
      assert {:ok, []} = Fence.refuse(["apps/acme/lib/acme/nex.ex", "README.md"])
    end

    @tag this_repository: true
    test "one fenced path among many refuses the whole change" do
      assert {:refused, [%{path: ".agents/policies/gates.json", why: why}]} =
               Fence.refuse([
                 "apps/acme/lib/acme/nex.ex",
                 ".agents/policies/gates.json",
                 "README.md"
               ])

      assert why =~ "trust"
    end

    test "the explanation names the rule and the file the rule lives in" do
      {:refused, refusals} = Fence.refuse([".agents/constitution.md"])
      text = Fence.explain(refusals)

      # Every refusal in this repository is arguable, which means citable.
      assert text =~ ".agents/policies/evaluators.json"
      assert is_binary(text)
      assert text =~ "§23"
      assert text =~ ".agents/constitution.md"
    end
  end

  describe "when the policy cannot be read" do
    @tag :tmp_dir
    test "it refuses everything rather than permitting everything", %{tmp_dir: tmp} do
      # §33: do not silently weaken behaviour when a dependency is unavailable.
      # A fence that fails open is not a fence, and the failure mode to design
      # against is the one where a missing file reads as "nothing to protect".
      original = Noetic.Harness.root_override()
      File.mkdir_p!(Path.join(tmp, ".agents/policies"))

      try do
        Noetic.Harness.put_root(tmp)

        # Run in a fresh process: the loader caches per process, so this one
        # has never seen the real policy.
        task =
          Task.async(fn ->
            {Fence.fenced?("anything/at/all.ex"), Fence.refuse(["apps/acme/lib/acme/nex.ex"])}
          end)

        assert {true, {:refused, [%{why: why}]}} = Task.await(task)
        assert why =~ "could not be read"
      after
        if original,
          do: Noetic.Harness.put_root(original),
          else: Noetic.Harness.delete_root()
      end
    end
  end
end
