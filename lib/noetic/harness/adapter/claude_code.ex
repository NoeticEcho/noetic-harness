defmodule Noetic.Harness.Adapter.ClaudeCode do
  @moduledoc """
  `claude -p`, on the subscription the person is already signed in to.

  The adapter to prefer. It needs no API key, which is not a convenience but a
  security property: a credential that does not exist cannot leak into a log, a
  bead, a prompt or a commit. `claude` reads its own auth and this module never
  sees it.

  ## What it runs

      claude -p --output-format json --model <model> [--restricted] <prompt on stdin>

  in the run's worktree and nowhere else. `:cwd` is required rather than
  defaulted: an adapter that falls back to the current directory when nobody
  told it where to work is an adapter that writes into the parent's tree, which
  is the whole thing `Noetic.Harness.Workspace` exists to stop.

  `--restricted` removes Bash, PowerShell and the REPL, and the *policy* says
  when — T0 and T1 read and draft, so they get no command execution at all.
  The flag is passed for those and omitted otherwise; it is not a judgement
  this module makes.

  ## What comes back

  `--output-format json` emits one object. The fields this reads, checked
  against a real run rather than against the documentation:

      result             the text the agent produced
      is_error           whether it failed
      subtype            "success", or how it did not succeed
      total_cost_usd     what it cost
      usage              input/output/cache tokens
      num_turns          how many turns it took
      permission_denials tools it asked for and did not get

  `permission_denials` is carried through deliberately. A dispatched run that
  spent its turns being told no did not do the work, and that is a different
  failure from one that tried and was wrong.

  **A trivial prompt cost $0.155** when this was measured, almost all of it
  cache-creation on the system prompt. Dispatch is never free, and the cheapest
  possible call is not cheap.

  ## When `claude` is not there

  `call/2` looks the executable up itself and answers `{:error, why}` — the
  sentence `available?/0` gives — rather than trusting that an earlier
  `available?/0` still holds. Until an earlier change it trusted it, and a missing
  `claude` became an `ArgumentError` inside a linked task: an exit that killed
  the caller before the dispatcher could record the failure.

  ## What it does not do

  It does not retry, choose a model, or decide the trust. The conductor decides
  the step, `Policy.derive_trust/3` the trust, and the policy the model. This
  runs one command and reports what happened.
  """

  @behaviour Noetic.Harness.Adapter

  @default_timeout_ms 20 * 60 * 1000

  @impl true
  def available? do
    case executable() do
      {:error, why} -> {:unavailable, why}
      {:ok, _path} -> Noetic.Harness.Adapter.credentials("claude_code")
    end
  end

  @impl true
  def call(prompt, opts) do
    with {:ok, cwd} <- cwd(opts),
         {:ok, claude} <- executable() do
      args = args(opts)
      timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

      case run(claude, args, prompt, cwd, timeout) do
        {:ok, output} -> parse(output)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Looked up on every call, and never taken on trust from `available?/0`.
  #
  # `available?/0` is a question asked earlier — `Adapter.resolve/1`, when the
  # dispatch was planned — and a dispatch can be minutes after its plan, or
  # reach `call/2` without asking at all. Until an earlier change `call/2` assumed
  # the answer still held: `System.find_executable/1` returned `nil`, the `nil`
  # went into `System.cmd/3`'s argv inside a *linked* task, and the
  # `ArgumentError` it raised reached the caller as an exit signal rather than
  # as a value. A process killed by a signal runs no `after` clause (checked,
  # not assumed), so the dispatcher never wrote the failure to the ledger and
  # never restored `NOETIC_HARNESS_PARENT_RUN`. CI found it: the `:live` test,
  # which nothing excluded, ran on a machine with no `claude` and died with
  # `EXIT`.
  #
  # The behaviour's contract is `{:error, term}`, and the sentence is the one
  # `available?/0` gives, so the two cannot drift apart.
  defp executable do
    case System.find_executable("claude") do
      nil ->
        {:error,
         "`claude` is not on PATH, so there is nothing to dispatch to. Install " <>
           "Claude Code, or point `:dispatch_adapter_id` at an adapter whose " <>
           "requirements are met"}

      path ->
        {:ok, path}
    end
  end

  # Required, not defaulted. See the moduledoc.
  defp cwd(opts) do
    case Keyword.get(opts, :cwd) do
      nil ->
        {:error,
         "no working directory was given, and this adapter does not default to " <>
           "the current one — a dispatched run writes in its own worktree " <>
           ""}

      cwd ->
        if File.dir?(cwd),
          do: {:ok, cwd},
          else: {:error, "the working directory #{cwd} does not exist"}
    end
  end

  defp args(opts) do
    base = ["-p", "--output-format", "json"]

    base
    |> then(fn args ->
      case Keyword.get(opts, :model) do
        nil -> args
        model -> args ++ ["--model", model]
      end
    end)
    |> then(fn args ->
      if Keyword.get(opts, :restricted, true), do: args ++ ["--restricted"], else: args
    end)
  end

  # The prompt goes on **stdin**, not in argv: it carries the constitution and
  # a context bundle — 43 KB on the first real one — and an argv that long is
  # one `ARG_MAX` away from a failure that reads like the model refusing.
  #
  # Two ways were tried before this one. A port (`Port.open/2` with
  # `:spawn_executable`) can write the prompt but cannot close stdin
  # afterwards, so `claude` waits for input that never ends; `Port.close/1`
  # closes the whole port and kills the process. `System.cmd/3` has no stdin at
  # all. So the prompt goes to a file and `sh` does the redirect.
  #
  # Every value is a positional argument and nothing is interpolated into the
  # script, which was checked with a path containing `; echo PWNED` — `sh -c`
  # with a built-up string is how a temp-file path becomes a command.
  @script ~s(bin="$1"; input="$2"; shift 2; exec "$bin" "$@" < "$input")

  # `claude` arrives resolved (`executable/0`). If it vanishes between the
  # lookup and the `exec`, `sh` is the one that fails, with a non-zero status
  # (127 under bash, which is what was checked; CI's dash was not), and that
  # comes back as `{:error, "`claude` exited <status>: ..."}` rather than as a
  # raise.
  defp run(claude, args, prompt, cwd, timeout) do
    path = Path.join(System.tmp_dir!(), "acme-dispatch-#{System.unique_integer([:positive])}")

    try do
      File.write!(path, prompt)

      task =
        Task.async(fn ->
          System.cmd("sh", ["-c", @script, "sh", claude, path | args],
            cd: cwd,
            stderr_to_stdout: true
          )
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} ->
          {:ok, output}

        {:ok, {output, code}} ->
          {:error,
           "`claude` exited #{code}: #{output |> String.slice(0, 2_000) |> String.trim()}"}

        nil ->
          {:error, "`claude` did not finish within #{div(timeout, 1000)}s and was killed"}
      end
    after
      File.rm(path)
    end
  end

  defp parse(output) do
    case JSON.decode(output) do
      {:ok, %{"is_error" => true} = doc} ->
        {:error, "the agent reported an error (#{doc["subtype"]}): #{doc["result"]}"}

      {:ok, doc} ->
        {:ok,
         %{
           output: doc["result"],
           cost_usd: doc["total_cost_usd"],
           usage: doc["usage"],
           turns: doc["num_turns"],
           denials: doc["permission_denials"] || [],
           session: doc["session_id"],
           adapter: "claude_code"
         }}

      {:error, _} ->
        # Not a parse detail worth printing in full: the output may be a login
        # prompt or a stack trace, and either way the first lines say which.
        {:error,
         "`claude` did not return JSON. The first of what it said: " <>
           (output |> String.slice(0, 500) |> String.trim())}
    end
  end
end
