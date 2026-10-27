defmodule Noetic.Harness.ProfilesTest do
  @moduledoc """
  `.agents/registry/profiles.json` and the check that holds it.

  These are about the check, against fixtures small enough to read, because
  a check whose only test is "this repository passes" cannot be told from a
  check that passes everything.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Fence, Glob, Profiles}

  # The check's own tests run on the pack (`Noetic.Harness.Pack`) with
  # `workers` switched on, because profiles are the worker protocol's and
  # the check answers "off" without it. This repository's own profiles.json
  # is `ProfilesRepositoryTest`'s.
  @moduletag pack_integrations: ["workers"]
  setup {Noetic.Harness.Pack, :root}

  describe "the glob matcher agrees with the fence" do
    # Profiles classifies by the fence's globs and its own in one pass, so the
    # two matchers must read a glob the same way. `Fence.fenced?/1` is the
    # fence's own answer; this compares it with `Glob` over every fenced glob,
    # on a path it names and on near misses either side of each wildcard.
    test "on every fenced glob, and on near misses either side of each wildcard" do
      {:ok, entries} = Fence.entries()
      globs = Enum.map(entries, & &1["glob"])

      for glob <- globs, path <- probes(glob) do
        assert Glob.any?(globs, path) == Fence.fenced?(path), "#{glob} and #{path}"
      end
    end

    defp probes(glob) do
      literal = glob |> String.replace("**", "a/b") |> String.replace("*", "x")

      [
        literal,
        String.replace(glob, "**", "a"),
        String.replace(glob, "*", "x/y"),
        literal <> ".bak",
        "prefix/" <> literal
      ]
    end
  end

  # --- the check, against fixtures --------------------------------------------

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

  defp check(doc, tracked),
    do: Profiles.validate(doc: doc, tracked: tracked, fence: [], domains: [], workflows: [])

  defp errors(findings), do: for({:error, message} <- findings, do: message)

  describe "validate/1" do
    test "a tracked file nothing claims is named" do
      d = doc([{"a", ["lib/a/**"]}])
      [message] = errors(check(d, ["lib/a/x.ex", "lib/b/y.ex", "CLAUDE.md"]))
      assert message =~ "1 tracked file(s) no profile or class claims: lib/b/y.ex"
    end

    test "a file two profiles own is refused unless shared declares it" do
      d = doc([{"a", ["lib/**"]}, {"b", ["lib/common/**"]}])
      tracked = ["lib/a.ex", "lib/common/c.ex"]

      [message] = errors(check(d, tracked))
      assert message =~ "1 file(s) owned by a and b"
      assert message =~ "lib/common/c.ex"

      shared = %{
        "shared" => [%{"glob" => "lib/common/**", "profiles" => ["a", "b"], "why" => "x"}]
      }

      assert errors(check(Map.merge(d, shared), tracked)) == []
    end

    test "`except` gives a path back, so a carve-out is not double ownership" do
      d = doc([{"a", ["lib/**"]}, {"b", ["lib/common/**"]}])
      [a, b] = d["profiles"]
      d = %{d | "profiles" => [Map.put(a, "except", ["lib/common/**"]), b]}
      assert errors(check(d, ["lib/a.ex", "lib/common/c.ex"])) == []
    end

    test "a profile glob that matches nothing is an error; a class glob, a warning" do
      d = doc([{"a", ["lib/**", "lib/typo/**"]}])
      findings = check(d, ["lib/x.ex", "CLAUDE.md"])

      assert ["profiles: a's glob lib/typo/** matches no tracked file"] = errors(findings)
      assert {:warning, "profiles: refused's glob .beads/** matches no tracked file"} in findings
    end

    test "the first class wins: an add-only run inside a profile's tree is add-only" do
      d = doc([{"harness", [".agents/**"]}])
      classify = Profiles.classifier(d, fence: [".agents/policies/**"])

      assert {:add_only, _} = classify.(".agents/runs/r.json")
      assert {:fenced, _} = classify.(".agents/policies/gates.json")
      assert {:per_epic, _} = classify.(".agents/handoff/bd-1.json")
      assert {:owned, ["harness"]} = classify.(".agents/workflows/wf.json")
    end

    test "per-epic is that epic's own file when an epic is named" do
      d = doc([{"harness", [".agents/**"]}])
      classify = Profiles.classifier(d, fence: [], epic: "bd-1")

      assert {:per_epic, ".agents/handoff/bd-1.json"} = classify.(".agents/handoff/bd-1.json")
      assert {:owned, ["harness"]} = classify.(".agents/handoff/bd-2.json")
    end

    test "two profiles with one id, and an unknown workflow, are refused" do
      d = doc([{"a", ["lib/**"]}, {"a", ["test/**"]}])
      [a1, a2] = d["profiles"]

      d = %{
        d
        | "profiles" => [Map.put(a1, "workflows", ["WF-999"]), Map.put(a2, "environment", "b")]
      }

      findings =
        Profiles.validate(
          doc: d,
          tracked: ["lib/x", "test/y", "CLAUDE.md"],
          fence: [],
          domains: [],
          workflows: ["WF-001"]
        )

      assert "profiles: 2 profiles have the id \"a\"" in errors(findings)
      assert "profiles: a names the workflow WF-999, which does not exist" in errors(findings)
    end

    test "a file that is not the schema's shape is refused before anything else" do
      d = Map.delete(doc([{"a", ["lib/**"]}]), "refused")
      [message | _] = errors(check(d, ["lib/x"]))
      assert message =~ "refused"
    end
  end

  describe "the agreement with domains.json" do
    defp agree(doc, tracked, domain_owns) do
      Profiles.validate(
        doc: doc,
        tracked: tracked,
        fence: [],
        domains: Map.keys(domain_owns),
        workflows: [],
        domain_owns: domain_owns
      )
    end

    defp two_profiles do
      d = doc([{"harness", ["lib/h/**"]}, {"memory", ["lib/m/**"]}])

      update_in(d, ["profiles"], fn [h, m] ->
        [Map.put(h, "domains", ["governance"]), Map.put(m, "domains", ["repository"])]
      end)
    end

    @tracked ["lib/h/a.ex", "lib/m/b.ex", "CLAUDE.md"]

    test "domains that own what their profiles own agree" do
      owns = %{"governance" => ["lib/h/"], "repository" => ["lib/m/b.ex"]}
      assert errors(agree(two_profiles(), @tracked, owns)) == []
    end

    test "a domain glob that matches no tracked file is named" do
      owns = %{"governance" => ["lib/h/", "lib/*/boundary*"], "repository" => ["lib/m/"]}

      assert errors(agree(two_profiles(), @tracked, owns)) == [
               "domains: governance's lib/*/boundary* matches no tracked file"
             ]
    end

    test "a profile listing a domain that owns none of its files is named" do
      # The harness profile listed governance, which owned docs/adr, docs/plan
      # and .beads: none of the 729 files the harness profile owned.
      owns = %{"governance" => ["CLAUDE.md", "lib/m/"], "repository" => ["lib/m/", "lib/h/"]}
      findings = errors(agree(two_profiles(), @tracked, owns))

      assert "profiles: harness lists the domain governance, which owns none of harness's 1 files" in findings
    end

    test "a file a profile owns that no domain owns is named, with its profile" do
      owns = %{"governance" => ["lib/h/a.ex"], "repository" => ["lib/m/b.ex"]}
      tracked = ["lib/h/a.ex", "lib/h/new.ex", "lib/m/b.ex", "CLAUDE.md"]

      assert errors(agree(two_profiles(), tracked, owns)) == [
               "profiles: 1 of harness's file(s) no domain in domains.json owns: lib/h/new.ex"
             ]
    end
  end
end
