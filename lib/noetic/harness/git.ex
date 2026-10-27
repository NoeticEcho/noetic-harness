defmodule Noetic.Harness.Git do
  @moduledoc """
  The read-only slice of git the harness needs.

  Deliberately read-only. The harness *describes* work; it does not commit,
  branch, merge or push. Those are T3 actions taken by a role under a workflow
  step, with a human able to see them happen — not side effects of running a
  context builder.

  Every function returns `:error` rather than raising when git is absent or the
  directory is not a repository, because the harness must be usable inside a
  fixture tree that is not one (the tests rely on exactly that).

  ## What reaches git, and what comes back

  - **A value is never an option.** Anything from a caller or a file sits
    behind `--end-of-options`, the `-e` it belongs to, or a `--`.
  - **Only stdout is parsed.** `run/1` used `stderr_to_stdout: true`, so a
    warning — `refname '433009c' is ambiguous` — came back as a changed path,
    and the lane selected gates for a file that does not exist. stderr is now
    discarded, through `sh -c 'exec git "$@" 2>/dev/null'` with the arguments
    as positional parameters, so the shell parses none of them.
  - **Nothing in the repository's config runs.** The harness runs git in
    whatever tree `Noetic.Harness.root/0` found, which can be an agent's
    worktree, and `extensions.worktreeConfig` honours a `config.worktree`
    there. So every call passes `core.fsmonitor=false`, and every `diff`
    passes `--no-ext-diff --no-textconv`: `diff.external` and a textconv
    driver are each a command a config file names.
  """

  @doc "Paths changed in the working tree, staged and unstaged, relative to the root."
  @spec changed_paths() :: {:ok, [String.t()]} | :error
  def changed_paths do
    with {:ok, output} <- run(["status", "--porcelain=v1", "--no-renames"]) do
      paths =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.slice(&1, 3..-1//1))
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.sort()

      {:ok, paths}
    end
  end

  @doc """
  Everything that differs from `base`: committed since it, modified and not
  committed, and new and not yet tracked.

  What a run changed, as opposed to what happens to be uncommitted right now
  (`changed_paths/0`). The difference is not academic: `Run.finish/2` used to
  take its paths from `changed_paths/0`, so the ordinary order of work — do it,
  commit it, then `--finish` — handed the lane an empty change set, and the lane
  selected gates for nothing. A second `--finish` on the same tree ran four
  gates where the first had run nine. Verifying *less* after committing is the
  exact inversion of what the step is for.

  `git diff --name-only <base>` compares `base` with the working tree, so it
  covers both the committed and the uncommitted halves of tracked changes; the
  untracked half comes from `status`, because `diff` never sees a file git has
  not been told about.

  `base` comes out of a run file, which is committed and editable, so it is
  held to what `Run` writes there — a commit id — before git sees it, and
  `--end-of-options` is passed anyway. `git diff` reads options
  anywhere before a `--`, and `--output=<path>` is one of them: a base of
  `--output=/some/file` was a file write. The `--` after it matters as much:
  without one, git reads a hex base that is also a file name as that path, and
  a run file edited to name one handed the lane a single file instead of the
  run's change.
  """
  @spec changed_since(String.t()) :: {:ok, [String.t()]} | :error
  def changed_since(base) when is_binary(base) and base != "" do
    with true <- commit_id?(base),
         {:ok, diffed} <-
           run(["diff", "--name-only", "--no-renames", "--end-of-options", base, "--"]),
         {:ok, status} <- run(["status", "--porcelain=v1", "--no-renames"]) do
      untracked =
        status
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "?? "))
        |> Enum.map(&String.slice(&1, 3..-1//1))

      paths =
        (String.split(diffed, "\n", trim: true) ++ untracked)
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, paths}
    else
      _ -> :error
    end
  end

  def changed_since(_base), do: :error

  defp commit_id?(base), do: base =~ ~r/\A[0-9a-f]{7,64}\z/

  @doc """
  Paths committed between two commits: `git diff --name-only from to`, and
  nothing from the working tree.

  What a WF-021 lane runs over, from the merge-base to HEAD. Unlike
  `changed_since/1` it leaves out the uncommitted and the untracked, because
  that lane's verdict is recorded against a head and `Run.committed_tree/2`
  refuses a finish with either. Read in `-z` form, so a path git would
  C-quote — a Cyrillic file name, say — arrives as itself.

  `from` must be a commit id, as `changed_since/1`'s base must; `to` may also
  be `HEAD`. Both sit behind `--end-of-options`.
  """
  @spec committed_between(String.t(), String.t()) :: {:ok, [String.t()]} | :error
  def committed_between(from, to) when is_binary(from) and is_binary(to) do
    with true <- commit_id?(from),
         true <- to == "HEAD" or commit_id?(to),
         {:ok, output} <-
           run([
             "diff",
             "--no-ext-diff",
             "--no-textconv",
             "--name-only",
             "-z",
             "--no-renames",
             "--end-of-options",
             from,
             to,
             "--"
           ]) do
      {:ok, output |> String.split(<<0>>, trim: true) |> Enum.uniq() |> Enum.sort()}
    else
      _ -> :error
    end
  end

  def committed_between(_from, _to), do: :error

  @doc """
  `git merge-base a b`, in full, or `:error` — for a ref that does not
  resolve, as much as for git being absent.

  The refs come from a workflow's `lane_paths` (`origin/develop`), and a
  workflow file is committed and editable, so each is held to the shape of a
  ref name — no leading `-`, no `..`, no spaces — and still passed after
  `--end-of-options`.
  """
  @spec merge_base(String.t(), String.t()) :: {:ok, String.t()} | :error
  def merge_base(a, b) when is_binary(a) and is_binary(b) do
    with true <- ref_name?(a) and ref_name?(b),
         {:ok, output} <- run(["merge-base", "--end-of-options", a, b]),
         sha = String.trim(output),
         true <- sha =~ ~r/\A[0-9a-f]{40,64}\z/ do
      {:ok, sha}
    else
      _ -> :error
    end
  end

  def merge_base(_a, _b), do: :error

  defp ref_name?(ref),
    do: ref =~ ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/ and not String.contains?(ref, "..")

  @doc """
  Every path in the working tree that differs from HEAD: staged, unstaged and
  untracked, each untracked file named rather than its directory.

  `Run.committed_tree/2` asks this before a WF-021 finish, and a new file
  nobody added is the commonest way for a tree to differ from its head, so
  untracked files are in it; ignored ones are not, since git does not list
  them. `-z` for the reason `tree_fingerprint/0` gives: porcelain v1 quotes
  any path holding a byte above 0x7F, and a quoted path does not match the
  prefix it is compared with.
  """
  @spec uncommitted() :: {:ok, [String.t()]} | :error
  def uncommitted do
    with {:ok, status} <-
           run(["status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all"]) do
      paths =
        status
        |> String.split(<<0>>, trim: true)
        |> Enum.filter(&(byte_size(&1) > 3))
        |> Enum.map(&binary_part(&1, 3, byte_size(&1) - 3))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, paths}
    end
  end

  @doc "The current commit, in full — what a run records as the place it started."
  @spec head_sha() :: {:ok, String.t()} | :error
  def head_sha do
    with {:ok, output} <- run(["rev-parse", "HEAD"]), do: {:ok, String.trim(output)}
  end

  @doc "`git diff --stat`, for the context bundle."
  @spec diff_stat() :: {:ok, String.t()} | :error
  def diff_stat do
    with {:ok, output} <- run(["diff", "--no-ext-diff", "--no-textconv", "--stat", "HEAD"]),
         do: {:ok, String.trim(output)}
  end

  @doc "The current branch name."
  @spec branch() :: {:ok, String.t()} | :error
  def branch do
    with {:ok, output} <- run(["rev-parse", "--abbrev-ref", "HEAD"]),
         do: {:ok, String.trim(output)}
  end

  @doc "The current commit, short."
  @spec head() :: {:ok, String.t()} | :error
  def head do
    with {:ok, output} <- run(["rev-parse", "--short", "HEAD"]), do: {:ok, String.trim(output)}
  end

  @doc """
  A fingerprint of the working tree: HEAD, the porcelain status and the full
  diff against HEAD, hashed.

  It exists for one rule in `.agents/policies/failure.md`: "an attempt only
  counts as an attempt if it changed something. Re-running an identical command
  against an unchanged tree is not a retry, it is a stall." Deciding that needs
  a fact about the product at the moment of the attempt, and nothing was recording
  one.

  Three inputs, and the third was learned by watching the first version fail.
  The diff matters because editing a file back and forth leaves the status
  identical and the tree genuinely unchanged, which is the case the rule is
  about. **Untracked files have to be hashed by content**: `git status` lists
  them by name and `git diff HEAD` cannot see them at all, so an agent writing a
  brand-new module — the commonest shape of work there is — produced an
  identical fingerprint on every attempt and would have been declared stalled
  while making steady progress.

  The untracked list is read in git's `-z` form. Porcelain v1 C-quotes any path
  holding a control character, a quote, a backslash or a byte above 0x7F, and
  the first version handed the quoted literal to `File.stat`, which answered
  `:enoent` — so every edit to a file with a Cyrillic or accented name was
  invisible, in a repository whose content is partly Cyrillic. `File.lstat` for
  the same reason in reverse: `File.stat` follows symlinks, so an untracked link
  made this an arbitrary-file-read of anything under 4 MiB on the machine.

  `.agents/runs/` is excluded, and that is not tidiness either. The ledger file
  is written by the very act being measured: recording an attempt changes the
  run's own JSON, so every fingerprint differed from the last and a stall was
  undetectable. The onlooker has to stay out of the observation. Files git
  ignores are invisible for the same structural reason and are not excluded
  deliberately — `--untracked-files=all` does not list them — so a step whose
  only product lands in `doc/` or `_build/` moves nothing here.

  **The fingerprint is taken when a step is *recorded*, not when it was
  attempted.** An agent that batch-records a session's work from notes gets one
  tree for several entries; the stall check's precision rests on a recording
  habit nothing enforces, and the evidence half of the conjunction is what keeps
  that from being a false stall.

  `:error` where git cannot answer, and the caller must treat that as
  *unknown*, never as *equal*: a fingerprint that silently compares equal turns
  every attempt into a stall.
  """
  @exclude_runs ":(exclude).agents/runs"

  @spec tree_fingerprint() :: {:ok, String.t()} | :error
  def tree_fingerprint do
    with {:ok, head} <- run(["rev-parse", "HEAD"]),
         {:ok, status} <-
           run([
             "status",
             "--porcelain=v1",
             "-z",
             "--no-renames",
             "--untracked-files=all",
             "--",
             ".",
             @exclude_runs
           ]),
         {:ok, diff} <-
           run(["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", ".", @exclude_runs]) do
      digest =
        :crypto.hash_init(:sha256)
        |> :crypto.hash_update([head, "\0", status, "\0", diff, "\0"])
        |> untracked_digest(status)
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      {:ok, digest}
    end
  end

  # Content for a small file, size and mtime for a large one. The cap is not
  # tidiness: an untracked multi-gigabyte export in the tree would otherwise be
  # read in full on every recorded step.
  #
  # The files are fed to the hash one at a time, so peak memory is one file,
  # not all of them. It used to build one iolist of every untracked file's
  # contents and hash it in a single call: 500 untracked 4 MiB files was 2 GB
  # resident on every `run --step`. The digest is the same bytes in
  # the same order, so fingerprints recorded before the change still compare.
  @untracked_content_cap 4 * 1024 * 1024

  # `-z` records are NUL-separated and never quoted, so a path with a newline,
  # a quote or a non-ASCII byte arrives intact.
  defp untracked_digest(hash, status) do
    status
    |> String.split(<<0>>, trim: true)
    |> Enum.filter(&String.starts_with?(&1, "?? "))
    |> Enum.map(&binary_part(&1, 3, byte_size(&1) - 3))
    |> Enum.sort()
    |> Enum.reduce(hash, fn path, acc ->
      :crypto.hash_update(acc, [path, "\0", untracked_bytes(path)])
    end)
  end

  defp untracked_bytes(path) do
    full = Path.join(Noetic.Harness.root(), path)

    # `lstat`, not `stat`: a symlink is fingerprinted as a symlink rather than
    # followed out of the repository and read.
    case File.lstat(full) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @untracked_content_cap ->
        case File.read(full) do
          {:ok, content} -> content
          {:error, reason} -> "unreadable:#{reason}"
        end

      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(full) do
          {:ok, target} -> "symlink:#{target}"
          {:error, reason} -> "symlink:#{reason}"
        end

      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        "#{size}:#{inspect(mtime)}"

      {:error, _} ->
        "gone"
    end
  end

  @doc """
  The files matching `glob` that git would show: tracked, or untracked and
  not ignored. `:error` unless the root is the top of a work tree — a fixture
  directory inside this repository is ignored by it, and would match nothing
  rather than what is on its disk.

  `glob` is `Path.wildcard/1`'s dialect for the forms the context builder
  uses — `**/` for any depth, `*` within one segment — passed as a `:(glob)`
  pathspec after `--`.
  """
  @spec files(String.t()) :: {:ok, [String.t()]} | :error
  def files(glob) when is_binary(glob) do
    with {:ok, top} <- run(["rev-parse", "--show-toplevel"]),
         true <- same_dir?(String.trim(top), Noetic.Harness.root()),
         {:ok, output} <-
           run([
             "ls-files",
             "-z",
             "--cached",
             "--others",
             "--exclude-standard",
             "--",
             ":(glob)" <> glob
           ]) do
      paths = output |> String.split(<<0>>, trim: true) |> Enum.uniq() |> Enum.sort()
      {:ok, paths}
    else
      _ -> :error
    end
  end

  defp same_dir?(a, b) do
    case {File.stat(a), File.stat(b)} do
      {{:ok, %{inode: i, major_device: d}}, {:ok, %{inode: i, major_device: d}}} -> true
      _ -> false
    end
  end

  @doc "Recent commits touching the given paths, one line each."
  @spec recent_commits([String.t()], pos_integer()) :: {:ok, [String.t()]} | :error
  def recent_commits(paths, limit \\ 8) do
    args =
      ["log", "--oneline", "-n", to_string(limit)] ++
        if(paths == [], do: [], else: ["--" | paths])

    with {:ok, output} <- run(args), do: {:ok, String.split(output, "\n", trim: true)}
  end

  @doc """
  Where the given module names are referenced.

  `git grep` rather than a filesystem walk, so it respects `.gitignore` and does
  not report the ten thousand files under `deps/` and `_build/`.
  """
  @spec grep([String.t()], pos_integer()) :: {:ok, [String.t()]} | :error
  def grep([], _limit), do: {:ok, []}

  def grep(needles, limit) do
    # Every needle is the value of its own `-e`, so one beginning with `-` is a
    # pattern and never an option, and the `--` after them says there are no
    # revisions. The first version built `-e -- first -e second`: it searched
    # for the literal `--`, and handed the first needle to git as a revision.
    # `-F`: a module name is a string, not a pattern — `Foo.Bar` as a regex
    # also matches `FooXBar`.
    args = ["grep", "-n", "-F"] ++ Enum.flat_map(needles, &["-e", &1]) ++ ["--"]

    case exec(args) do
      {output, 0} -> {:ok, output |> String.split("\n", trim: true) |> Enum.take(limit)}
      # `git grep` exits 1 when it matches nothing, which is a result. Anything
      # else is git failing, and says so rather than reading as "no callers".
      {_, 1} -> {:ok, []}
      _ -> :error
    end
  end

  defp run(args) do
    case exec(args) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  end

  defp exec(args) do
    System.cmd(
      "sh",
      ["-c", ~s(exec git "$@" 2>/dev/null), "git", "-c", "core.fsmonitor=false" | args],
      cd: Noetic.Harness.root()
    )
  rescue
    _ -> {"", :enoent}
  end
end
