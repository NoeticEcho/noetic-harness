defmodule Noetic.Harness.EnvironmentsTest do
  @moduledoc """
  Every test here is a way the suite could come to score a candidate on tasks
  that cannot tell whether the candidate worked.
  """
  # `async: false`, and now for a written reason. The git-history
  # setup below puts a stub `mix` at the front of `PATH` with
  # `System.put_env/2`, and `PATH` is a VM-global: every concurrently running
  # test would get that stub, and when this file restores the real one they
  # would get that instead, mid-call. The harness root here is per process
  # and would not have kept it sync on its own.
  use ExUnit.Case, async: false

  alias Noetic.Harness.{Environments, Fixture}

  defp environment(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "title" => id,
        "statement" => "something was observed to be wrong",
        "source" => %{
          "kind" => "fix_commit",
          "repository" => "self",
          "fix" => String.duplicate("a", 40),
          "parent" => String.duplicate("b", 40),
          "subject" => "the answer sheet",
          "bead" => nil
        },
        "verifier" => %{
          "kind" => "reverse_patch",
          "app" => "acme",
          "files" => ["test/acme/#{id}_test.exs"],
          "source_paths" => ["apps/acme/lib/acme/#{id}.ex"]
        },
        "set" => nil,
        "verification" => verification("unverified"),
        "verification_history" => []
      },
      attrs
    )
  end

  defp verification(state, reason \\ "because", extra \\ %{}) do
    Map.merge(
      %{
        "state" => state,
        "failed_before" => state == "verified",
        "passed_after" => state == "verified",
        "discrimination" => if(state == "verified", do: "assertion"),
        "by" => "test",
        "at" => "2026-09-20T00:00:00Z",
        "head" => String.duplicate("c", 40),
        "reason" => reason
      },
      extra
    )
  end

  defp tree(environments) do
    Map.new(environments, fn environment ->
      {"evolution/environments/#{environment["id"]}.json", environment}
    end)
  end

  # A real git repository with a real fix commit and a fake `mix`, so that
  # `verify/2` can be driven end to end in well under a second.
  #
  # The rest of this file uses `Fixture.with_tree`, whose tree is not a git
  # repository — which is why every verification test before an earlier change could
  # only assert `unavailable`. The hazard that bead names is about *where the
  # commands run*, and nothing that stops short of running them can see it.
  # The fake `mix` is the same device the dispatcher's tests use for
  # `claude -p`: a shell script on `PATH` that records its working directory
  # and answers from the source in front of it, so the argument construction,
  # the exit status and the classification are all real and all free.
  defp with_repo(fun) do
    root =
      Noetic.Harness.TestTmp.path("harness-env-repo") |> Noetic.Harness.Fixture.write_project()

    bin = Path.join(root, "bin")
    log = Path.join(root, "mix-runs.log")
    source = Path.join([root, "apps", "tiny", "lib", "tiny.ex"])
    verifier = Path.join([root, "apps", "tiny", "test", "tiny_test.exs"])

    File.mkdir_p!(Path.dirname(source))
    File.mkdir_p!(Path.dirname(verifier))
    File.mkdir_p!(bin)

    # `extra-output` is how a test decides what the "failing code" printed —
    # a connection string, an inspected config map — because that is where the
    # real leak risk lives and it is not something the verifier's own source
    # can carry: the worktree is at HEAD and never has the caller's
    # uncommitted edits.
    File.write!(Path.join(bin, "mix"), """
    #!/bin/sh
    printf '%s\\n' "$PWD" >> #{log}
    if grep -q FIXED lib/tiny.ex 2>/dev/null; then
      printf 'Finished in 0.1 seconds\\n1 test, 0 failures\\n'
      exit 0
    fi
    [ -f #{Path.join(root, "extra-output")} ] && cat #{Path.join(root, "extra-output")}
    if [ -f #{Path.join(root, "broken-build")} ]; then
      cat #{Path.join(root, "broken-build")}
      exit 1
    fi
    printf 'Finished in 0.1 seconds\\n1 test, 1 failure\\n'
    exit 1
    """)

    File.chmod!(Path.join(bin, "mix"), 0o755)

    File.write!(source, "defmodule Tiny do\n  def value, do: :broken\nend\n")
    File.write!(verifier, "# the oracle, which a solver may not read\n")

    git = fn args -> {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true) end

    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.email", "harness@example.invalid"])
    git.(["config", "user.name", "harness"])
    git.(["config", "commit.gpgsign", "false"])
    # Explicit paths, never `add -A`: the constitution's rule, kept even in a
    # throwaway repository, because a test is where the next person reads it.
    git.(["add", "apps/tiny/lib/tiny.ex", "apps/tiny/test/tiny_test.exs"])
    git.(["commit", "-q", "-m", "the defect"])

    File.write!(source, "defmodule Tiny do\n  def value, do: :FIXED\nend\n")
    git.(["add", "apps/tiny/lib/tiny.ex"])
    git.(["commit", "-q", "-m", "the fix"])

    {fix, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    {parent, 0} = System.cmd("git", ["rev-parse", "HEAD~1"], cd: root)

    definition =
      environment("env-tiny", %{
        "source" => %{
          "kind" => "fix_commit",
          "repository" => "self",
          "fix" => String.trim(fix),
          "parent" => String.trim(parent),
          "subject" => "the fix",
          "bead" => nil
        },
        "verifier" => %{
          "kind" => "reverse_patch",
          "app" => "tiny",
          "files" => ["test/tiny_test.exs"],
          "source_paths" => ["apps/tiny/lib/tiny.ex"]
        }
      })

    path = Path.join([root, ".agents", "evolution", "environments", "env-tiny.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(definition))

    previous_root = Noetic.Harness.root_override()
    previous_path = System.get_env("PATH")
    Noetic.Harness.put_root(root)
    System.put_env("PATH", bin <> ":" <> previous_path)

    try do
      fun.(%{root: root, source: source, log: log})
    after
      if previous_root,
        do: Noetic.Harness.put_root(previous_root),
        else: Noetic.Harness.delete_root()

      System.put_env("PATH", previous_path)
      File.rm_rf!(root)
    end
  end

  describe "a verification is isolated from the tree the caller is standing in" do
    test "every command runs in a worktree of its own, and the worktree is taken away" do
      with_repo(fn %{root: root, log: log} ->
        {:ok, environment} = Environments.verify("env-tiny", by: "test")

        assert environment["verification"]["state"] == "verified"
        assert environment["verification"]["discrimination"] == "assertion"

        # Two passes — HEAD first, then the reverse patch — and neither of them
        # in the repository root, which is where another session is working.
        cwds = log |> File.read!() |> String.split("\n", trim: true)
        assert length(cwds) == 2

        for cwd <- cwds do
          refute cwd == Path.join(root, "apps/tiny")
          assert String.contains?(cwd, "noetic-harness")
        end

        assert File.ls!(Path.join([root, ".git", "noetic-harness"])) == []
      end)
    end

    test "uncommitted work in the verifier's own paths is neither a refusal nor touched" do
      with_repo(fn %{source: source} ->
        dirty = File.read!(source) <> "\n# somebody else is in the middle of something\n"
        File.write!(source, dirty)

        {:ok, environment} = Environments.verify("env-tiny", by: "test")

        # Before an earlier change this was `unavailable`, because verification rewrote
        # these very files and would not do it over unsaved work. It no longer
        # rewrites them, so the honest answer is a verdict plus a sentence
        # saying what the verdict is about.
        assert environment["verification"]["state"] == "verified"
        assert environment["verification"]["note"] =~ "uncommitted changes"
        assert environment["verification"]["note"] =~ "is not about them"
        assert File.read!(source) == dirty
      end)
    end
  end

  describe "evidence and attribution claim only what they are" do
    test "a credential this process is holding never reaches the committed record" do
      with_repo(fn %{root: root} ->
        System.put_env("SCORING_API_TOKEN", "NOT-A-REAL-CREDENTIAL-2f9c41ab77de")
        on_exit(fn -> System.delete_env("SCORING_API_TOKEN") end)

        # The shape that actually leaks: a failing test inspecting a config map.
        File.write!(
          Path.join(root, "extra-output"),
          ~s|     code: assert Config.get() == %{token: "NOT-A-REAL-CREDENTIAL-2f9c41ab77de"}\n|
        )

        {:ok, environment} = Environments.verify("env-tiny", by: "test")

        evidence = environment["verification"]["evidence"] || ""
        refute evidence =~ "NOT-A-REAL-CREDENTIAL-2f9c41ab77de"
        assert evidence =~ "[redacted $SCORING_API_TOKEN]"
      end)
    end

    test "a credential this process never held is withheld rather than filtered quietly" do
      with_repo(fn %{root: root} ->
        # Not in this process's environment, so no redaction can find it. §33:
        # the evidence is replaced by a sentence saying what happened, not by
        # nothing.
        File.write!(
          Path.join(root, "extra-output"),
          "     ** (DBConnection.ConnectionError) postgres://app:hunter2@db.invalid/acme\n"
        )

        {:ok, environment} = Environments.verify("env-tiny", by: "test")

        evidence = environment["verification"]["evidence"]
        refute evidence =~ "hunter2"
        assert evidence =~ "evidence withheld"
        assert environment["verification"]["state"] == "verified"
      end)
    end

    test "attribution says where the name came from and that nothing checked it" do
      with_repo(fn _ ->
        {:ok, environment} =
          Environments.verify("env-tiny", by: "somebody", by_from: "HARNESS_AGENT")

        assert environment["verification"]["by"] == "somebody"
        assert environment["verification"]["by_from"] == "HARNESS_AGENT"
        assert environment["verification"]["by_attested"] == false
      end)
    end

    test "attribution/0 names the variable it read, not just the value" do
      System.put_env("HARNESS_AGENT", "claude-opus-5")
      on_exit(fn -> System.delete_env("HARNESS_AGENT") end)

      assert Environments.attribution() == [by: "claude-opus-5", by_from: "HARNESS_AGENT"]
    end

    test "nothing in this repository claims an attested verification" do
      # If this ever fails, something started attesting identity and the
      # constant in `attribute/2` has become a real value. That is a good day
      # and this test is how it announces itself.
      for environment <- Environments.list(),
          record <- [environment["verification"] | environment["verification_history"] || []],
          is_map(record) do
        assert record["by_attested"] == false,
               "#{environment["id"]} claims an attested verification, which nothing can do yet"
      end
    end

    test "a file whose id disagrees with its name is an error, not a second environment" do
      seeded = %{
        "evolution/environments/env-holdout.json" => environment("env-holdout"),
        # Same id, different filename: `list/1` keys on the id and one of the
        # two silently wins.
        "evolution/environments/aaa-first.json" => environment("env-holdout")
      }

      Fixture.with_tree(seeded, fn _ ->
        %{errors: errors} = Environments.validate()

        assert Enum.any?(errors, &(&1 =~ "aaa-first.json declares id \"env-holdout\""))
      end)
    end
  end

  describe "a broken build is not a verdict about a test" do
    test "a pre-fix run that never reached the tests is unavailable, not verified" do
      with_repo(fn %{root: root} ->
        # The exact shape the worktree opened up: pass 1 passes at HEAD, and
        # pass 2 exits non-zero because `mix` could not build, not because the
        # verifier detected anything. Every non-zero exit used to be read as
        # "failed at the parent source" and written down as `verified`.
        File.write!(
          Path.join(root, "broken-build"),
          "** (Mix) Could not compile dependency :lazy_html, \"make\" command failed.\n"
        )

        {:ok, environment} = Environments.verify("env-tiny", by: "test")

        assert environment["verification"]["state"] == "unavailable"
        assert environment["verification"]["reason"] =~ "not the defect"
        assert environment["verification"]["failed_before"] == nil
      end)
    end

    test "a pre-fix run that fails to compile the app under test is still a real task" do
      with_repo(fn %{root: root} ->
        # Reverse-applying a commit that created a module deletes it and the
        # app stops compiling. That is the blessed `discrimination: "compile"`
        # case and it must not be swept up by the check above — the difference
        # is the tree under test failing versus the machinery around it.
        File.write!(
          Path.join(root, "broken-build"),
          "== Compilation error in file lib/tiny.ex ==\n** (CompileError) lib/tiny.ex:2: undefined\n"
        )

        {:ok, environment} = Environments.verify("env-tiny", by: "test")

        assert environment["verification"]["state"] == "verified"
        assert environment["verification"]["discrimination"] == "compile"
      end)
    end
  end

  describe "the fail-before criterion" do
    test "an unverified environment cannot be put into a set" do
      Fixture.with_tree(tree([environment("env-a")]), fn _ ->
        assert {:error, message} = Environments.assign("env-a", "benchmark")
        assert message =~ "unverified"
        assert message =~ "scores nothing"
      end)
    end

    test "a rejected environment cannot be put into a set either" do
      rejected = environment("env-a", %{"verification" => verification("rejected")})

      Fixture.with_tree(tree([rejected]), fn _ ->
        assert {:error, message} = Environments.assign("env-a", "holdout")
        assert message =~ "rejected"
      end)
    end

    test "suite/1 excludes anything not currently verified, whatever its set says" do
      seeded = [
        environment("env-good", %{
          "set" => "benchmark",
          "verification" => verification("verified")
        }),
        environment("env-stale", %{
          "set" => "benchmark",
          "verification" => verification("rejected")
        })
      ]

      Fixture.with_tree(tree(seeded), fn _ ->
        assert Enum.map(Environments.suite("benchmark"), & &1["id"]) == ["env-good"]
      end)
    end

    test "a set member whose verifier stopped discriminating is an error" do
      seeded = [
        environment("env-stale", %{"set" => "holdout", "verification" => verification("rejected")})
      ]

      Fixture.with_tree(tree(seeded), fn _ ->
        %{errors: errors} = Environments.validate()
        assert Enum.any?(errors, &(&1 =~ "env-stale" and &1 =~ "silently shrinks"))
      end)
    end

    test "a set member we can no longer ask about is a warning, not an error" do
      # Otherwise the honest action — re-verifying after HEAD moved past the
      # commit — is the one that turns a blocking gate red with no legal way to
      # clear it, and the incentive is to stop re-verifying.
      seeded = [
        environment("env-gone", %{
          "set" => "holdout",
          "verification" => verification("unavailable")
        })
      ]

      Fixture.with_tree(tree(seeded), fn _ ->
        %{errors: errors, warnings: warnings} = Environments.validate()

        # Not `errors == []`: a one-environment fixture is below the floor
        # An earlier change added, and every set says so. The claim here is about
        # `env-gone` and nothing else.
        refute Enum.any?(errors, &(&1 =~ "env-gone"))
        assert Enum.any?(warnings, &(&1 =~ "env-gone" and &1 =~ "unavailable"))
        assert Environments.suite("holdout") == []
      end)
    end

    test "failing before the fix with a compile error is not evidence that the test discriminates" do
      seeded = [
        environment("env-new-module", %{
          "set" => "benchmark",
          "verification" => verification("verified", "because", %{"discrimination" => "compile"})
        })
      ]

      Fixture.with_tree(tree(seeded), fn _ ->
        %{warnings: warnings} = Environments.validate()
        assert Enum.any?(warnings, &(&1 =~ "env-new-module" and &1 =~ "compile error"))
      end)
    end
  end

  describe "set assignment is one-way" do
    test "an environment already in a set cannot be moved to another" do
      verified = environment("env-a", %{"verification" => verification("verified")})

      Fixture.with_tree(tree([verified]), fn _ ->
        {:ok, _} = Environments.assign("env-a", "holdout")

        assert {:error, message} = Environments.assign("env-a", "benchmark")
        assert message =~ "already in the holdout set"
        assert message =~ "one-way"

        assert {:ok, %{"set" => "holdout"}} = Environments.fetch("env-a")
      end)
    end

    test "assigning the set it already has is not a move" do
      verified = environment("env-a", %{"verification" => verification("verified")})

      Fixture.with_tree(tree([verified]), fn _ ->
        {:ok, _} = Environments.assign("env-a", "transfer")
        assert {:ok, %{"set" => "transfer"}} = Environments.assign("env-a", "transfer")
      end)
    end

    test "an unknown set name is refused" do
      verified = environment("env-a", %{"verification" => verification("verified")})

      Fixture.with_tree(tree([verified]), fn _ ->
        assert {:error, message} = Environments.assign("env-a", "validation")
        assert message =~ "benchmark"
      end)
    end
  end

  describe "the verifier is a secret" do
    test "two sets sharing one test file is an error" do
      shared = %{
        "kind" => "reverse_patch",
        "app" => "acme",
        "files" => ["test/acme/runtime_test.exs"],
        "source_paths" => ["apps/acme/lib/acme/runtime.ex"]
      }

      seeded = [
        environment("env-a", %{
          "set" => "benchmark",
          "verifier" => shared,
          "verification" => verification("verified")
        }),
        environment("env-b", %{
          "set" => "holdout",
          "verifier" => shared,
          "verification" => verification("verified")
        })
      ]

      Fixture.with_tree(tree(seeded), fn _ ->
        %{errors: errors} = Environments.validate()

        assert Enum.any?(errors, fn error ->
                 error =~ "runtime_test.exs" and error =~ "benchmark and holdout"
               end)
      end)
    end

    test "two environments in the same set may share a file" do
      shared = %{
        "kind" => "reverse_patch",
        "app" => "acme",
        "files" => ["test/acme/runtime_test.exs"],
        "source_paths" => ["apps/acme/lib/acme/runtime.ex"]
      }

      seeded =
        for id <- ~w(env-a env-b) do
          environment(id, %{
            "set" => "benchmark",
            "verifier" => shared,
            "verification" => verification("verified")
          })
        end

      Fixture.with_tree(tree(seeded), fn _ ->
        %{errors: errors} = Environments.validate()
        refute Enum.any?(errors, &(&1 =~ "runtime_test.exs"))
      end)
    end
  end

  describe "validate/0" do
    test "a transfer set drawn from the benchmark's own apps is warned about" do
      seeded = [
        environment("env-bench", %{
          "set" => "benchmark",
          "verification" => verification("verified")
        }),
        environment("env-hold", %{"set" => "holdout", "verification" => verification("verified")}),
        environment("env-trans", %{
          "set" => "transfer",
          "verification" => verification("verified")
        })
      ]

      Fixture.with_tree(tree(seeded), fn root ->
        # Which app a source path names is the layout's to say.
        Fixture.write_project(root)
        %{warnings: warnings} = Environments.validate()
        assert Enum.any?(warnings, &(&1 =~ "measuring the benchmark's task family twice"))
      end)
    end

    test "an empty set is warned about, because a gate reading it reads nothing" do
      Fixture.with_tree(tree([]), fn _ ->
        %{warnings: warnings} = Environments.validate()

        for set <- Environments.sets() do
          assert Enum.any?(warnings, &(&1 =~ "the #{set} set is empty"))
        end
      end)
    end

    test "a verified environment with no statement has nothing to hand an agent" do
      seeded = [
        environment("env-a", %{
          "statement" => nil,
          "set" => "benchmark",
          "verification" => verification("verified")
        })
      ]

      Fixture.with_tree(tree(seeded), fn _ ->
        %{warnings: warnings} = Environments.validate()
        assert Enum.any?(warnings, &(&1 =~ "env-a" and &1 =~ "no statement"))
      end)
    end
  end

  describe "list/1 filters" do
    test "no options is everything; set: nil is the unassigned, which is not the same" do
      seeded = [
        environment("env-loose"),
        environment("env-placed", %{
          "set" => "benchmark",
          "verification" => verification("verified")
        })
      ]

      Fixture.with_tree(tree(seeded), fn _ ->
        assert length(Environments.list()) == 2
        assert Enum.map(Environments.list(set: nil), & &1["id"]) == ["env-loose"]
      end)
    end
  end

  describe "provenance" do
    test "an id is not reused, because the history is what makes the file worth having" do
      Fixture.with_tree(tree([environment("env-a")]), fn _ ->
        assert {:error, message} = Environments.put(environment("env-a"))
        assert message =~ "already exists"
      end)
    end

    test "an id that could become any path is refused" do
      Fixture.with_tree(tree([]), fn _ ->
        assert {:error, message} = Environments.put(environment("../../etc/passwd"))
        assert message =~ "becomes a filename"
      end)
    end

    test "a verification is stamped with when, and with the tree it was asked about" do
      Fixture.with_tree(tree([environment("env-a")]), fn _ ->
        {:ok, updated} =
          Environments.record_verification("env-a", %{state: "rejected", reason: "no"})

        assert {:ok, _, _} = DateTime.from_iso8601(updated["verification"]["at"])
        # `head` is nil in a fixture tree, which is not a git repository — the
        # point is that the key exists and is not silently omitted.
        assert Map.has_key?(updated["verification"], "head")
      end)
    end

    test "an environment with no test verifies nothing and is refused" do
      broken = environment("env-a", %{"verifier" => %{"kind" => "reverse_patch", "files" => []}})

      Fixture.with_tree(tree([]), fn _ ->
        assert {:error, message} = Environments.put(broken)
        assert message =~ "verifies nothing"
      end)
    end

    test "recording a verification keeps the previous one" do
      Fixture.with_tree(tree([environment("env-a")]), fn _ ->
        {:ok, _} = Environments.record_verification("env-a", verification("verified", "first"))

        {:ok, updated} =
          Environments.record_verification("env-a", verification("rejected", "second"))

        assert updated["verification"]["reason"] == "second"

        # An earlier change changed this from `["because", "first"]`. The `because`
        # was the fixture's `unverified` record — the state `derive/2` leaves
        # behind before anybody has run anything. It is not a verification that
        # happened, and the real stub carries none of the fields the schema
        # requires of a history entry, so the validator rejected the first
        # environment ever derived and verified through this path.
        assert Enum.map(updated["verification_history"], & &1["reason"]) == ["first"]
      end)
    end

    test "a verification state outside the four is refused" do
      Fixture.with_tree(tree([environment("env-a")]), fn _ ->
        assert {:error, message} =
                 Environments.record_verification("env-a", %{state: "probably fine"})

        assert message =~ "verified"
      end)
    end
  end

  describe "verification never reports more than it established" do
    test "a verifier kind with no runner is unavailable, not rejected" do
      seeded = [
        environment("env-a", %{
          "verifier" => %{
            "kind" => "reverse_patch",
            "app" => "acme",
            "files" => ["test/x_test.exs"],
            "source_paths" => ["apps/acme/lib/x.ex"]
          }
        })
      ]

      # The fixture tree is not a git repository, so the fix commit cannot be
      # read. That is a statement about our ability to ask, and it must not be
      # reported as a statement about the test.
      Fixture.with_tree(tree(seeded), fn _ ->
        {:ok, environment} = Environments.verify("env-a", by: "test")
        assert environment["verification"]["state"] == "unavailable"
        assert environment["verification"]["failed_before"] == nil
      end)
    end

    test "state/1 reads unverified from an environment that has never been run" do
      assert Environments.state(%{}) == "unverified"
    end
  end

  describe "a suite that is replenished and retired, not merely derived once" do
    # A suite derived from history decays: the repository moves, a
    # fix stops reverse-applying, and a set that quietly stops discriminating
    # scores everything the same while looking like it is working. In an
    # autonomous loop nobody re-reads it, so the loop optimising against it
    # looks like it is improving.

    defp verified(id, set) do
      environment(id, %{
        "set" => set,
        "verification" =>
          Map.merge(verification("verified"), %{
            "head" => String.duplicate("c", 40),
            "discrimination" => "assertion"
          })
      })
    end

    test "retiring needs a reason, and 'stale' is not one" do
      Fixture.with_tree(tree([verified("env-a", "benchmark")]), fn _ ->
        assert {:error, message} = Environments.retire("env-a", reason: "stale")
        assert message =~ "twenty characters"

        assert {:error, missing} =
                 Environments.retire("env-nope", reason: String.duplicate("x", 30))

        assert missing =~ "no environment"
      end)
    end

    test "a retired environment leaves the ordinary reads and keeps its reason" do
      Fixture.with_tree(
        tree([verified("env-a", "benchmark"), verified("env-b", "benchmark")]),
        fn _ ->
          reason = "its verifier passes with and without the fix since the loader was rewritten"

          assert :ok = Environments.retire("env-a", reason: reason, replaced_by: "env-b")

          ids = Enum.map(Environments.list(), & &1["id"])
          refute "env-a" in ids, "a retired environment is still in the ordinary listing"
          assert "env-b" in ids

          refute Enum.any?(Environments.suite("benchmark"), &(&1["id"] == "env-a")),
                 "a retired environment is still scoring candidates"

          assert [retired] = Environments.list(retired: true)
          assert retired["id"] == "env-a"
          assert retired["retired"]["reason"] == reason
          assert retired["retired"]["replaced_by"] == "env-b"
        end
      )
    end

    test "retiring twice is refused, and restoring keeps the retirement on the file" do
      Fixture.with_tree(tree([verified("env-a", "benchmark")]), fn _ ->
        reason = String.duplicate("a real reason, at length. ", 2)

        assert :ok = Environments.retire("env-a", reason: reason)
        assert {:error, again} = Environments.retire("env-a", reason: reason)
        assert again =~ "already retired"

        assert :ok = Environments.restore("env-a", reason: "it was retired against the wrong id")

        assert {:ok, environment} = Environments.fetch("env-a")
        refute Environments.retired?(environment)

        assert [entry] = environment["retired_history"],
               "the retirement vanished; a suite's value is its provenance and " <>
                 "'retired and then brought back' is exactly what a later reader needs"

        assert entry["restored_because"] =~ "wrong id"
      end)
    end

    test "coverage counts what a set actually holds" do
      seeded = [
        verified("env-a", "benchmark"),
        verified("env-b", "benchmark"),
        environment("env-c", %{
          "set" => "benchmark",
          "verification" => verification("unavailable")
        })
      ]

      Fixture.with_tree(tree(seeded), fn _ ->
        coverage = Environments.coverage()

        assert coverage["benchmark"]["members"] == 3
        assert coverage["benchmark"]["verified"] == 2
        assert coverage["benchmark"]["unavailable"] == 1
        assert coverage["benchmark"]["discriminating"] == 2
        assert coverage["holdout"]["members"] == 0
      end)
    end

    test "a member that failed to compile is not counted as discriminating" do
      # The validator already warns about this and nothing counted it. A test
      # that failed to compile before the fix proves the file was broken, not
      # that the test discriminates anything.
      compiling =
        environment("env-c", %{
          "set" => "benchmark",
          "verification" => Map.merge(verification("verified"), %{"discrimination" => "compile"})
        })

      Fixture.with_tree(tree([verified("env-a", "benchmark"), compiling]), fn _ ->
        coverage = Environments.coverage()

        assert coverage["benchmark"]["verified"] == 2
        assert coverage["benchmark"]["discriminating"] == 1
      end)
    end

    test "a set below the floor is an error, not a note" do
      # An earlier change is explicit: a scoring run over two environments is not a
      # measurement, and an earlier change's refusal to score a partially verified
      # suite is the same rule from the other end.
      #
      # Distinct from the `unavailable` warning, which is about one member and
      # about our ability to ask — making *that* an error would punish the
      # honest act of re-verifying.
      Fixture.with_tree(
        tree([verified("env-a", "benchmark"), verified("env-b", "benchmark")]),
        fn _ ->
          %{errors: errors} = Environments.validate()

          assert Enum.any?(errors, &(&1 =~ "benchmark set has 2 verified member(s)")),
                 "a set of two was accepted: #{inspect(errors)}"
        end
      )

      at_floor = for n <- 1..Environments.floor(), do: verified("env-#{n}", "benchmark")

      Fixture.with_tree(tree(at_floor), fn _ ->
        %{errors: errors} = Environments.validate()

        refute Enum.any?(errors, &(&1 =~ "benchmark set has")),
               "a set at the floor was refused: #{inspect(errors)}"
      end)
    end

    test "a repository with no environment at all has no suite yet: warnings, not the floor" do
      # A repository fresh from `harness init` has no environment,
      # and the floor above would fail its `validate` on three sets it has not
      # had a chance to fill. There is no suite there to shrink, so it is told
      # each set is empty and nothing more.
      Fixture.with_tree(%{}, fn _ ->
        %{errors: errors, warnings: warnings} = Environments.validate()

        refute Enum.any?(errors, &(&1 =~ "verified member(s)")),
               "an empty repository was held to the floor: #{inspect(errors)}"

        for set <- Environments.sets() do
          assert Enum.any?(warnings, &(&1 =~ "the #{set} set is empty")),
                 "the #{set} set's emptiness went unsaid: #{inspect(warnings)}"
        end
      end)

      # One environment, in any set or none, is a suite, and the floor binds
      # every set again: a suite cannot shrink below it unnoticed.
      Fixture.with_tree(tree([verified("env-a", "benchmark")]), fn _ ->
        %{errors: errors} = Environments.validate()

        for set <- Environments.sets() do
          assert Enum.any?(errors, &(&1 =~ "the #{set} set has")),
                 "one environment and the #{set} set escaped the floor: #{inspect(errors)}"
        end
      end)
    end

    test "the unverified stub never enters the verification history" do
      # Found by the validator on the first environment ever derived and
      # verified through this path: `derive/2` writes an `unverified` stub that
      # says `"reason": "never run"` and carries none of `at`, `head`,
      # `by_attested`, `by_from`, `evidence` or `discrimination`, and pushing
      # it into the history produced a record the schema rejects.
      #
      # A history of verifications should contain verifications.
      Fixture.with_tree(tree([environment("env-a")]), fn _ ->
        {:ok, updated} =
          Environments.record_verification("env-a", %{
            state: "verified",
            reason: "it failed before and passes after",
            failed_before: true,
            passed_after: true
          })

        assert updated["verification_history"] == [],
               "the never-run stub was recorded as a verification that happened"

        {:ok, again} =
          Environments.record_verification("env-a", %{
            state: "unavailable",
            reason: "the parent is not in this checkout",
            failed_before: nil,
            passed_after: nil
          })

        assert [first] = again["verification_history"]
        assert first["state"] == "verified", "a real verdict was dropped from the history"
      end)
    end
  end
end
