defmodule Noetic.Harness.Tree do
  @moduledoc """
  A working tree that is not the caller's, made ready to run `mix test` in.

  `Noetic.Harness.Workspace` produces a git worktree; this makes one *usable*.
  It was extracted from `Noetic.Harness.Environments`, where it grew, when a
  second caller needed exactly the same thing: scoring a candidate against the
  environment suite means standing up two trees at two commits and running the
  same verifiers in both. Two copies of this would have drifted,
  and the half that drifted would have been the half that decides a number.

  ## What a fresh worktree is missing, and what is done about it

  **`deps/` is symlinked.** 66MB of source that a verification only reads is
  not worth copying. A dependency built by `elixir_make` compiles in its own
  *source* directory (`lazy_html` here, 120KB), so a tree forced to rebuild one
  would write into the caller's shared `deps/`. Where `bwrap` works,
  it cannot: `run_tests/4` binds the symlink's target read-only for every
  verification as well as every scoring attempt, the write fails with `EROFS`,
  the build fails, and `environmental?/1` reads that as an environment that
  could not be asked rather than a verdict. `TreeSharedDepsTest` drives that
  path with a stub `mix`, and fails with the bind removed. Where `bwrap` is
  absent the write still lands, and the test says so rather than passing.

  **`_build/` is seeded with the dependencies' artifacts, and only those.**
  A cold umbrella build is the entire cost: measured end to end, an
  environment verification took **7m06s** against an empty `_build` and
  **1m35s** with this. `_build/test/lib/<dep>` is written once by
  `deps.compile` and then left alone, while `_build/test/lib/noetic_harness*` is what
  a concurrent session recompiles all day — and copying a directory somebody
  is writing is how you get a half-written `.beam` with a fresh mtime that
  `mix` then trusts. Recompiling the umbrella's own apps is paid rather than
  risked.

  `cp -a` rather than `File.cp_r/2`, because `mix` decides staleness by mtime
  and `cp_r` does not preserve it: a copy without `-a` recompiles everything
  it was meant to save. A copy that fails is not a silent weakening — the tree
  then compiles from cold and produces the same answer, more slowly.

  ## A solver's tree has a history of its own

  A worktree shares its repository's objects, so a scoring solver could read
  the fix it was scored on with `git show`. `sever/2` points the tree's
  `.git` at a repository holding one commit, the task, for as long as the
  solver works, and `rejoin/1` points it back.

  That was not enough while the tree lived under the host's `.git/`: git
  searches upward, so `git -C .. show <fix>` found the host from the tree's
  parent. A scoring tree is now opened under `solver_root/0`, a private
  directory no repository encloses, and `sever/2` refuses a tree whose parent
  is inside one. `without_git_env/1` keeps the solver's own process from
  inheriting a variable that names a repository or a git configuration. What
  all three close and what they do not are in `sever/2`'s doc.

  ## A broken build is not a verdict

  `environmental?/1` is the distinction an independent review had to point
  out. `mix test` exits non-zero when a test detects something *and* when
  `mix` never reached the tests at all, and the second became reachable
  precisely because seeding made the first pass cheap: a fresh worktree can
  fail to compile a dependency. Anything that reads an exit status as a
  finding has to ask this first.

  A `CompileError` in the app under test is deliberately **not** environmental.
  Reverse-applying a commit that created a module deletes it and the app stops
  compiling; that is a real task, recorded as `discrimination: "compile"`. The
  line this draws is between the tree under test failing and the machinery
  around it failing.
  """

  alias Noetic.Harness.Workspace

  @environmental ~r/^\*\* \(Mix\)|[Cc]ould not compile dependency/m

  # What could point a git command at an object store other than the one it
  # names, or hand it configuration from outside. Unset for every command on
  # the solver's repository (`sever/2`).
  @clean_git_env for var <-
                       ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
                          GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
                          GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG),
                     do: {var, nil}

  @doc """
  Give a fresh worktree the `deps` and `_build` it needs to run tests.

  Best-effort: everything here is an optimisation, and a tree that did not get
  it produces the same answers from a cold build.
  """
  @spec prepare(Workspace.t() | String.t()) :: :ok
  def prepare(%{path: path}), do: prepare(path)

  def prepare(path) when is_binary(path) do
    link_deps(path)
    seed_dependencies(path)
    :ok
  end

  @doc """
  What `git add -A --intent-to-add` must not look at, as pathspecs.

  An earlier change, and this is the half nobody had noticed. `.gitignore` says
  `/deps/` with a trailing slash, which matches a **directory** — and
  `prepare/1` puts a *symlink* there. Git reports it `?? deps`: untracked, and
  not ignored. So `add -A --intent-to-add` staged it, `diff --name-only base`
  reported it as a path the solver had changed, and `reset --hard` deleted it.

  Every confinement was therefore destroying the very symlink that makes a
  verification 1m35s instead of 7m06s, and handing the fence a phantom change
  the solver never made. Demonstrated against this repository's own
  `.gitignore` rather than a fixture's.

  Excluding it by pathspec is preferred over widening `.gitignore` to `/deps`:
  the symlink exists only in a prepared worktree, so the rule belongs to the
  preparation and not to the project.

  Only `deps` is named. `_build` is a real directory `prepare/1` makes with
  `mkdir_p`, so `.gitignore` already matches it — and naming it here is worse
  than useless: an explicit `:(exclude)_build` makes git treat it as a path the
  caller mentioned, and `git add` then refuses the whole command with "The
  following paths are ignored by one of your .gitignore files". Three forms
  were tried against a real repository before this one.
  """
  @spec pathspec() :: [String.t()]
  def pathspec, do: [".", ":!deps"]

  @doc """
  The paths `prepare/1` puts in a worktree, as `git clean -e` patterns.

  Computed from the **source** tree, never from the worktree being cleaned.
  A list taken from the worktree would protect whatever the solver created
  there, which is the opposite of the point.
  """
  @spec seeded() :: [String.t()]
  def seeded do
    root = Noetic.Harness.root()

    ["/deps"] ++
      for dep <- seeded_deps(root) do
        "/" <> Path.join(build_lib(), dep)
      end
  end

  # The project's layout (`Noetic.Harness.Project.layout/0`) says
  # where the build directory and the apps are. Mix's compiled dependencies
  # for the test environment are its `test/lib`: `_build/test/lib` here. A
  # project with no layout has nothing to seed from.
  defp build_lib do
    case Noetic.Harness.Project.layout() do
      nil -> nil
      layout -> Path.join([layout.build, "test", "lib"])
    end
  end

  defp seeded_deps(root) do
    case build_lib() do
      nil ->
        []

      lib ->
        own = own_apps(root)

        case File.ls(Path.join(root, lib)) do
          {:ok, entries} -> Enum.reject(entries, &(&1 in own))
          {:error, _} -> []
        end
    end
  end

  # What `git clean` is about to remove, asked before it removes it. `-n` is
  # the dry run and prints one "Would remove <path>" per entry, collapsing a
  # whole directory into one line — which is the right granularity for a
  # report and the wrong one for a diff, so this is capped rather than
  # exhaustive.
  defp strays(tree, excludes) do
    case tree_run(tree, ["clean", "-ndx"] ++ excludes) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.replace_prefix(&1, "Would remove ", ""))
        |> Enum.take(50)

      _ ->
        []
    end
  end

  # An exclusion protects a directory, so a file planted inside a seeded one
  # would survive. Each is therefore compared against its source by listing:
  # same relative paths, same sizes. A directory that diverges is removed and
  # re-copied — one dependency, not the ninety-three that a blanket re-seed
  # would cost 32 seconds to redo.
  defp reseed_divergent(tree) do
    root = Noetic.Harness.root()
    source = Path.join(root, build_lib() || "")
    target = Path.join(tree, build_lib() || "")

    for dep <- seeded_deps(root),
        listing(Path.join(source, dep)) != listing(Path.join(target, dep)) do
      File.rm_rf(Path.join(target, dep))
      File.mkdir_p!(target)
      run("cp", ["-a", Path.join(source, dep), target])
      dep
    end
  end

  defp listing(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(fn path ->
      {Path.relative_to(path, dir), File.stat(path) |> elem(1) |> Map.get(:size) || 0}
    end)
    |> Enum.sort()
  end

  defp link_deps(path) do
    source = Path.join(Noetic.Harness.root(), "deps")
    target = Path.join(path, "deps")

    if File.dir?(source) and not File.exists?(target) do
      File.ln_s(source, target)
    end

    :ok
  end

  defp seed_dependencies(path) do
    case build_lib() do
      nil -> :ok
      lib -> seed_dependencies(path, lib)
    end
  end

  defp seed_dependencies(path, lib) do
    root = Noetic.Harness.root()
    source = Path.join(root, lib)
    target = Path.join(path, lib)
    own = own_apps(root)

    case File.ls(source) do
      {:ok, entries} ->
        case Enum.reject(entries, &(&1 in own)) do
          [] ->
            :ok

          deps ->
            File.mkdir_p!(target)
            run("cp", ["-a"] ++ Enum.map(deps, &Path.join(source, &1)) ++ [target])
            :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp own_apps(root) do
    with %{apps: apps} <- Noetic.Harness.Project.layout(),
         {:ok, names} <- File.ls(Path.join(root, apps)) do
      names
    else
      _ -> []
    end
  end

  @doc """
  Run the layout's test command (`mix test` here) over `files` in `app`, inside `tree`.

  `tree` is never `Noetic.Harness.root()`. That argument is the whole of
  The repository root is where somebody else is standing.
  """
  @spec run_tests(String.t(), [String.t()], String.t()) :: {String.t(), integer()}
  def run_tests(app, files, tree, readonly \\ []) do
    case Noetic.Harness.Project.layout() do
      # Said, as a failed run is: `Environments` and `Scoring` ask for the
      # layout first, so this is a caller that did not.
      nil ->
        {Noetic.Harness.Project.no_layout(), 1}

      %{apps: apps, test_command: [program | args]} ->
        cwd = Path.join([tree, apps, app])
        {command, argv} = confine_command(program, args ++ files, tree, readonly)

        run(command, argv, cd: cwd, env: [{"MIX_ENV", "test"}])
    end
  end

  @doc """
  Whether this machine can make a path read-only for one command.

  `mix test` compiles the solver's file before ExUnit loads the
  verifier, so a module body in a solver's source is code the scoring host
  executes — and an independent review used exactly that to rewrite the
  verifier `Tree.restore/3` had just put back, scoring `solved: true` on a
  defect it had not touched. An earlier change added detection: the oracle is hashed
  before and after, and an attempt whose oracle moved is unusable. A solver
  that puts the original bytes back at `System.at_exit` defeats it.

  The bead priced three containments — a container, a separate user, a second
  tree — and all three are expensive here. There is a fourth it did not list
  and this machine has: **bubblewrap**. `bwrap --ro-bind <file> <file>` makes
  the verifier read-only for one process tree, with no root, no daemon and no
  image. A compile-time `File.write!` to it fails with `EROFS` rather than
  succeeding and being noticed afterwards.

  Measured 2026-09-22: 7–12 ms per invocation, against a verification that
  takes 1m35s. Passwordless `sudo` is not available here and the docker daemon
  is not reachable from this user, so the other two options are not merely
  expensive — they do not run.

  `false` means the boundary is absent, and that is reported rather than
  silently tolerated: §5 of the constitution is that a gate which could not run
  is `unavailable`, not `passed`.
  """
  @spec confined?() :: boolean()
  def confined? do
    case System.find_executable("bwrap") do
      nil ->
        false

      bwrap ->
        # Present is not the same as working: user namespaces are disabled on
        # some hosts, and `bwrap` then fails at the first bind. Asked, not
        # assumed — the same rule `noetic-harness inspect --tools` applies.
        match?(
          {_, 0},
          System.cmd(bwrap, ["--dev-bind", "/", "/", "true"], stderr_to_stdout: true)
        )
    end
  rescue
    _ -> false
  end

  # The shared `deps`, if this tree has the symlink `prepare/1` makes.
  #
  # An earlier change's residual, found while closing an earlier change: `tree/deps` points
  # at the **real repository's** `deps/`, so a solver writing `deps/<anything>`
  # modifies the shared checkout. `changed_paths/1` cannot see it — it is
  # outside the worktree's git — and `confine/3` cannot revert it, because
  # there is nothing in the tree to revert. Every later verification in every
  # worktree then uses the modified dependency.
  #
  # Binding the *target* read-only costs nothing a verification needs: `mix`
  # writes build artifacts to `_build`, never to `deps`, and `deps.compile`
  # does not run inside a scoring attempt because the artifacts are seeded.
  defp shared_deps(tree) do
    link = Path.join(tree, "deps")

    case File.read_link(link) do
      {:ok, target} -> [Path.expand(target, tree)]
      {:error, _not_a_symlink} -> []
    end
  end

  defp confine_command(command, argv, tree, readonly) do
    paths =
      (Enum.map(readonly, &Path.join(tree, &1)) ++ shared_deps(tree))
      |> Enum.filter(&File.exists?/1)
      |> Enum.uniq()

    if paths != [] and confined?() do
      binds = Enum.flat_map(paths, &["--ro-bind", &1, &1])
      {"bwrap", ["--dev-bind", "/", "/"] ++ binds ++ ["--", command] ++ argv}
    else
      {command, argv}
    end
  end

  @doc "Did `mix` fail before it reached the tests? See the moduledoc."
  @spec environmental?(String.t()) :: boolean()
  def environmental?(output), do: Regex.match?(@environmental, output)

  @doc """
  Reverse-apply a commit's diff, restricted to `paths`, inside `tree`.

  Nothing is restored afterwards and no `after` clause guards it, because the
  tree this writes to is thrown away. The whole "the working tree was left
  reversed" state a shared-tree version had to be able to report is
  unreachable.
  """
  @spec reverse_patch(String.t(), String.t(), [String.t()]) :: :ok | {:error, String.t()}
  def reverse_patch(tree, sha, paths) do
    # A private directory with an unpredictable name. The first version wrote
    # `/tmp/harness-env-<id>.patch`, which any local user could pre-create as a
    # symlink or swap between the write and the `git apply` — and the thing
    # applied would then be compiled and executed by `mix test`.
    dir = Path.join(System.tmp_dir!(), "harness-tree-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    _ = File.chmod(dir, 0o700)
    patch = Path.join(dir, "fix.patch")

    try do
      case git(["show", "--format=", sha, "--"] ++ paths) do
        {:error, reason} ->
          {:error, "cannot read the commit: #{reason}"}

        {:ok, diff} ->
          File.write!(patch, diff)

          case tree_run(tree, ["apply", "--reverse", patch]) do
            {_, 0} -> :ok
            {output, _} -> {:error, "the patch no longer reverse-applies: #{String.trim(output)}"}
          end
      end
    after
      File.rm_rf(dir)
    end
  end

  @doc """
  Put `paths` back to what `ref` says they are, inside `tree`.

  This is how an oracle is taken away from a solver and given back to the
  scorer: the verifier files are removed before an agent is called and
  restored from the arm's own commit before the verdict is taken.
  """
  @spec restore(String.t(), String.t(), [String.t()]) :: :ok | {:error, String.t()}
  def restore(_tree, _ref, []), do: :ok

  def restore(tree, ref, paths) do
    case tree_run(tree, ["checkout", ref, "--"] ++ paths) do
      {_, 0} ->
        :ok

      {output, _} ->
        {:error, "could not restore #{Enum.join(paths, ", ")}: #{String.trim(output)}"}
    end
  end

  @doc """
  Throw away everything the solver changed except `keep`.

  A solver is asked to change the environment's `source_paths` and nothing
  else, and until an independent review said so that was a *request*. It
  showed a solver scoring `solved: true` on an untouched defect by rewriting
  `test_helper.exs` to exclude the failing test — `mix` exits 0, and nothing
  downstream can tell that apart from a fix.

  So the request becomes a boundary: after the agent returns, every **tracked**
  path it touched outside `keep` goes back to what the prepared commit says,
  and anything untracked it created outside `keep` is removed.

  **Ignored too, since an earlier change.** It used to be `git clean -qfd` with no
  `-x`, so a file under `_build/`, `deps/`, `doc/` or any stray `*.beam`
  survived confinement and was invisible to the fence. An independent review
  demonstrated both. That is a scoring-integrity question rather than hygiene:
  mix trusts a `.beam` with a fresh mtime, so a planted one is a compiled
  module the verifier then runs.

  A bare `-x` was not available, which is why the bead sat: `prepare/1`
  symlinks `deps/` and seeds `_build/test/lib/<dep>`, and that is the
  difference between a 1m35s verification and a 7m06s one. Re-seeding after
  every confinement was measured on this machine and costs 32s for 93MB — too
  much for something that runs once per attempt.

  So the clean is `-x` with an exclusion per seeded path, and the exclusions
  are computed from the **source** tree rather than from the worktree. That
  distinction is the whole guard: a solver that creates
  `_build/test/lib/evil/` gets it removed, because `evil` is not a directory
  the real build has. What an exclusion cannot prevent is a file planted
  *inside* a seeded directory — so each one is then compared against its
  source by listing, and a directory that diverges is removed and re-copied.
  One dependency, not ninety-three.

  What this still does not reach is `deps/`, which is a **symlink to the real
  repository** — a write through it lands outside the worktree entirely and no
  amount of cleaning inside the tree can revert it. That is not a gap in this
  function; it is an earlier change, which says the worktree is not a containment
  boundary because `mix test` compiles the solver's code in the first place.
  Recorded there rather than papered over here.

  Returns the paths it reverted — tracked paths outside `keep`, and the
  ignored strays it removed — so that a caller can say what it took away.
  """
  @spec confine(String.t(), String.t(), [String.t()]) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def confine(tree, base, keep) do
    kept =
      Map.new(keep, fn path ->
        full = Path.join(tree, path)
        {path, if(File.regular?(full), do: File.read!(full))}
      end)

    with {_, 0} <- tree_run(tree, ["add", "-A", "--intent-to-add", "--" | pathspec()]),
         # `core.quotePath=false`: a path with a byte outside ASCII is
         # otherwise quoted and octal-escaped, and this list is compared
         # against `keep` by string equality. Same defect as
         # `Workspace.changed_paths/1`, found in the same review.
         {output, 0} <-
           tree_run(tree, [
             "-c",
             "core.quotePath=false",
             "diff",
             "--name-only",
             "--no-renames",
             base
           ]) do
      changed = output |> String.split("\n", trim: true) |> Enum.sort()
      outside = changed -- keep

      excludes = Enum.flat_map(seeded(), &["-e", &1])
      stray = strays(tree, excludes)

      with {_, 0} <- tree_run(tree, ["reset", "-q", "--hard", base]),
           {_, 0} <- tree_run(tree, ["clean", "-qfdx"] ++ excludes) do
        reseed_divergent(tree)

        Enum.each(kept, fn
          {_path, nil} -> :ok
          {path, content} -> File.write!(Path.join(tree, path), content)
        end)

        {:ok, Enum.sort(outside ++ stray)}
      else
        {output, _} -> {:error, "could not confine the change: #{String.trim(output)}"}
      end
    else
      {output, _} -> {:error, "could not see what changed: #{String.trim(output)}"}
    end
  end

  @doc """
  Delete `paths` from `tree`.

  Used to take the verifier out of a scoring tree before the solver sees it.
  `Environments.brief/1` controls what a solver is *handed*; this controls what
  is *there*, which is what an earlier change could only narrow.
  """
  @spec remove(String.t(), [String.t()]) :: :ok
  def remove(tree, paths) do
    Enum.each(paths, fn path -> File.rm_rf(Path.join(tree, path)) end)
    :ok
  end

  @doc """
  Commit everything in `tree` and return the new sha.

  This exists for one reason and it is not tidiness. A scoring worktree is
  *prepared* before the solver arrives — the defect reintroduced, the verifier
  deleted — and those are changes the harness made, not the agent. The
  evaluator fence judges what changed against the workspace's base, so without
  this it refused every scoring attempt for the scorer's own deletion of the
  oracle. Committing the prepared state makes the base what the solver actually
  started from, which is the only thing the fence should be looking at.

  A design decision already allows a dispatched run to commit inside its own
  worktree; this is that, done by the thing that set the tree up.
  """
  @spec commit(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def commit(tree, message) do
    with {_, 0} <- tree_run(tree, ["add", "-A"]),
         {_, 0} <-
           tree_run(tree, [
             "-c",
             "user.email=harness@harness.invalid",
             "-c",
             "user.name=harness",
             "commit",
             "-q",
             "--allow-empty",
             "-m",
             message
           ]),
         {sha, 0} <- tree_run(tree, ["rev-parse", "HEAD"]) do
      {:ok, String.trim(sha)}
    else
      {output, _} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Give `tree` a history of its own, for as long as a solver works in it.

  An earlier change, and the hole it closes was the cheapest in the engine. A
  worktree shares its repository's object store, and a scoring arm has the
  environment's fix in its history, because `Scoring` refuses an arm that
  does not. So from inside the tree `git show <fix>` handed a solver the
  answer, and so did `git show HEAD~1:<verifier>`: deleting the verifier
  from the working tree left it one commit back, under the prepared commit.
  An orphan commit would not have helped, because the objects stay in the
  store and `git log --all` still lists the arm.

  So the tree's `.git` file is pointed at a repository made for the solver,
  outside the host's, holding **one commit**: the prepared commit's files,
  path for path, and nothing that was ever in the host's history. The host
  never reads that file, because `Workspace.tree_git/1` addresses a tree
  through the admin directory it registered. So the fence, `confine/3`,
  `restore/3` and the verdict still see the arm's history, which they need.

  Four things are asked before the new repository is handed over, and a
  failure of any one is an error, not a weaker attempt:

    * no repository encloses the tree's parent (`unenclosed/1`). A tree
      under the host's `.git/` — where `Workspace.root/0` puts one — is
      refused: from there `git -C .. show <fix>` found the host, because git
      searches upward, and a review of the first version did exactly that.
      `Scoring` opens its trees under `solver_root/0` instead;
    * its commit's tree is the prepared commit's tree, sha for sha;
    * it holds that one commit and no other;
    * none of `hidden` is an object in it. These are revisions as the host
      names them: `Scoring` passes the fix and `<fix>:<verifier>` for each
      verifier file.

  **What this does not close.** The host's repository is on the same disk,
  and a process running as the same user can read it by its path, with git
  or without. Two ways to that path start in the tree: `deps` is a symlink
  into the host's checkout, and each seeded `_build/test/lib/<dep>/priv` is
  a relative link through it, so `git -C deps/.. show <fix>` still finds the
  host. And the solver's environment may still name the host's path: `PWD`,
  `OLDPWD` or `CLAUDE_PROJECT_DIR`, when the harness was started from it.
  And the solver need not know the path at all. Its process is a child of
  this VM's `erl_child_setup` (the adapter's `sh` execs it), which keeps the
  working directory the VM started in, so `/proc/$PPID/cwd`, read by the
  solver or one ancestor up from a command it runs, is the host's checkout
  whenever the harness was started there. `without_git_env/1` takes away the
  variables that point *git* at a repository or at configuration from
  outside, and no others. All of that is containment, and no
  sandbox is claimed here. What this makes true is narrower, and it is the
  one an ordinary solver trips over: the history *in* the tree — `git log`,
  `git show`, `git diff HEAD~1`, the reflog — and *above* it holds the task
  and not its answer.

  Call it after the prepared commit and before `prepare/1`. `add -A -f`
  takes every file in the tree, and once `deps` and `_build` are there that
  is no longer the commit, which the first check refuses. `rejoin/1` undoes
  it. A tree left severed, by a VM killed mid-dispatch, can still be
  removed: `Workspace` repairs a `.git` file that does not point home before
  it removes the tree.
  """
  @spec sever(String.t(), [String.t()]) :: {:ok, map()} | {:error, String.t()}
  def sever(tree, hidden) do
    with {:ok, admin} <- admin_dir(tree),
         :ok <- unenclosed(Path.dirname(Path.expand(tree))),
         {_, {expected, 0}} <- {:tree, tree_run(tree, ["rev-parse", "--verify", "HEAD^{tree}"])},
         {:ok, objects} <- host_objects(hidden),
         {:ok, dir} <- private_dir("acme-solver") do
      severed = %{tree: tree, admin: admin, dir: dir}

      case own_history(tree, Path.join(dir, "git"), String.trim(expected), objects) do
        :ok ->
          {:ok, severed}

        {:error, reason} ->
          rejoin(severed)
          {:error, reason}
      end
    else
      {:tree, {output, _}} ->
        {:error, "the prepared commit cannot be read: #{String.trim(output)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Point `tree`'s `.git` back at the host's admin directory and delete the
  solver's repository. Whatever the solver left at `.git` is removed first,
  without following it.
  """
  @spec rejoin(map()) :: :ok | {:error, String.t()}
  def rejoin(%{tree: tree, admin: admin, dir: dir}) do
    dotgit = Path.join(tree, ".git")
    File.rm_rf(dotgit)
    written = File.write(dotgit, "gitdir: #{admin}\n")
    File.rm_rf(dir)

    case written do
      :ok -> :ok
      {:error, why} -> {:error, "could not point #{dotgit} back home: #{inspect(why)}"}
    end
  end

  @doc """
  A directory to open a solver's tree in: private, and enclosed by no
  repository.

  An earlier change, found in review. `Workspace.root/0` is under the host's `.git/`, and a
  tree there has the host one `..` away: `git -C .. show <fix>` returned the
  verifier from a severed tree, and `GIT_CEILING_DIRECTORIES` did not stop it
  — the solver's environment is the solver's to change. So `Scoring` opens
  each arm's worktree here, under the system's temporary directory, and
  removes the directory when the arm is done. The host still registers the
  worktree and reads it through its own admin directory, so nothing that
  judges the attempt changes.

  The path is the **physical** one. Git records a worktree by its resolved
  path, and `Workspace.tree_git/1` compares that record with the path it is
  given, so a `TMPDIR` reached through a symlink would make every scoring
  tree unreadable to the host.

  It costs a checkout of the tree and a copy of the dependencies' build
  artifacts on the temporary directory's filesystem — about 160 MB here
  before the umbrella's own apps compile into it, one arm at a time. Where
  that is a small `tmpfs`, `TMPDIR` moves it. A `TMPDIR` inside a repository
  is refused rather than used.
  """
  @spec solver_root() :: {:ok, String.t()} | {:error, String.t()}
  def solver_root do
    with {:ok, dir} <- private_dir("acme-score") do
      with {:ok, physical} <- physical(dir),
           :ok <- unenclosed(physical) do
        {:ok, physical}
      else
        {:error, reason} ->
          File.rm_rf(dir)
          {:error, reason}
      end
    end
  end

  @doc """
  Run `fun` with no variable in the environment that points git at a
  repository or at configuration from outside, and put them back afterwards.

  An earlier change, found in review. The solver is a separate OS process, and it inherits
  this VM's environment. A `GIT_DIR`, `GIT_WORK_TREE` or
  `GIT_OBJECT_DIRECTORY` naming the host — git exports the first two to the
  hooks it runs (githooks(5)), and so to anything a hook starts — would hand
  a solver in a severed tree the host's history without a `cd`. The
  harness's own git calls on the solver's repository already run without
  them (`@clean_git_env`); this is the solver's.

  The configuration variables go with them.
  `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM` and `GIT_CONFIG` each name a file
  of configuration from outside the tree, as `GIT_CONFIG_PARAMETERS` and
  `GIT_CONFIG_COUNT` carry it inline, and git reads each alone. Without them
  a solver's git reads the configuration it would read anywhere, and not
  the one this VM was given.

  Process-global for something that is per call, and for the reason
  `Dispatcher`'s `as_parent/2` gives: the environment is the only channel
  that reaches a program an adapter starts, and a scoring run dispatches
  one attempt at a time. Afterwards the environment is what it was, whatever
  `fun` did to these variables.
  """
  @spec without_git_env((-> result)) :: result when result: term()
  def without_git_env(fun) do
    vars = Enum.map(@clean_git_env, &elem(&1, 0))
    saved = Map.take(System.get_env(), vars)
    clear = fn -> Enum.each(vars, &System.delete_env/1) end
    clear.()

    try do
      fun.()
    after
      clear.()
      System.put_env(saved)
    end
  end

  defp own_history(tree, git_dir, expected, objects) do
    solver = fn args -> solver_git(git_dir, tree, args) end

    with :ok <- remove_gitfile(tree),
         {_, 0} <-
           run("git", ["init", "-q", "--template=", "--separate-git-dir=" <> git_dir, tree],
             env: @clean_git_env
           ),
         {_, 0} <- solver.(["add", "-A", "-f"]),
         {_, 0} <-
           solver.([
             "-c",
             "user.email=harness@harness.invalid",
             "-c",
             "user.name=harness",
             "-c",
             "commit.gpgsign=false",
             "commit",
             "-q",
             "-m",
             "the tree you were given"
           ]),
         :ok <- same_tree(solver, expected),
         :ok <- one_commit(solver),
         :ok <- absent(solver, objects) do
      # `prepare/1` puts `deps` here as a symlink, which the project's
      # `/deps/` does not match, and the solver's `git status` should start
      # clean.
      File.mkdir_p!(Path.join(git_dir, "info"))
      File.write!(Path.join([git_dir, "info", "exclude"]), "/deps\n")
      :ok
    else
      {:error, reason} -> {:error, reason}
      {output, _} -> {:error, "could not make the solver's repository: #{String.trim(output)}"}
    end
  end

  defp remove_gitfile(tree) do
    case File.rm(Path.join(tree, ".git")) do
      :ok -> :ok
      {:error, why} -> {:error, "could not remove #{tree}/.git: #{inspect(why)}"}
    end
  end

  defp same_tree(solver, expected) do
    case solver.(["rev-parse", "--verify", "HEAD^{tree}"]) do
      {sha, 0} ->
        if String.trim(sha) == expected,
          do: :ok,
          else:
            {:error,
             "the solver's commit is not the prepared commit's tree (#{String.trim(sha)}, " <>
               "not #{expected})"}

      {output, _} ->
        {:error, "the solver's commit cannot be read: #{String.trim(output)}"}
    end
  end

  defp one_commit(solver) do
    case solver.(["rev-list", "--all", "--reflog", "--count"]) do
      {"1\n", 0} ->
        :ok

      {output, _} ->
        {:error, "the solver's repository holds #{String.trim(output)} commits, not 1"}
    end
  end

  defp absent(solver, objects) do
    case Enum.filter(objects, fn {_rev, sha} ->
           match?({_, 0}, solver.(["cat-file", "-e", sha]))
         end) do
      [] ->
        :ok

      present ->
        {:error,
         "the solver's repository holds #{Enum.map_join(present, ", ", &elem(&1, 0))}, " <>
           "which it was not to be given"}
    end
  end

  # Each revision as the host resolves it, and an object the host holds. One
  # it cannot resolve is an error, because its absence from the solver's
  # store would then be checked against nothing. `rev-parse --verify` alone
  # does not ask: it answers any forty hex digits with themselves, which a
  # test of this caught.
  defp host_objects(revisions) do
    Enum.reduce_while(revisions, {:ok, []}, fn rev, {:ok, acc} ->
      with {sha, 0} <- run("git", ["rev-parse", "--verify", "--quiet", rev]),
           sha = String.trim(sha),
           {_, 0} <- run("git", ["cat-file", "-e", sha]) do
        {:cont, {:ok, [{rev, sha} | acc]}}
      else
        _ -> {:halt, {:error, "the host cannot resolve #{rev}, so its absence cannot be checked"}}
      end
    end)
  end

  defp admin_dir(tree) do
    with {:ok, git} <- Workspace.tree_git(tree) do
      case Enum.find_value(git, &(String.starts_with?(&1, "--git-dir=") && &1)) do
        "--git-dir=" <> admin -> {:ok, admin}
        _ -> {:error, "no admin directory for #{tree}"}
      end
    end
  end

  # Unpredictable, and refused if it is already there: a solver runs as the
  # same user and may know this directory's name.
  defp private_dir(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.pid()}-#{:erlang.unique_integer([:positive])}-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
      )

    case File.mkdir(dir) do
      :ok ->
        _ = File.chmod(dir, 0o700)
        {:ok, dir}

      {:error, why} ->
        {:error, "could not make a private directory for the solver: #{inspect(why)}"}
    end
  end

  # Is `dir` inside a repository, asked the way a solver that wants the answer
  # would ask? Its environment is its own, so nothing that a variable or a
  # setting could switch off is left on here: no `GIT_*` pointing anywhere, no
  # ceiling, discovery across filesystems, and every repository counted as
  # safe whoever owns it. `LC_ALL=C`, because "not a git repository" is the
  # only answer that means no, and a translated git says it differently.
  @discovery @clean_git_env ++
               [
                 {"GIT_CEILING_DIRECTORIES", nil},
                 {"GIT_DISCOVERY_ACROSS_FILESYSTEM", "1"},
                 {"LC_ALL", "C"}
               ]

  defp unenclosed(dir) do
    case run(
           "git",
           ["-c", "safe.directory=*", "-c", "safe.bareRepository=all"] ++
             ["rev-parse", "--absolute-git-dir"],
           cd: dir,
           env: @discovery
         ) do
      {repo, 0} ->
        {:error,
         "#{dir} is inside the repository at #{String.trim(repo)}, so a solver's " <>
           "`git -C ..` would read that repository's history"}

      {output, 128} ->
        if output =~ "not a git repository",
          do: :ok,
          else:
            {:error,
             "git could not say whether #{dir} is in a repository: #{String.trim(output)}"}

      {output, _} ->
        {:error, "git could not say whether #{dir} is in a repository: #{String.trim(output)}"}
    end
  end

  # The path with every symlink resolved, which is how git records a worktree.
  defp physical(dir) do
    case run("pwd", ["-P"], cd: dir) do
      {path, 0} -> {:ok, String.trim(path)}
      {output, _} -> {:error, "could not resolve #{dir}: #{String.trim(output)}"}
    end
  end

  # The solver's repository, addressed explicitly, and with nothing in the
  # environment that could point it at another object store.
  defp solver_git(git_dir, tree, args) do
    run(
      "git",
      [
        "--git-dir=" <> git_dir,
        "--work-tree=" <> tree,
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null" | args
      ],
      cd: tree,
      env: @clean_git_env
    )
  end

  @doc """
  Is `ancestor` reachable from `ref`?

  A scoring arm from which an environment's fix commit is not reachable cannot
  have that defect reintroduced — the patch has nothing to reverse — so the arm
  and the environment are not comparable. Asked before anything is spent.
  """
  @spec ancestor?(String.t(), String.t()) :: boolean()
  def ancestor?(ancestor, ref) do
    match?({_, 0}, run("git", ["merge-base", "--is-ancestor", ancestor, ref]))
  end

  # argv, never a shell. Every value that reaches here — an app name, a test
  # file, a patch path — comes out of a JSON file under `.agents/`, and an
  # early version of this interpolated all three into `sh -c`. A file naming
  # its test `"x_test.exs; curl … | sh"` was arbitrary code execution for
  # whoever ran the suite next.
  # git in a tree that candidate code has run in — and may have written, `.git`
  # included. `Workspace.tree_git/1` addresses it without believing its `.git`
  # (the `core.fsmonitor` escape an earlier change's review found), and a tree whose
  # admin directory cannot be confirmed is not touched: the answer comes back
  # as git's own failure status, which every caller here already handles.
  defp tree_run(tree, args) do
    case Noetic.Harness.Workspace.tree_git(tree) do
      {:ok, git} -> run("git", git ++ args, cd: tree)
      {:error, message} -> {message, 128}
    end
  end

  defp run(command, args, opts \\ []) do
    opts = Keyword.merge([cd: Noetic.Harness.root(), stderr_to_stdout: true], opts)
    System.cmd(command, args, opts)
  rescue
    error -> {Exception.message(error), 127}
  end

  defp git(args) do
    case run("git", args) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, String.trim(output)}
    end
  end
end
