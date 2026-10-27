defmodule Noetic.Harness.GitTest do
  @moduledoc """
  The argv `Noetic.Harness.Git` hands to git: what came from a file
  or a caller is a value, never an option.
  """

  use ExUnit.Case, async: true

  alias Noetic.Harness.Git

  setup do
    root = Path.join(System.tmp_dir!(), "harness-git-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(root)
    git!(root, ["init", "-q", "-b", "main"])
    File.write!(Path.join(root, "a.ex"), "defmodule Alpha do\nend\n")
    File.write!(Path.join(root, "b.ex"), "defmodule Beta do\n  -flag\nend\n")
    git!(root, ["add", "a.ex", "b.ex"])
    git!(root, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"])

    previous = Noetic.Harness.root_override()
    Noetic.Harness.put_root(root)

    on_exit(fn ->
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp git!(root, args) do
    {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end

  describe "changed_since/1" do
    test "a base that is an option is refused, and writes nothing", %{root: root} do
      target = Path.join(root, "written-by-git-diff")

      assert Git.changed_since("--output=#{target}") == :error
      refute File.exists?(target), "git diff took the run's base as --output"
    end

    test "a base that is not a commit id is refused before git sees it" do
      for base <- ["HEAD", "main", "HEAD~1", "abc", "ABCDEF1", "abcdef1 --stat"] do
        assert Git.changed_since(base) == :error, "accepted #{inspect(base)}"
      end
    end

    test "a hex base that is also a file name is a commit, not a path", %{root: root} do
      # Review: with no `--` after it, git read `abcdef1` as the file of that
      # name, and answered with that one file instead of the run's change.
      File.write!(Path.join(root, "abcdef1"), "")
      git!(root, ["add", "abcdef1"])
      git!(root, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "f"])
      File.write!(Path.join(root, "abcdef1"), "changed")
      File.write!(Path.join(root, "a.ex"), "changed")

      assert Git.changed_since("abcdef1") == :error
    end

    test "a git warning is not a changed path", %{root: root} do
      # Review: a tag named like the short sha made git warn that the refname
      # is ambiguous, and the warning came back as a path.
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
      short = String.slice(sha, 0, 7)
      git!(root, ["tag", short])
      File.write!(Path.join(root, "a.ex"), "changed")

      assert {:ok, ["a.ex"]} = Git.changed_since(short)
    end

    test "a repository's config runs nothing", %{root: root} do
      marker = Path.join(root, "external-diff-ran")
      git!(root, ["config", "diff.external", "touch #{marker}; true"])
      git!(root, ["config", "core.fsmonitor", "touch #{marker}; false"])
      File.write!(Path.join(root, "a.ex"), "changed")

      assert {:ok, _} = Git.tree_fingerprint()
      assert {:ok, _} = Git.diff_stat()
      assert {:ok, _} = Git.changed_paths()
      refute File.exists?(marker), "git ran a command the repository's config named"
    end

    test "a real commit id still answers", %{root: root} do
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
      File.write!(Path.join(root, "a.ex"), "defmodule Alpha do\n  :changed\nend\n")
      File.write!(Path.join(root, "new.ex"), "")

      assert {:ok, ["a.ex", "new.ex"]} = Git.changed_since(String.trim(sha))
      assert {:ok, ["a.ex", "new.ex"]} = Git.changed_since(String.slice(sha, 0, 7))
    end
  end

  describe "tree_fingerprint/0" do
    test "streaming the untracked files gives the digest one hash call gave", %{root: root} do
      # An earlier change hashes file by file instead of building one iolist of every
      # untracked file's contents. Fingerprints are recorded in committed runs
      # and compared later, so the new digest must be the old one.
      File.write!(Path.join(root, "a.ex"), "changed")
      File.write!(Path.join(root, "z-untracked.txt"), "zed")
      File.write!(Path.join(root, "m-untracked.txt"), String.duplicate("m", 70_000))

      out = fn args ->
        {text, 0} = System.cmd("git", args, cd: root)
        text
      end

      head = out.(["rev-parse", "HEAD"])

      status =
        out.([
          "status",
          "--porcelain=v1",
          "-z",
          "--no-renames",
          "--untracked-files=all",
          "--",
          ".",
          ":(exclude).agents/runs"
        ])

      diff =
        out.([
          "diff",
          "--no-ext-diff",
          "--no-textconv",
          "HEAD",
          "--",
          ".",
          ":(exclude).agents/runs"
        ])

      untracked =
        for path <- ["m-untracked.txt", "z-untracked.txt"],
            do: [path, "\0", File.read!(Path.join(root, path))]

      once =
        :crypto.hash(:sha256, [head, "\0", status, "\0", diff, "\0", untracked])
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      assert {:ok, ^once} = Git.tree_fingerprint()
    end
  end

  describe "files/1" do
    test "what git would show: tracked, untracked, never ignored", %{root: root} do
      File.mkdir_p!(Path.join(root, "deep/er"))
      File.write!(Path.join(root, "deep/er/c.ex"), "")
      File.mkdir_p!(Path.join(root, "_build/x"))
      File.write!(Path.join(root, "_build/x/d.ex"), "")
      File.write!(Path.join(root, ".gitignore"), "_build/\n")

      assert {:ok, ["a.ex", "b.ex", "deep/er/c.ex"]} = Git.files("**/*.ex")
      assert {:ok, ["deep/er/c.ex"]} = Git.files("deep/*/*.ex")
    end

    test "below the top of a work tree it is :error, and the disk is asked", %{root: root} do
      sub = Path.join(root, "sub")
      File.mkdir_p!(sub)
      Noetic.Harness.put_root(sub)
      assert Git.files("**/*.ex") == :error
    end
  end

  describe "grep/2" do
    test "every needle is searched for" do
      assert {:ok, lines} = Git.grep(["Alpha", "Beta"], 10)
      assert Enum.any?(lines, &(&1 =~ "a.ex:1:"))
      assert Enum.any?(lines, &(&1 =~ "b.ex:1:"))
    end

    test "a needle beginning with - is a pattern, not an option" do
      assert {:ok, ["b.ex:2:  -flag"]} = Git.grep(["-flag"], 10)
    end

    test "a needle that matches nothing is an empty result" do
      assert {:ok, []} = Git.grep(["Gamma"], 10)
    end

    test "a needle is a string, not a pattern" do
      assert {:ok, []} = Git.grep(["Alph."], 10)
    end

    test "git failing is :error, not \"no callers\"" do
      Noetic.Harness.put_root(System.tmp_dir!())
      assert Git.grep(["Alpha"], 10) == :error
    end
  end
end
