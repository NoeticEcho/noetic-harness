defmodule Noetic.Harness.Workspace do
  alias Noetic.Harness.{Realpath, Tree}

  @moduledoc """
  Where a dispatched run is allowed to write.

  A dispatched run gets its own git worktree, may write freely
  inside it, and lands nothing. This module is that worktree — opening it,
  reading what changed in it, showing the diff, and taking it away again.

  ## Why this is not in `Git`

  `Noetic.Harness.Git` opens its moduledoc with "deliberately read-only… the
  harness *describes* work; it does not commit, branch, merge or push", and
  that sentence is load-bearing: it is why a context builder cannot have a side
  effect on your tree. Creating a worktree is a write, so it lives here instead
  of widening the one module whose guarantee is that it never writes. The two
  are separated by what they may do, not by subject matter.

  What this module still may not do is the important half. It creates a branch
  and a directory. It does not commit, merge, push, or touch a branch anything
  else has. A dispatched run's product is a diff plus the ledger entry, and
  both are the parent's to present.

  ## Where the worktrees live, and why there

  Under the repository's *git common directory* — `.git/noetic-harness/` — and
  not beside the source.

  A worktree checked out inside the working tree shows up in the parent's
  `git status` as an untracked directory, which is one `git add` away from a
  dispatched agent's half-finished work being committed by a human who did not
  write it. This repository forbids `git add -A` for exactly that failure and
  dispatch makes it worse, so the answer is to put the checkout somewhere
  `git status` does not look. `.git/` is on the same filesystem, so the
  checkout is cheap, and it is removed when the repository is.

  `NOETIC_HARNESS_WORKTREE_ROOT` overrides it, which is what a test uses.

  **A scoring solver's tree is the exception**, and `open/2`'s `:root` is how
  it is made. From a tree under `.git/`, `git -C ..` is the host repository,
  because git searches upward, and a solver scored on a fix it can read from
  there is not measured. `Scoring` opens each arm under a private temporary
  directory no repository encloses (`Tree.solver_root/0`). The
  worktree is still this repository's, registered and locked like any other,
  so `close/2`, `tree_git/1` and `prune/1` find it by its branch wherever it
  is.

  ## Two things learned by running it

  **The parent repository's hooks fire on `worktree add`.** `post-checkout`
  runs in the new worktree, and here that is beads' hook, which tried an import
  against an uninitialised database and printed an error into the middle of the
  dispatch. A dispatched worktree is not a checkout a person made and has no
  business triggering a sync, so the command runs with
  `-c core.hooksPath=/dev/null`.

  **`git add -A` is the right call here and nowhere else.** `changed_paths/1`
  and `diff/1` have to see files the agent *created*, which a plain
  `git diff` does not. They use `add -A --intent-to-add`, which records that a
  path exists and stages no content. The constitution's rule is about a working
  directory more than one session shares; this directory has exactly one
  writer, and the rule's own stated reason does not reach it.
  """

  @type t :: %{
          run: String.t(),
          path: String.t(),
          branch: String.t(),
          base: String.t()
        }

  @doc """
  The directory worktrees are created under.
  """
  @spec root() :: {:ok, String.t()} | {:error, String.t()}
  def root do
    case System.get_env("NOETIC_HARNESS_WORKTREE_ROOT") do
      nil ->
        case common_dir() do
          {:ok, dir} -> {:ok, Path.join(dir, "noetic-harness")}
          :error -> {:error, "this is not a git repository, so there is nowhere to isolate a run"}
        end

      override ->
        {:ok, override}
    end
  end

  defp root(opts) do
    case Keyword.get(opts, :root) do
      nil -> root()
      dir -> {:ok, dir}
    end
  end

  @doc """
  The branch a run's worktree is checked out on.

  Under `harness/run/`, so that `git branch --list 'harness/run/*'` is the list
  of dispatched runs that have written something and `git branch -d` on one is
  obviously safe.
  """
  @spec branch_for(String.t()) :: String.t()
  def branch_for(run_id), do: "harness/run/" <> run_id

  @doc """
  Open the worktree for a run, or return the one it already has.

  Re-opening is deliberate rather than an error: a run that dispatches twice
  writes into the same isolated tree, which is what makes the second attempt's
  diff comparable with the first. Two runs never share one, because the path is
  the run id.

  `:root` opens it under that directory instead of `root/0` — see the
  moduledoc for the one caller that needs it. `list/0` and the bare
  directories `orphans/0` looks for are still `root/0`'s.
  """
  @spec open(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def open(run_id, opts \\ []) do
    with :ok <- valid_id(run_id),
         {:ok, root} <- root(opts),
         {:ok, base} <- base_for(opts) do
      path = Path.join(root, run_id)
      branch = branch_for(run_id)

      cond do
        File.exists?(Path.join(path, ".git")) ->
          lock(path)
          {:ok, %{run: run_id, path: path, branch: branch, base: recorded_base(run_id, base)}}

        # A directory with no `.git` is not a worktree git knows about — it is
        # what a killed run leaves once its registration is pruned. Handing it
        # back as this run's tree would run every later `git` in it against
        # whatever repository encloses it.
        File.dir?(path) ->
          {:error,
           cannot_isolate(
             "#{path} is left over from an earlier run and is not a worktree; " <>
               "`noetic-harness workspace --prune` removes it if no run claims it"
           )}

        true ->
          create(run_id, path, branch, base)
      end
    end
  end

  # An id becomes a directory name and a branch name, and `prune/1` removes a
  # directory by it. One with a `/` in it nests inside another run's
  # directory, and pruning the outer one took the inner, live worktree with it
  # in review. Every id this repository generates already fits.
  @id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  defp valid_id(id) when is_binary(id) do
    if Regex.match?(@id, id) and not String.contains?(id, ".."),
      do: :ok,
      else: {:error, cannot_isolate("#{inspect(id)} is not a usable run id")}
  end

  defp valid_id(id), do: {:error, cannot_isolate("#{inspect(id)} is not a usable run id")}

  defp create(run_id, path, branch, base) do
    # `mkdir_p!` here raised out of `open/1` past its own `{:error, _}` spec
    # when the configured root was a file rather than a directory — and the
    # caller that has to turn this into a refusal cannot catch a raise it was
    # never told about.
    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        create_worktree(run_id, path, branch, base)

      {:error, reason} ->
        {:error, cannot_isolate("could not create #{Path.dirname(path)}: #{inspect(reason)}")}
    end
  end

  defp create_worktree(run_id, path, branch, base) do
    # `-c core.hooksPath=/dev/null`: see the moduledoc. A dispatched worktree is
    # not a checkout a person made.
    #
    # `--lock`, with this VM's pid as the reason: `Environments` and `Scoring`
    # open worktrees that never get a ledger entry, so "no ledger" alone would
    # let `prune/1` take one out from under a run in another session. A lock
    # whose pid is alive is in use; see `orphans/0`.
    case cmd(
           ["-c", "core.hooksPath=/dev/null", "worktree", "add", "--lock", "--reason"] ++
             [lock_reason(), "-b", branch, path, base]
         ) do
      {:ok, _} ->
        cmd(["update-ref", base_ref(run_id), base])
        {:ok, %{run: run_id, path: path, branch: branch, base: base}}

      {:error, output} ->
        {:error, cannot_isolate(String.trim(output))}
    end
  end

  # Every refusal in this repository names the rule and the file the rule lives
  # in, so that it can be argued with rather than worked around. Both ways of
  # failing to open a worktree say the same sentence, because the first version
  # had one that did and one that did not, and a test caught the difference.
  defp cannot_isolate(detail) do
    "could not isolate this run in its own worktree: #{detail}. " <>
      "A dispatched run that cannot be isolated does not run in somebody else's " <>
      "tree instead"
  end

  # The commit the run forked from, kept as a ref rather than recomputed.
  #
  # A re-opened worktree's base is not today's HEAD — the parent may have
  # committed in between — and it is not the branch tip either, because a
  # dispatched run is allowed to commit inside its own worktree. Both of those
  # were tried and both silently widen or narrow every later diff. Git already
  # is a place to keep a commit id, so the base is written to
  # `refs/harness/base/<run>` when the worktree is created and read back when
  # it is re-opened. The fallback is today's HEAD and is wrong by construction,
  # so it exists only for a worktree created before this ref did.
  defp recorded_base(run_id, fallback) do
    case cmd(["rev-parse", "--verify", "--quiet", base_ref(run_id)]) do
      {:ok, sha} -> String.trim(sha)
      {:error, _} -> fallback
    end
  end

  defp base_ref(run_id), do: "refs/harness/base/" <> run_id

  @doc """
  Repository-relative paths this workspace has changed since it was opened.

  Includes files the agent created, which a plain `git diff` does not — see the
  moduledoc on `--intent-to-add`. These are the paths the evaluator fence
  judges, so "could not answer" and "nothing changed" must not be conflated:
  the error is returned rather than an empty list.
  """
  @spec changed_paths(t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def changed_paths(%{path: path, base: base}) do
    # `--` and a pathspec that excludes what `Tree.prepare/1`
    # seeds. `.gitignore` says `/deps/`, which matches a directory and not the
    # symlink that is actually there, so without this the preparation itself
    # reads as a change the run made.
    with {:ok, git} <- tree_git(path),
         {:ok, _} <- cmd(git ++ ["add", "-A", "--intent-to-add", "--" | Tree.pathspec()]),
         {:ok, output} <-
           cmd(quote_path(git ++ ["diff", "--name-only", "--no-renames", base])) do
      {:ok, output |> String.split("\n", trim: true) |> Enum.sort()}
    else
      {:error, output} ->
        {:error, "git could not say what this run changed: #{String.trim(output)}"}
    end
  end

  @doc """
  The git arguments that address a run's worktree **without believing it**.

  A dispatched agent may write anything inside its worktree, and that includes
  the `.git` file that tells git where the repository is. Review of an earlier change
  had a sandboxed agent, using nothing but its own `write_file` action, point
  `.git` at a directory it had written with `core.fsmonitor = "<command>"` —
  and the next `git add` run here, on the host, ran the command.

  So the harness never lets the worktree say where its repository is. The admin
  directory is found from the *common* directory, which the agent cannot
  write, and confirmed by its `gitdir` file pointing back at this worktree;
  git is then given `--git-dir` and `--work-tree` explicitly, with fsmonitor
  and hooks off. A worktree whose admin directory cannot be found is refused.

  **The comparison is of physical paths, and the leaf is never resolved.**
  Git writes `gitdir` with every symlink resolved, so a worktree reached
  through one — any temporary directory on macOS, where `/var` is a link to
  `/private/var` — matched no admin directory, and everything that runs git
  in a run's tree refused. So the worktree directory and the
  directory part of `gitdir` are each resolved (`Noetic.Harness.Realpath`),
  and `.git` is joined to both afterwards. Resolving the whole of
  `path/.git` would follow the one entry the agent writes: a `.git` symlink
  to another worktree's `.git` would resolve to that worktree's spelling,
  match *its* admin directory, and hand the agent's tree another run's
  index and `HEAD`. The leaf is compared by name, so whatever the agent put
  there, this worktree is still found by the directory it is in.

  Only the worktree directory's *ancestors* may be links: the harness made
  them, and the agent cannot write them. A worktree directory that is itself
  a link is refused, so that a weaker sandbox in which an agent could swap
  its root for a link to another run's tree still gets nothing from it.
  """
  @spec tree_git(Path.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def tree_git(path) do
    with {:ok, common} <- common_dir_or_error(),
         :ok <- not_a_link(path),
         {:ok, physical} <- Realpath.resolve(path) do
      expected = Path.join(physical, ".git")
      admin_root = Path.join(common, "worktrees")

      found =
        case File.ls(admin_root) do
          {:ok, names} ->
            Enum.find_value(names, fn name ->
              admin = Path.join(admin_root, name)

              with {:ok, gitdir} <- File.read(Path.join(admin, "gitdir")),
                   gitdir = Path.absname(String.trim(gitdir), admin),
                   {:ok, dir} <- Realpath.resolve(Path.dirname(gitdir)),
                   true <- Path.join(dir, Path.basename(gitdir)) == expected do
                admin
              else
                _ -> nil
              end
            end)

          _ ->
            nil
        end

      case found do
        nil ->
          {:error,
           "no admin directory under #{admin_root} names #{path}, so git is not run in it — " <>
             "its own .git file is the one thing in a worktree that is never believed"}

        admin ->
          {:ok,
           [
             "--git-dir=" <> admin,
             "--work-tree=" <> path,
             "-c",
             "core.fsmonitor=false",
             "-c",
             "core.hooksPath=/dev/null"
           ]}
      end
    end
  end

  defp not_a_link(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, "the worktree #{path} is itself a symbolic link, so git is not run in it"}

      _ ->
        :ok
    end
  end

  defp common_dir_or_error do
    case common_dir() do
      {:ok, dir} -> {:ok, Path.expand(dir)}
      :error -> {:error, "this is not a git repository"}
    end
  end

  @doc """
  The diff a person reads before deciding.

  A design decision asks for a diff and not a summary of one, so this returns the
  patch itself.
  """
  @spec diff(t()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(%{path: path, base: base}) do
    with {:ok, git} <- tree_git(path),
         {:ok, _} <- cmd(git ++ ["add", "-A", "--intent-to-add"]),
         {:ok, output} <- cmd(quote_path(git ++ ["diff", "--no-renames", base])) do
      {:ok, output}
    else
      {:error, output} -> {:error, "git could not produce the diff: #{String.trim(output)}"}
    end
  end

  @doc """
  A short statement of what the run did, for the ledger.
  """
  @spec summary(t()) :: String.t()
  def summary(%{path: path, branch: branch, base: base}) do
    stat =
      case with({:ok, git} <- tree_git(path), do: cmd(git ++ ["diff", "--shortstat", base])) do
        {:ok, output} -> String.trim(output)
        {:error, _} -> "diffstat unavailable"
      end

    "worktree #{path} on branch #{branch}: #{stat}"
  end

  @doc """
  Take the worktree away.

  **Refuses to discard by default.** `.agents/policies/failure.md` says the
  evidence is not reverted along with the code, and a design decision applies that to
  a rejected dispatch: a run nobody can diagnose taught nobody anything. So
  `close/2` keeps the tree and the branch unless the caller says
  `discard: true`, which is what a caller says when it has already captured the
  diff.
  """
  @spec close(t(), keyword()) :: :ok | {:error, String.t()}
  def close(workspace, opts \\ [])

  def close(%{run: run_id, path: path, branch: branch}, opts) do
    if Keyword.get(opts, :discard, false) do
      with :ok <- remove_worktree(path),
           {:ok, _} <- cmd(["branch", "-D", branch]) do
        cmd(["update-ref", "-d", base_ref(run_id)])
        :ok
      else
        {:error, output} -> {:error, String.trim(output)}
      end
    else
      :ok
    end
  end

  @doc """
  Every run worktree that currently exists.

  A list that keeps growing is the thing to watch: each entry is a dispatched
  run whose diff nobody has looked at yet.
  """
  @spec list() :: {:ok, [String.t()]} | {:error, String.t()}
  def list do
    with {:ok, root} <- root() do
      case File.ls(root) do
        {:ok, entries} ->
          {:ok, entries |> Enum.filter(&File.dir?(Path.join(root, &1))) |> Enum.sort()}

        {:error, :enoent} ->
          {:ok, []}

        {:error, reason} ->
          {:error, "could not read #{root}: #{inspect(reason)}"}
      end
    end
  end

  # ---- leftovers -----------------------------------------------------------

  @doc """
  Run ids that something of the dispatcher's still exists for — a
  `harness/run/*` branch, or a directory under `root/0` — that nothing is
  using, and that have no ledger entry anywhere.

  A dispatched run's branch outlives the VM that made it, and a
  run killed before its cleanup leaves the branch behind. The next run to pick
  the same name is refused by `open/2` — correctly, a design decision — and the
  failure reads like a regression in whatever that run was testing. Four had
  accumulated here by 2026-09-22, the oldest a day old.

  **The directory is the other half, and was found by running the first.**
  With the branches gone, `.git/noetic-harness/` still held 250 MB for a run
  whose branch had been deleted by hand and whose worktree registration had
  been pruned: a directory with no `.git` in it, which nothing listed as a
  worktree and nothing would ever remove. A sweep over branches alone reported
  "none" beside it.

  **What makes something an orphan is narrower than it looks, on purpose.**
  A design decision says a dispatched run's diff is evidence a person reviews before
  anything lands, so a branch may not be removed merely because its run
  closed. An orphan is all of:

  - **no ledger entry** in `.agents/runs/` of **any** worktree of this
    repository — the branches are shared by all of them, and a run dispatched
    from the main checkout has its branch visible here and its file there;
  - **none in the history of any ref** — a run file that was committed and
    later removed is still a run somebody may need to read;
  - **not in use.** `open/2` locks every worktree with its VM's pid, because
    `Environments` and `Scoring` open worktrees that never get a ledger entry
    and a review deleted one from under a run in another session. A lock whose
    pid is alive, or whose reason is not ours to parse, means in use. A bare
    directory cannot be locked, so it must also be an hour old.

  **Any failure to answer is a failure, not a "no".** `git log --all` fails on
  one ref to a missing object, and counting that as "not in history" made a
  committed run an orphan in review. Every such error returns `{:error, _}`
  and nothing is removed.
  """
  @spec orphans() :: {:ok, [String.t()]} | {:error, String.t()}
  def orphans do
    with {:ok, listed} <-
           cmd(["branch", "--list", "--format=%(refname:short)", branch_for("*")]),
         {:ok, dirs} <- list(),
         {:ok, trees} <- worktrees(),
         {:ok, root} <- root() do
      branches =
        listed
        |> String.split("\n", trim: true)
        |> Enum.map(&String.replace_prefix(&1, branch_for(""), ""))

      (branches ++ dirs)
      |> Enum.uniq()
      |> Enum.filter(&Regex.match?(@id, &1))
      |> Enum.sort()
      |> Enum.reject(&in_use?(&1, trees, root))
      |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
        case ledgered?(id, trees) do
          {:ok, true} -> {:cont, {:ok, acc}}
          {:ok, false} -> {:cont, {:ok, [id | acc]}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
      |> case do
        {:ok, ids} -> {:ok, Enum.reverse(ids)}
        error -> error
      end
    else
      {:error, output} ->
        {:error, "could not list what the dispatcher left: #{String.trim(output)}"}
    end
  end

  @bare_min_age_ms 3_600_000

  defp in_use?(id, trees, root) do
    case Enum.find(trees, &(&1.branch == branch_for(id))) do
      %{locked: nil} -> false
      %{locked: reason} -> lock_alive?(reason)
      nil -> young_bare_dir?(Path.join(root, id))
    end
  end

  defp young_bare_dir?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{type: :directory, mtime: mtime}} ->
        System.os_time(:second) - mtime < div(@bare_min_age_ms, 1000)

      _ ->
        false
    end
  end

  defp lock_reason, do: "noetic-harness pid:#{System.pid()}"

  # Ours, with a pid that is gone: not in use. Anything else — a live pid, a
  # lock a person took with their own reason — is in use.
  defp lock_alive?(reason) do
    case Regex.run(~r/\Anoetic-harness pid:(\d+)\z/, reason) do
      [_, pid] -> pid_alive?(pid)
      _ -> true
    end
  end

  defp pid_alive?(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> true
      {output, _} -> not String.contains?(output, "No such process")
    end
  rescue
    _ -> true
  end

  defp lock(path) do
    cmd(["worktree", "unlock", path])
    cmd(["worktree", "lock", "--reason", lock_reason(), path])
  end

  defp ledgered?(id, trees) do
    file = Path.join([".agents", "runs", id <> ".json"])

    if Enum.any?(trees, &File.exists?(Path.join(&1.path, file))) do
      {:ok, true}
    else
      case cmd(["log", "--all", "--format=%h", "-1", "--", file]) do
        {:ok, out} ->
          {:ok, String.trim(out) != ""}

        {:error, output} ->
          {:error,
           "could not read the history for #{file}, so cannot say no run claims it: " <>
             String.trim(output)}
      end
    end
  end

  # `git worktree list --porcelain`, one map per block. The branch is what a
  # worktree is matched by, not its path: git prints the resolved path, and a
  # root reached through a symlink compared unequal and fell through to
  # `rm_rf` on a registered worktree in review.
  defp worktrees do
    with {:ok, out} <- cmd(["worktree", "list", "--porcelain"]) do
      {:ok,
       out
       |> String.split(~r/\n\s*\n/, trim: true)
       |> Enum.map(fn block ->
         lines = String.split(block, "\n", trim: true)

         %{
           path: field(lines, "worktree"),
           branch:
             lines
             |> field("branch")
             |> then(&(&1 && String.replace_prefix(&1, "refs/heads/", ""))),
           locked:
             Enum.find_value(lines, fn
               "locked" -> ""
               "locked " <> reason -> reason
               _ -> nil
             end)
         }
       end)}
    end
  end

  defp field(lines, key) do
    Enum.find_value(
      lines,
      &(String.starts_with?(&1, key <> " ") && String.replace_prefix(&1, key <> " ", ""))
    )
  end

  @doc """
  Remove the orphans among `ids`: the worktree or the bare directory, the
  branch, and the base ref — whichever of them exist. Returns one result per
  id, so a partial failure is reported rather than summarised.

  **It asks `orphans/0` again rather than trusting its caller.** An id that
  has a ledger entry anywhere, or is in use, is refused here and not in the
  task that called it, so no caller — a script, a future `--all`, a test with
  a typo — can delete a dispatched run's diff by naming it.

  A worktree git knows about is removed by `git worktree remove`. A directory
  it does not know is removed from disk, and **only under the repository's own
  `.git/noetic-harness/`**: with `NOETIC_HARNESS_WORKTREE_ROOT` pointing
  somewhere else, a bare directory there is reported and left alone.
  """
  @spec prune([String.t()]) :: [{String.t(), :ok | {:error, String.t()}}]
  def prune(ids) do
    cmd(["worktree", "prune"])

    with {:ok, orphans} <- orphans(),
         {:ok, root} <- root(),
         {:ok, trees} <- worktrees() do
      for id <- ids do
        if id in orphans,
          do: {id, discard_orphan(id, root, trees)},
          else:
            {id,
             {:error,
              "#{branch_for(id)} is not an orphan: it has a ledger entry, is in use, " <>
                "or has nothing left"}}
      end
    else
      {:error, message} -> for id <- ids, do: {id, {:error, message}}
    end
  end

  defp discard_orphan(id, root, trees) do
    with :ok <- remove_tree(id, root, trees),
         :ok <- remove_branch(id) do
      cmd(["update-ref", "-d", base_ref(id)])
      :ok
    end
  end

  defp remove_tree(id, root, trees) do
    path = Path.join(root, id)

    case Enum.find(trees, &(&1.branch == branch_for(id))) do
      %{path: registered} ->
        remove_worktree(registered)

      nil ->
        cond do
          not File.dir?(path) ->
            :ok

          File.exists?(Path.join(path, ".git")) ->
            {:error, "#{path} has a .git but no branch git lists; left for a person"}

          not own_root?(root) ->
            {:error, "#{path} is outside .git/noetic-harness; left for a person"}

          true ->
            rm_rf(path)
        end
    end
  end

  # Twice `--force`: once for the changes, once for the lock `open/2` took.
  #
  # **And `repair` when git will not.** An earlier change: a tree whose `.git` file no
  # longer points home is refused outright — "validation failed, cannot remove
  # working tree: '…/.git' is not a .git file" — however many `--force`s it is
  # given. `harness_adapter_test.exs` rewrites that file on purpose, to prove
  # the host never believes it, so its `on_exit` close failed on every run and
  # left one locked `jido-fsmonitor-*` worktree behind per suite; `prune/1`
  # then failed on the same line, and the trees outlived every session start.
  # `worktree repair` rewrites the file from git's own admin entry, which is
  # the record this module registered, not whatever the tree now claims. It
  # exits 1 on the file it has just fixed, so its answer is not read; the
  # second `remove` is, and a failure reports the first one's reason.
  defp remove_worktree(path) do
    remove = fn -> cmd(["worktree", "remove", "--force", "--force", path]) end

    case remove.() do
      {:ok, _} ->
        :ok

      {:error, first} ->
        cmd(["worktree", "repair", path])

        case remove.() do
          {:ok, _} -> :ok
          {:error, _} -> {:error, String.trim(first)}
        end
    end
  end

  defp own_root?(root) do
    case common_dir() do
      {:ok, dir} -> Path.expand(root) == Path.expand(Path.join(dir, "noetic-harness"))
      :error -> false
    end
  end

  defp rm_rf(path) do
    case File.rm_rf(path) do
      {:ok, _} -> :ok
      {:error, reason, file} -> {:error, "could not remove #{file}: #{inspect(reason)}"}
    end
  end

  defp remove_branch(id) do
    case cmd(["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch_for(id)]) do
      {:ok, _} ->
        case cmd(["branch", "-D", branch_for(id)]) do
          {:ok, _} -> :ok
          {:error, output} -> {:error, String.trim(output)}
        end

      {:error, _} ->
        :ok
    end
  end

  # The *full* sha, not `Git.head/0`'s short one. Both name the same commit and
  # git accepts either, but `rev-parse` reads the recorded ref back in full, so
  # a short base makes a re-opened workspace compare unequal to the one it is —
  # which is how this was found.
  # `:base` opens the worktree at a ref other than HEAD. Scoring a candidate
  # needs two trees from the same repository at two different commits — the
  # candidate's and its baseline's — and comparing them is the whole point, so
  # this is not an option a caller should have to reimplement.
  # It is resolved to a full sha here, because the recorded base is what every
  # later diff is taken against and a branch name would move under it.
  defp base_for(opts) do
    case Keyword.get(opts, :base) do
      nil -> head()
      ref -> resolve(ref)
    end
  end

  @doc """
  Whether git can resolve this ref to a commit in this repository.

  `Scoring` asks before spending anything: a candidate whose `ref` or
  `baseline` is not here cannot be checked out, and finding that out after
  sixteen dispatches is finding it out too late.
  """
  @spec resolvable?(String.t()) :: boolean()
  def resolvable?(ref) when is_binary(ref), do: match?({:ok, _}, resolve(ref))
  def resolvable?(_), do: false

  defp head, do: resolve("HEAD")

  defp resolve(ref) do
    case cmd(["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]) do
      {:ok, sha} ->
        {:ok, String.trim(sha)}

      {:error, _} ->
        {:error,
         "git could not resolve #{inspect(ref)} to a commit, so there is no base to isolate from"}
    end
  end

  defp common_dir do
    case cmd(["rev-parse", "--git-common-dir"]) do
      {:ok, dir} ->
        dir = String.trim(dir)

        {:ok,
         if(Path.type(dir) == :absolute, do: dir, else: Path.join(Noetic.Harness.root(), dir))}

      {:error, _} ->
        :error
    end
  end

  # `core.quotePath=false`, and it is a fence defect rather than a nicety.
  #
  # git quotes and octal-escapes a path with a byte outside ASCII —
  # `".agents/policies/evaluat\303\266rs.json"`, with the quotes — and
  # `Noetic.Harness.Fence` matches globs against the string it is handed. An
  # independent review wrote both spellings into a worktree and watched the
  # ASCII sibling be refused while the other was not, in a directory the fence
  # protects and which `Environments` loads with `Path.wildcard/1`. So the
  # unquoted spelling is what the fence is asked about.
  defp quote_path(args), do: ["-c", "core.quotePath=false" | args]

  defp cmd(args) do
    case System.cmd("git", args, cd: Noetic.Harness.root(), stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
