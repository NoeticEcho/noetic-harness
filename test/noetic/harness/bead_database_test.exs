defmodule Noetic.Harness.BeadDatabaseTest do
  @moduledoc """
  A design decision's one bead database, as `SessionStart` checks it.

  The session worktree ran a bead database of its own for days, 264 issues
  beside the main checkout's 161, and nothing said so. Every case here is a
  real git checkout with a real `git worktree add`, because the question is
  where git puts the main checkout, and a fixture that only pretends to be a
  worktree would answer it by construction.
  """
  # async: true. Nothing global is touched: `BEADS_DIR`, `BEADS_DB` and
  # `CLAUDE_CODE_REMOTE` are passed as options everywhere, including to
  # SessionStart, and the root override is per process.
  use ExUnit.Case, async: true

  alias Noetic.Harness.{Attach, Beads}

  setup do
    base = Noetic.Harness.TestTmp.dir!("bead-db")
    on_exit(fn -> File.rm_rf(base) end)

    git!(["init", "--quiet", Path.join(base, "main")])
    main = git!(["-C", Path.join(base, "main"), "rev-parse", "--show-toplevel"])

    git!(
      ["-C", main, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] ++
        ["-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--allow-empty", "-m", "init"]
    )

    git!(
      ["-C", main, "-c", "core.hooksPath=/dev/null", "worktree", "add", "--quiet"] ++
        ["--detach", Path.join(base, "wt")]
    )

    worktree = git!(["-C", Path.join(base, "wt"), "rev-parse", "--show-toplevel"])

    # `beads` is an integration: this worktree has it, as this
    # repository does. Untracked, so the checkout git reads is unchanged.
    Noetic.Harness.Fixture.write_project(worktree)

    coordinator = Path.join([main, ".beads", "embeddeddolt"])
    File.mkdir_p!(coordinator)

    {:ok, base: base, main: main, worktree: worktree, coordinator: coordinator}
  end

  # Every environment variable the check reads, pinned, so the machine's own
  # BEADS_DIR cannot decide a test (it did, in the first version).
  @clean [beads_dir: nil, beads_db: nil]

  defp git!(args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    String.trim(out)
  end

  describe "which database bd would use" do
    test "the main checkout's own is the coordinator's", %{main: main} do
      assert Beads.database_split(main, @clean) == :ok
    end

    test "a worktree with none of its own falls back to it", %{worktree: worktree} do
      assert Beads.database_split(worktree, @clean) == :ok
    end

    test "a worktree with one of its own is a split", ctx do
      own = Path.join([ctx.worktree, ".beads", "embeddeddolt"])
      File.mkdir_p!(own)

      assert {:split, "this worktree has a database of its own", ^own, coordinator} =
               Beads.database_split(ctx.worktree, @clean)

      assert coordinator == ctx.coordinator
    end

    test "BEADS_DIR is a split unless it names the main checkout's", ctx do
      elsewhere = Path.join(ctx.base, "elsewhere/.beads")
      File.mkdir_p!(elsewhere)

      assert {:split, "BEADS_DIR names " <> _, where, _} =
               Beads.database_split(ctx.worktree, beads_dir: elsewhere, beads_db: nil)

      assert where == Path.join(elsewhere, "embeddeddolt")

      assert Beads.database_split(ctx.worktree,
               beads_dir: Path.join(ctx.main, ".beads"),
               beads_db: nil
             ) == :ok
    end

    test "a redirect is a split unless it leads to the main checkout's", ctx do
      beads = Path.join(ctx.worktree, ".beads")
      File.mkdir_p!(beads)
      redirect = Path.join(beads, "redirect")

      # Relative, as bd writes it: from the worktree, up one and into main.
      File.write!(redirect, "../main/.beads\n")
      assert Beads.database_split(ctx.worktree, @clean) == :ok

      File.write!(redirect, Path.join(ctx.base, "elsewhere/.beads"))

      assert {:split, ".beads/redirect leads there", where, _} =
               Beads.database_split(ctx.worktree, @clean)

      assert where == Path.join(ctx.base, "elsewhere/.beads/embeddeddolt")

      # Relative to `.beads` rather than to the checkout root: bd does not read
      # it that way, so this names nothing it would use. The first version
      # accepted both readings and called this one fine.
      File.write!(redirect, "../../main/.beads\n")
      assert {:split, _, _, _} = Beads.database_split(ctx.worktree, @clean)
    end

    test "an empty or unreadable redirect is a split, and never a crash", ctx do
      beads = Path.join(ctx.worktree, ".beads")
      File.mkdir_p!(beads)
      redirect = Path.join(beads, "redirect")

      File.write!(redirect, "  \n")

      assert {:split, ".beads/redirect is empty" <> _, _, _} =
               Beads.database_split(ctx.worktree, @clean)

      File.write!(redirect, "../main/.beads\n")
      File.chmod!(redirect, 0o000)
      on_exit(fn -> File.chmod(redirect, 0o644) end)

      # Root reads anything, so this half means something only as a user.
      if match?({:error, _}, File.read(redirect)) do
        assert {:split, ".beads/redirect is empty or unreadable" <> _, _, _} =
                 Beads.database_split(ctx.worktree, @clean)
      end
    end

    test "an earlier rule wins, as it does in bd", ctx do
      File.mkdir_p!(Path.join([ctx.worktree, ".beads", "embeddeddolt"]))

      assert Beads.database_split(ctx.worktree,
               beads_dir: Path.join(ctx.main, ".beads"),
               beads_db: nil
             ) == :ok,
             "BEADS_DIR names the main checkout's, so bd uses it despite the worktree's own"

      File.write!(Path.join([ctx.worktree, ".beads", "redirect"]), "../main/.beads\n")

      assert Beads.database_split(ctx.worktree, @clean) == :ok,
             "the redirect leads to the main checkout's, so bd follows it"
    end

    test "a BEADS_DIR that does not exist is ignored, as bd ignores it", ctx do
      assert Beads.database_split(ctx.worktree,
               beads_dir: Path.join(ctx.base, "nowhere/.beads"),
               beads_db: nil
             ) == :ok

      assert Beads.database_split(ctx.worktree, beads_dir: "", beads_db: nil) == :ok
    end

    test "BEADS_DB is a split unless it names the coordinator's", ctx do
      elsewhere = Path.join(ctx.base, "nowhere/.beads/embeddeddolt")

      assert {:split, "BEADS_DB names " <> _, ^elsewhere, _} =
               Beads.database_split(ctx.worktree, beads_dir: nil, beads_db: elsewhere)

      assert Beads.database_split(ctx.worktree, beads_dir: nil, beads_db: ctx.coordinator) == :ok
      assert Beads.database_split(ctx.worktree, beads_dir: nil, beads_db: "") == :ok
    end

    test "asked from a subdirectory, the checkout's root is what counts", ctx do
      # What `checkout/1` asks git for: the top level. With the path as given,
      # a database of the worktree's own would be looked for under the
      # subdirectory, and not found.
      File.mkdir_p!(Path.join([ctx.worktree, ".beads", "embeddeddolt"]))
      sub = Path.join(ctx.worktree, "apps/deep")
      File.mkdir_p!(sub)

      assert {:split, "this worktree has a database of its own", _, _} =
               Beads.database_split(sub, @clean)
    end

    test "the main checkout reached through a symlink is still the main checkout", ctx do
      # Directories are compared by device and inode, so the link and the main
      # checkout are one place, and the coordinator's own database is not
      # mistaken for a worktree's.
      link = Path.join(ctx.base, "link-to-main")
      File.ln_s!(ctx.main, link)

      assert Beads.database_split(link, @clean) == :ok
    end

    test "outside git there is no main checkout to compare with", %{base: base} do
      outside = Path.join(base, "not-a-checkout")
      File.mkdir_p!(outside)

      assert Beads.database_split(outside, @clean) == :unknown
    end
  end

  # An empty ready list handed in, so no test here waits on the real `bd`.
  defp quiet(remote), do: [ready: fn -> {:live, {:ok, ""}} end, remote: remote] ++ @clean

  describe "SessionStart" do
    test "says so, loudly, when the database is not the coordinator's", ctx do
      File.mkdir_p!(Path.join([ctx.worktree, ".beads", "embeddeddolt"]))
      Noetic.Harness.put_root(ctx.worktree)

      {:ok, text} = Attach.context("session_start", %{}, quiet(nil))

      assert text =~ "NOT THE COORDINATOR'S BEAD DATABASE"
      assert text =~ ctx.coordinator
    end

    test "says nothing about it when the database is the coordinator's", ctx do
      Noetic.Harness.put_root(ctx.worktree)

      {:ok, text} = Attach.context("session_start", %{}, quiet(nil))

      refute text =~ "COORDINATOR'S BEAD DATABASE"
    end

    test "an empty CLAUDE_CODE_REMOTE is a local session", ctx do
      File.mkdir_p!(Path.join([ctx.worktree, ".beads", "embeddeddolt"]))
      Noetic.Harness.put_root(ctx.worktree)

      {:ok, text} = Attach.context("session_start", %{}, quiet(""))

      assert text =~ "NOT THE COORDINATOR'S BEAD DATABASE"
    end

    test "says nothing about it in a cloud session, which never writes beads", ctx do
      File.mkdir_p!(Path.join([ctx.worktree, ".beads", "embeddeddolt"]))
      Noetic.Harness.put_root(ctx.worktree)

      {:ok, text} = Attach.context("session_start", %{}, quiet("true"))

      refute text =~ "COORDINATOR'S BEAD DATABASE"
    end
  end
end
