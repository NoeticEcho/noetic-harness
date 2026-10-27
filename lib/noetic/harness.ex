defmodule Noetic.Harness do
  @moduledoc """
  The AI development harness: the runtime that reads `.agents/` and turns it
  into routed work.

  ## Why this exists as code and not as documentation

  A harness written only as prose is a set of intentions. Every claim it makes —
  "every registered agent has a prompt", "every skill a role names exists",
  "this gate runs before that merge" — is true until someone renames a file, and
  then it is quietly false and nobody finds out. This app makes those claims
  executable: `noetic-harness validate` fails when a role names a skill that is not
  on disk, when a workflow step requires a capability nobody supplies, when a
  gate names a holder that is not a role, or when an agent cannot compose a
  prompt.

  ## The separation

  | Layer | Where | Rule |
  |---|---|---|
  | Canonical definitions | `.agents/` | Hand-authored or generated once. The source of truth. |
  | Runtime | `apps/noetic_harness` | Reads the definitions. Holds no copy of them. |
  | Generated adapters | `.claude/agents/`, `.agents/prompts/` | Derived. Never hand-edited. |

  Nothing here hard-codes a role, a skill, a workflow or a gate. Adding a role
  is a line in `.agents/registry/`, not a module here — which is the difference
  between a registry and a very long `case` statement.

  ## Reading order

  `Noetic.Harness.Registry` → `Noetic.Harness.Router` →
  `Noetic.Harness.Context` → `Noetic.Harness.Prompt` → `Noetic.Harness.Gates`.

  `Noetic.Harness.Validation` is what CI runs, and reading it tells you what the
  harness considers a defect.

  ## What this app may depend on

  It depends on no other application in this umbrella, and on no hex package
  that needs a native build, a precompiled-binary download, or a started
  application. Today the list is `boundary`, compile-time only, and JSON is
  read with Elixir's built-in `JSON`.

  The rule used to be "zero hex dependencies", and an earlier change narrowed it
  after measuring what it was actually buying. Three properties hung on one
  sentence and only one of them was about hex:

    * `noetic-harness route` answers when the *product apps do not compile* — the
      case it exists for is a half-finished refactor, where you want to ask the
      harness what to do about the thing that is broken. That rests on the
      umbrella half.
    * The harness's own tests run when Postgres, TypeDB and Qdrant are absent,
      so the thing that checks the development system does not need the
      development system up. Also the umbrella half.
    * `noetic-harness hook` is fast because it loads beams with `-pa` instead of
      booting mix. **This half was wrong.** Measured 2026-09-22, twenty runs
      each: one code path 1038 ms, two 1017 ms, six 1028 ms, against a 3000 ms
      ceiling. The differences are inside the run-to-run spread. The BEAM boot
      is the whole cost and the path count is invisible.

  What does break the hook is a NIF — a `.so` opened on every prompt — a
  package that downloads a binary, which resolves on a machine with a network
  and not on one without, or a package that needs its application started, when
  the hook runs `elixir -e` and starts nothing. Those are what the rule now
  names, and `Noetic.Harness.AppDependenciesTest` checks them against what is on
  disk rather than against a list of package names.
  """

  use Boundary,
    deps: [],
    exports: [
      Adapter,
      Identity,
      Registry,
      Router,
      Context,
      Prompt,
      Gates,
      Memory,
      Evolution,
      Environments,
      Workflow,
      Skills,
      Policy,
      Artifact,
      Run,
      Telemetry,
      Validation,
      Adapters,
      Loader,
      Beads,
      Git,
      MCP
    ]

  # The process-dictionary key `put_root/1` writes. Not a string: a module
  # attribute keeps it out of reach of anything that iterates the dictionary
  # looking for strings, and makes a typo a compile error.
  @root_key :noetic_harness_root
  @discovered_key :noetic_harness_discovered_root

  @doc """
  The repository root: the directory that contains `.agents/`.

  Found by walking up from the current working directory, then from this
  module's own source path. Mix tasks in an umbrella run from a different
  directory depending on whether they were invoked at the root or inside an
  app, and an absolute path baked in at compile time breaks the moment the
  repository is cloned somewhere else — so it is computed, not configured.

  Two things override it, and the order matters: **this process** first, then
  `NOETIC_HARNESS_ROOT`.

  The environment variable came first and is VM-global, which made every test
  that needs an isolated `.agents/` a test that cannot run in parallel — and
  one that forgot `async: false` made the whole suite flaky under a failure
  message naming an unrelated module. An independent review of an earlier change
  caught it: `usage_test.exs` was `async: true` with an isolated root and
  three of five full runs failed, once taking down `SecurityTest`'s "an
  untrusted role cannot escalate by naming a higher trust" with "could not
  read file /tmp/usage-runs-611/.agents/skills/elixir-idioms/SKILL.md". That
  is an earlier change, and `put_root/1` is the answer: isolation per process rather
  than per VM.

  The variable stays, because a *subprocess* cannot read this process's
  dictionary — `noetic-harness hook` and every `System.cmd/3` in the suite still
  need it, and passing it per-command through `:env` is already per-subprocess
  and therefore already safe.

  **What a call costs** matters, because a call is made thousands of times:
  composing the 271 prompts makes 9,324. The `$callers` walk reads one
  dictionary key of each caller, not the dictionary. The discovered root is
  remembered per process, keyed by the working directory. So a warm call costs
  one read of the cwd, straight from `:prim_file` rather than through the file
  server. Both used to cost far more. In a `Task` whose caller had
  loaded the registry, a compose of every prompt took 27 s; it now takes 1.8 s.
  The difference was `PromptTest`'s and `ValidationTest`'s 60 s timeout inside
  a full suite (`Noetic.Harness.RootCostTest`).
  """
  @spec root() :: Path.t()
  def root do
    case process_root() || System.get_env("NOETIC_HARNESS_ROOT") do
      nil -> discover_root()
      path -> Path.expand(path)
    end
  end

  @doc """
  Point this process, and any `Task` it spawns, at a different repository root.

  Returns the previous value, so a caller can restore it. `delete_root/0`
  clears it.

  The `$callers` walk is what makes it usable: `Task.async/1` records its
  caller chain, so code the test starts in another process still resolves the
  test's root. It is the same mechanism Ecto's SQL sandbox uses for the same
  reason, and it is why this is a per-test override rather than a per-VM one.

  `on_exit/1` callbacks run in a process with no such chain, so a cleanup that
  needs the path must capture it before registering — which is the defect that
  leaked three run files into the committed registry once already.
  """
  @spec put_root(Path.t()) :: Path.t() | nil
  def put_root(path) when is_binary(path), do: Process.put(@root_key, Path.expand(path))

  @doc """
  This process's root override, or `nil`.

  What `put_root/1` would replace. A test that wants to restore what it found
  reads this rather than the environment variable, because the two are
  different overrides and restoring one for the other is how a nested
  fixture quietly escapes its tree.
  """
  @spec root_override() :: Path.t() | nil
  def root_override, do: process_root()

  @doc "Clear this process's root override. Returns the previous value."
  @spec delete_root() :: Path.t() | nil
  def delete_root, do: Process.delete(@root_key)

  defp process_root do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(fn
      pid when pid == self() ->
        Process.get(@root_key)

      # One key, not the dictionary. `Process.info(pid, :dictionary)` copies
      # all of it, and `Loader.cached_load/1` and `Prompt.cached_read/1` keep
      # whole parsed files there. A `Task` started by a process that had
      # loaded the registry paid 2.8 ms per `root/0` instead of 0.19 ms, and a
      # compose of every prompt took 26 s instead of 4.5. Inside a full suite
      # that was the 60 s timeout in `PromptTest` and `ValidationTest`.
      pid ->
        case Process.info(pid, {:dictionary, @root_key}) do
          {{:dictionary, @root_key}, :undefined} -> nil
          {{:dictionary, @root_key}, root} -> root
          nil -> nil
        end
    end)
  end

  @doc "Path to `.agents/` or one of its entries."
  @spec agents_path([String.t()] | String.t() | nil) :: Path.t()
  def agents_path(sub \\ nil)
  def agents_path(nil), do: Path.join(root(), ".agents")
  def agents_path(sub) when is_binary(sub), do: Path.join([root(), ".agents", sub])
  def agents_path(sub) when is_list(sub), do: Path.join([root(), ".agents" | sub])

  # Remembered per process, keyed by the working directory.
  #
  # Rediscovering on every call cost one file-server round trip for the cwd
  # and one per level walked up. Composing the 271 prompts calls `root/0`
  # 9,324 times, which is 37,296 requests queued behind every other async
  # test's file I/O. Warm, a call now costs the one `File.cwd!/0`.
  #
  # The key is the cwd, so a `File.cd` still moves the answer, as it did
  # before. What the memo would miss is an `.agents/` created or removed on the
  # path between the cwd and the root during one process's life. Nothing does
  # that: fixtures live in their own temp trees and are reached with
  # `put_root/1`. The walk uses `:raw` checks, which do not go through the
  # file server at all.
  #
  # The cwd is read with `:prim_file.get_cwd/0`, not `File.cwd!/0`.
  # `File.cwd!/0` is a call to the one file server, so every warm call queued
  # behind whatever file IO the rest of the node was doing; in a full suite on
  # the 2-core workstation `ValidationTest` timed out at 60 s with its stack in
  # `:file.call`. `:prim_file` reads the same process-wide cwd directly —
  # `File.cd/1` sets it through the file server, which calls `:prim_file` —
  # and was measured at 116 µs against 501 µs per call with eight processes
  # loading the file server.
  defp discover_root do
    cwd = current_dir()
    key = {@discovered_key, cwd}

    case Process.get(key) do
      nil ->
        found = walk_up(cwd) || walk_up(__DIR__) || cwd
        Process.put(key, found)
        found

      found ->
        found
    end
  end

  defp current_dir do
    case :prim_file.get_cwd() do
      {:ok, dir} -> IO.chardata_to_string(dir)
      {:error, _} -> File.cwd!()
    end
  end

  defp walk_up(path) do
    cond do
      File.dir?(Path.join(path, ".agents"), [:raw]) -> path
      Path.dirname(path) == path -> nil
      true -> walk_up(Path.dirname(path))
    end
  end
end
