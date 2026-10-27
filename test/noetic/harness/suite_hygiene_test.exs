defmodule Noetic.Harness.SuiteHygieneTest do
  # `async: true`: reads this directory, writes nothing.
  use ExUnit.Case, async: true

  @moduledoc """
  A file that runs sync says why, above the flag.

  Six files were `async: false` with no reason written anywhere,
  and the only way to find out whether they had to be was to read each one
  looking for shared state. Three of the six turned out to be sync only because
  the harness root used to be a VM-global, which an earlier change fixed; three had
  real reasons nobody had written down — `PATH`, the dispatch adapter, and the
  real run registry.

  This test is the part that does not decay. A comment is cheap to write while
  the reason is in your head and expensive to reconstruct afterwards, and the
  cost of *not* writing it was measured: the investigation was six files.

  It also corrects the bead's arithmetic, which is worth keeping because it is
  the kind of number that gets repeated. An earlier change says the suite is 440s of
  which 339s is sync, and implies that flipping the undocumented files returns
  that wall clock. It does not. Measured per file on 2026-09-22:

      dispatcher_test     145.4s     repoints the dispatch adapter
      workspace_test       80.8s     real git worktrees
      entry_points_test    48.0s     subprocesses in bash, zsh and sh
      scoring_test         13.7s
      adapters_test         9.7s
      beads_test            8.8s
      conductor_test        8.4s
      run_test              3.5s
      environments_test     3.1s
      hooks_test            1.2s
      adapter_test          0.2s

  274 of the ~323 sync seconds are the top three, all of them documented and
  all of them correctly sync. `dispatcher_test` is 58 tests that each create a
  real git worktree, which is the isolation property they exist to check.
  Flipping the three undocumented files that could be flipped bought about
  thirty seconds. The rule below is what this bead is actually worth.
  """

  @dir Path.expand("../..", __DIR__)

  defp test_files do
    Path.wildcard(Path.join(@dir, "**/*_test.exs"))
  end

  describe "a file that cannot run concurrently" do
    test "there are test files to check, and some of them are sync" do
      # The calibration. A wildcard that matched nothing, or a suite that went
      # fully async, would make the test below pass over an empty list — and
      # this repository has shipped exactly that twice.
      files = test_files()

      assert length(files) > 20, "found #{length(files)} test files; the wildcard is wrong"

      sync = Enum.filter(files, &(File.read!(&1) =~ ~r/^\s*use ExUnit\.Case, async: false/m))

      assert sync != [], "no file is sync, so the rule below is checking nothing"
    end

    test "says why, in a comment above the flag" do
      for path <- test_files() do
        lines = path |> File.read!() |> String.split("\n")

        case Enum.find_index(lines, &(&1 =~ ~r/^\s*use ExUnit\.Case, async: false/)) do
          nil ->
            :ok

          index ->
            reason =
              lines
              |> Enum.take(index)
              |> Enum.reverse()
              |> Enum.take_while(
                &(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#"))
              )
              |> Enum.map(&String.trim/1)
              |> Enum.filter(&String.starts_with?(&1, "#"))
              |> Enum.join(" ")

            assert String.length(reason) > 60,
                   "#{Path.relative_to(path, @dir)} is `async: false` with no reason written " <>
                     "above it. Say what the shared state is — an environment variable, an " <>
                     "application key, a real file in `.agents/`, a subprocess. Six files " <>
                     "without that comment cost a whole investigation, and the " <>
                     "next reader cannot tell a deliberate sync from a forgotten one."
        end
      end
    end

    test "the reason names something, rather than only asserting there is one" do
      # "async: false because it has to be" would satisfy the length check and
      # tell the next reader nothing. The shared state in this repository is
      # one of a small number of things, and naming which is the whole value.
      # Not a closed vocabulary — the check is that something concrete is
      # named, and the list grows when a reason names something real that is
      # not on it. `adapters_test` is why "generated" and "file" are here: its
      # reason ("edits a generated file to prove drift is detected, and a
      # concurrent test reading that file would see the edit") is a perfectly
      # good one and the first version of this list rejected it.
      named =
        ~w(env PATH Application global VM-global subprocess worktree git registry
           .agents adapter dictionary stdin stdout real generated file concurrent
           shared)

      for path <- test_files() do
        contents = File.read!(path)

        if contents =~ ~r/^\s*use ExUnit\.Case, async: false/m do
          head = contents |> String.split("use ExUnit.Case") |> hd()

          assert Enum.any?(named, &String.contains?(head, &1)),
                 "#{Path.relative_to(path, @dir)} says it is sync but names no shared state. " <>
                   "One of #{Enum.join(named, ", ")} is almost certainly the reason; if it is " <>
                   "genuinely something else, say what and this list grows."
        end
      end
    end
  end
end
