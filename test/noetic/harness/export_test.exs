defmodule Noetic.Harness.ExportTest do
  @moduledoc """
  `harness export` on the editorial pack, held by a golden file
  (`test/support/runtime_pack/export.json`), and what it refuses.

  The golden file is regenerated, after a deliberate change to the pack or
  the composer, from `apps/noetic_harness`, with

      NOETIC_HARNESS_ROOT=$PWD/test/support/runtime_pack MIX_ENV=test mix run --no-start -e \\
        '{:ok, e} = Noetic.Harness.Export.build()
         File.write!("test/support/runtime_pack/export.json", Noetic.Harness.Export.encode(e))'

  and its diff is the review of that change as a product would receive it.
  The command-line door, `noetic-harness export --out`/`--check`, is not on this
  branch: a `mix harness.*` task must be listed in `noetic-harness`, which is the
  coordinator's (`.agents/handoff/bd-5cr.33.json`, `shared_change_requests`).
  """

  # async: true: each test builds a root of its own and points only its own
  # process at it (`Noetic.Harness.put_root/1`, which a `Task` it starts
  # inherits); the loaders' caches are per process too. Nothing is shared.
  use ExUnit.Case, async: true

  import Noetic.Harness.RuntimePack,
    only: [root!: 1, root!: 2, mixed_root!: 1, edit!: 3, update_role: 3]

  alias Noetic.Harness.{Export, RuntimePack, Starter}

  @golden Path.expand("../../support/runtime_pack/export.json", __DIR__)
  @kinds ~w(check evidence review manual)

  defp export! do
    assert {:ok, export} = Export.build()
    export
  end

  describe "the editorial pack's export" do
    test "is the golden file, byte for byte" do
      root!("export")

      assert Export.encode(export!()) == File.read!(@golden),
             "the export changed; if that was meant, regenerate it (see this module's doc) " <>
               "and review the diff"
    end

    test "carries its pack and a hash of the rest of it" do
      golden = @golden |> File.read!() |> JSON.decode!()

      assert golden["export"] == 1
      assert golden["pack"] == %{"name" => "editorial", "version" => "0.1.0"}
      assert Export.intact?(golden)

      edited = put_in(golden, ["roles", Access.at(0), "grants", "trust_ceiling"], "T2")
      refute Export.intact?(edited)
    end

    test "holds every runtime definition, each saying so, and every gate of the four kinds" do
      %{"definitions" => definitions, "roles" => roles} =
        @golden |> File.read!() |> JSON.decode!()

      assert Enum.map(definitions["roles"], & &1["id"]) == Enum.sort(RuntimePack.roles())
      assert Enum.map(roles, & &1["id"]) == Enum.sort(RuntimePack.roles())

      for key <- ~w(roles capabilities workflows tools), definition <- definitions[key] do
        assert definition["plane"] == "runtime", "#{key} #{definition["id"]}"
      end

      assert Enum.all?(definitions["gates"], &(&1["kind"] in @kinds))
      assert Enum.map(definitions["lanes"], & &1["id"]) == ~w(card letter)

      for role <- roles do
        assert Enum.sort(Map.keys(role["grants"]["gates"])) == Enum.sort(@kinds)
        assert role["grants"]["trust_ceiling"] == "T1"
        assert Enum.all?(role["grants"]["tools"], &(&1["kind"] in ~w(function data)))
        assert role["steps"] != [], role["id"]
      end
    end

    test "grants a role the gates on its own work, and not its workflow lane's" do
      %{"roles" => roles} = @golden |> File.read!() |> JSON.decode!()
      proofreader = Enum.find(roles, &(&1["id"] == "editorial.proofreader"))

      assert proofreader["grants"]["gates"] == %{
               "check" => [],
               "evidence" => [],
               "manual" => [],
               "review" => ["proof.review"]
             }

      assert proofreader["grants"]["tools"] == [
               %{"id" => "draft.read", "kind" => "data", "min_trust" => "T0"}
             ]

      assert Enum.map(proofreader["steps"], &{&1["workflow"], &1["step"]}) ==
               [{"WF-101", "proofread"}, {"WF-102", "proofread"}]
    end

    test "writes no engine: no command, no path, no development text" do
      text = File.read!(@golden)

      for engine <-
            [
              "noetic_harness",
              "the product.",
              "defmodule",
              "mix ",
              "noetic-harness",
              ".agents/",
              "$schema",
              "\"command\""
            ] do
        refute text =~ engine, engine
      end

      vocabulary = RuntimePack.development_vocabulary(Starter.source())
      %{"roles" => roles} = JSON.decode!(text)

      for role <- roles, prompt <- [role["prompt"] | Enum.map(role["steps"], & &1["prompt"])] do
        assert {[], []} == RuntimePack.leaks(prompt, vocabulary), role["id"]
      end
    end

    test "is the same beside a development pack: the development plane is not in it" do
      mixed_root!("export")

      assert Export.encode(export!()) == File.read!(@golden)
    end
  end

  describe "it refuses" do
    test "a pack validate refuses, with validate's messages" do
      root!("export-refused", fn agents ->
        edit!(agents, "registry/agents.json", fn doc ->
          update_role(doc, "editorial.proofreader", &Map.put(&1, "max_trust", "T2"))
        end)
      end)

      assert {:error, messages} = Export.build()
      assert Enum.any?(messages, &(&1 =~ "editorial.proofreader"))
    end

    test "a root with no runtime role" do
      dir = Noetic.Harness.TestTmp.dir!("export-development")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, _} = Starter.install(dir, name: "development")
      Noetic.Harness.put_root(dir)

      assert {:error, [message]} = Export.build()
      assert message =~ "no runtime"
      assert message =~ ""
    end

    test "a runtime manifest naming no pack" do
      root!("export-no-pack", fn agents ->
        edit!(agents, "runtime/templates/prompt/MANIFEST.json", &Map.delete(&1, "pack"))
      end)

      assert {:error, [message]} = Export.build()
      assert message =~ "names no pack"
    end
  end
end
