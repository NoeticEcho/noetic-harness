defmodule Noetic.Harness.ValidationProfilesTest do
  @moduledoc """
  `harness.validate`'s `profiles` check: a profiles.json whose
  profiles overlap, or that names a profile that does not exist, is refused.

  Against fixtures small enough to read, as `ProfilesTest` is, and once
  against this repository. Each refusal names the profile and the path, so
  the coordinator reading a red `validate` knows which two workers collide
  and where.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.Validation

  # On the pack (`Noetic.Harness.Pack`) with `workers` switched on: the
  # check is the worker protocol's. The test of this repository's own
  # profiles.json is tagged `this_repository`.
  @moduletag pack_integrations: ["workers"]
  setup {Noetic.Harness.Pack, :root}

  defp doc(profiles, extra \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "doc" => "fixture",
        "profiles" =>
          Enum.map(profiles, fn {id, owns} ->
            %{
              "id" => id,
              "description" => id,
              "owns" => owns,
              "workflows" => [],
              "domains" => [],
              "environment" => id,
              "max_concurrent" => 1
            }
          end),
        "coordinator" => %{
          "description" => "held",
          "held" => [%{"glob" => "CLAUDE.md", "why" => "x"}]
        },
        "refused" => [%{"glob" => ".beads/**", "why" => "x"}],
        "add_only" => [%{"glob" => ".agents/runs/*.json", "why" => "x"}],
        "per_epic" => [%{"glob" => ".agents/handoff/{epic}.json", "why" => "x"}],
        "shared" => []
      },
      extra
    )
  end

  defp check(doc, tracked) do
    Validation.check_profiles(nil,
      doc: doc,
      tracked: tracked,
      fence: [],
      domains: [],
      workflows: []
    )
  end

  defp errors(findings), do: for({:error, message} <- findings, do: message)

  test "harness.validate runs it, so mix precommit does" do
    assert :profiles in Validation.checks()
  end

  @tag this_repository: true
  test "this repository's profiles.json passes" do
    {:ok, findings} = Validation.run([:profiles])
    assert errors(findings) == [], Enum.join(errors(findings), "\n")
  end

  test "a clean registry passes" do
    d = doc([{"harness", ["lib/harness/**"]}, {"memory", ["lib/memory/**"]}])
    assert errors(check(d, ["lib/harness/a.ex", "lib/memory/b.ex", "CLAUDE.md"])) == []
  end

  describe "an overlap" do
    test "a file two profiles own names both profiles and the file" do
      d = doc([{"harness", ["lib/**"]}, {"memory", ["lib/common/**"]}])

      assert [message] = errors(check(d, ["lib/a.ex", "lib/common/c.ex", "CLAUDE.md"]))
      assert message =~ "owned by harness and memory"
      assert message =~ "lib/common/c.ex"
    end

    test "a glob two profiles both list is refused before any file lands under it" do
      # Decided on files alone this passed: nothing is tracked under it yet,
      # and the first two epics to add a file there would collide.
      d = doc([{"harness", ["lib/h/**", "lib/new/**"]}, {"memory", ["lib/m/**", "lib/new/**"]}])
      findings = errors(check(d, ["lib/h/a.ex", "lib/m/b.ex", "CLAUDE.md"]))

      assert ("profiles: the glob lib/new/** is listed by harness and memory, " <>
                "which `shared` does not declare") in findings
    end

    test "`shared` declares an overlap, and then it is not one" do
      d =
        doc([{"harness", ["lib/h/**", "lib/new/**"]}, {"memory", ["lib/m/**", "lib/new/**"]}], %{
          "shared" => [
            %{"glob" => "lib/new/**", "profiles" => ["harness", "memory"], "why" => "x"}
          ]
        })

      tracked = ["lib/h/a.ex", "lib/m/b.ex", "lib/new/c.ex", "CLAUDE.md"]
      assert errors(check(d, tracked)) == []
    end
  end

  describe "a profile that does not exist" do
    test "an id outside the six is named" do
      d = doc([{"harness", ["lib/h/**"]}, {"painter", ["lib/p/**"]}])
      findings = errors(check(d, ["lib/h/a.ex", "lib/p/b.ex", "CLAUDE.md"]))

      assert Enum.any?(findings, &(&1 =~ ~s|"painter" is not a profile|)), inspect(findings)
    end

    test "`shared` naming one is named, with its glob" do
      d =
        doc([{"harness", ["lib/h/**"]}], %{
          "shared" => [%{"glob" => "lib/h/**", "profiles" => ["harness", "ghost"], "why" => "x"}]
        })

      findings = errors(check(d, ["lib/h/a.ex", "CLAUDE.md"]))

      assert ~s|profiles: `shared` lib/h/** names "ghost", which is not a profile here| in findings
    end
  end

  test "a profile with no environment is named" do
    d = doc([{"harness", ["lib/h/**"]}])
    d = update_in(d, ["profiles"], fn [p] -> [Map.put(p, "environment", "")] end)

    assert ~s|profiles: "harness" names no environment| in errors(
             check(d, ["lib/h/a.ex", "CLAUDE.md"])
           )
  end

  test "a document that is not the schema's shape is an error, and the checks here do not crash on it" do
    for broken <- [nil, %{"profiles" => "all of them"}, %{"profiles" => [%{"owns" => 1}]}] do
      findings = Validation.check_profiles(nil, doc: broken, tracked: [], fence: [])
      assert errors(findings) != [], inspect(broken)
    end
  end
end
