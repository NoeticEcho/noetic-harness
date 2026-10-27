defmodule Noetic.Harness.ValidationEngineTest do
  @moduledoc """
  The `evolution` and `environments` checks run wherever the build has the
  evolution engine.

  `Validation` names the engine's two modules only through `@engine`, so that
  a build without them — the published harness left them out for one cut,
  until their guards were complete — still compiles under
  `--warnings-as-errors`. That
  condition is also a way the checks could stop running without anybody
  noticing: a renamed module, a wrong atom, and `checks/0` would quietly drop
  them. These tests are what notices. They are left out of a tree without the
  engine, with the engine.
  """

  # `async: true`, as `ValidationTest` is: the plants go into a harness root
  # `Noetic.Harness.put_root/1` scopes to this process and its `Task`s.
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Environments, Evolution, Fixture, Validation}

  test "this build has the engine, so both of its checks are named" do
    assert Code.ensure_loaded?(Evolution)
    assert Code.ensure_loaded?(Environments)
    assert Validation.engine_checks() == [:evolution, :environments]
    assert :evolution in Validation.checks()
    assert :environments in Validation.checks()
  end

  describe "over MCP" do
    # On the pack, as `MCPTest` is: a tree of the engine has no `.agents/` at
    # its root, and this test first ran in one when the engine went back in.
    setup {Noetic.Harness.Pack, :root}

    test "the MCP server serves the engine's task here" do
      {:ok, manifest} = Noetic.Harness.MCP.manifest()
      brief = Enum.find(manifest["tools"], &(&1["task"] == "environments"))

      assert Code.ensure_loaded?(Mix.Tasks.Harness.Environments)
      assert Noetic.Harness.MCP.served?(brief)
    end
  end

  test "a build without the engine names neither of its checks" do
    assert Validation.engine_checks(fn _module -> false end) == []

    assert Validation.engine_checks(&(&1 == Evolution)) == [:evolution]
  end

  test "the evolution check runs: a broken lineage is reported" do
    orphan = %{
      "id" => "cand-2026-01-01-orphan",
      "status" => "proposed",
      "created_at" => "2026-01-01T00:00:00Z",
      "lineage" => %{"parents" => ["cand-2026-01-01-gone"], "generation" => 1}
    }

    tree = Map.put(Fixture.minimal(), "evolution/candidates/#{orphan["id"]}.json", orphan)

    Fixture.with_tree(tree, fn _root ->
      assert {:ok, findings} = Validation.run([:evolution])
      assert findings == Enum.map(Evolution.validate(), &{:error, &1})

      assert Enum.any?(findings, fn {:error, message} ->
               message =~ "cand-2026-01-01-orphan names parent cand-2026-01-01-gone"
             end)
    end)
  end

  test "the environments check runs: an environment it cannot read is reported" do
    tree = Map.put(Fixture.minimal(), "evolution/environments/env-broken.json", "{ not json")

    Fixture.with_tree(tree, fn _root ->
      assert {:ok, findings} = Validation.run([:environments])
      %{errors: errors, warnings: warnings} = Environments.validate()

      assert findings ==
               Enum.uniq(Enum.map(errors, &{:error, &1}) ++ Enum.map(warnings, &{:warning, &1}))

      assert {:error, "env-broken.json cannot be read, so it is in no suite: " <> _} =
               Enum.find(findings, &match?({:error, "env-broken.json" <> _}, &1))
    end)
  end

  # The whole run, over this repository's `.agents` with the two plants beside
  # it: what `noetic-harness validate` with no argument reads. Everything but the
  # planted files is a symlink to the real tree, as in `ValidationTest`.
  @tag this_repository: true
  test "a run with no checks named runs the engine's too" do
    orphan = %{
      "id" => "cand-2026-01-01-orphan",
      "status" => "proposed",
      "created_at" => "2026-01-01T00:00:00Z",
      "lineage" => %{"parents" => ["cand-2026-01-01-gone"], "generation" => 1}
    }

    root =
      planted_root(%{
        "evolution/candidates/#{orphan["id"]}.json" => JSON.encode!(orphan),
        "evolution/environments/env-broken.json" => "{ not json"
      })

    previous = Noetic.Harness.put_root(root)

    try do
      assert {:ok, findings} = Validation.run()
      messages = for {_severity, message} <- findings, do: message

      assert Enum.any?(messages, &(&1 =~ "names parent cand-2026-01-01-gone"))
      assert Enum.any?(messages, &(&1 =~ "env-broken.json cannot be read"))
    after
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
    end
  end

  # A copy of `.agents` where every directory on the way to a planted file is
  # real and everything else is a symlink into this repository's tree.
  defp planted_root(plants) do
    root = Noetic.Harness.TestTmp.path("validation-engine")
    on_exit(fn -> File.rm_rf!(root) end)
    link(Noetic.Harness.agents_path(), Path.join(root, ".agents"), plants)
    root
  end

  defp link(real, copy, plants) do
    File.mkdir_p!(copy)
    {here, below} = Enum.split_with(plants, fn {path, _} -> not String.contains?(path, "/") end)
    planted = Map.new(here)

    deeper =
      Enum.group_by(
        below,
        fn {path, _} -> path |> String.split("/", parts: 2) |> hd() end,
        fn {path, content} -> {path |> String.split("/", parts: 2) |> List.last(), content} end
      )

    for entry <- File.ls!(real),
        not Map.has_key?(planted, entry),
        not Map.has_key?(deeper, entry) do
      File.ln_s!(Path.join(real, entry), Path.join(copy, entry))
    end

    for {file, content} <- planted, do: File.write!(Path.join(copy, file), content)
    for {dir, inner} <- deeper, do: link(Path.join(real, dir), Path.join(copy, dir), inner)
  end
end
