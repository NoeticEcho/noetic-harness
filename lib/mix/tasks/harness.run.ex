defmodule Mix.Tasks.Harness.Run do
  @shortdoc "Open, record and close a run against a workflow"

  @moduledoc """
  The ledger of what you actually did. **It does not run anything for you.**

      noetic-harness run --list
      noetic-harness run --start WF-003 --title "world channel crashes mid-ritual" --bead bd-1234
      noetic-harness run --step reproduce --outcome done \\
        --evidence "mix test test/world/channel_test.exs:88 — 1 failure, matches the report"
      noetic-harness run --status
      noetic-harness run --finish

  With no `--run`, every command acts on the one open run. If two are open it
  refuses and names them rather than picking the newest: more than one session
  can share this working directory, and "newest wins" writes one session's
  evidence into another's ledger. Runs the test suite opens are marked
  ephemeral and are never the one it means — that is an earlier change, which cost
  four steps' evidence before it was a rule.

  `--finish` runs the workflow's gate lane itself rather than believing a report
  of it, and refuses to close the run when a required step has no recorded
  outcome, when any step's outcome is not `done`, or when the lane did not pass.
  A `partial` lane — one with a gate that could not run — needs
  `--accept-partial "<reason>"`, and the reason is stored in the run.

  ## Options

    * `--list` — every run, newest first (`--prune-ephemeral` removes the open
      ones the test suite left behind, except those of a VM still running or
      in another pid namespace, which it lists as kept)
    * `--start <WF-0xx>` with `--title`, optionally `--bead`, `--agent`, `--lane`,
      `--parent-run <id>` — the run that caused this one. It has to be a run in
      the ledger, because depth, spend and independence are all walked from it.
      A dispatched agent does not need to pass it: `Dispatcher` exports
      `NOETIC_HARNESS_PARENT_RUN` around the call and `Run.start/1` reads it,
      so a run opened inside a dispatch is already a child. The last line is
      `opened <run-id>`; a start that opened no run exits non-zero.
    * `--step <id>` with `--outcome`, `--evidence` (repeatable), `--artifact`
      (repeatable), `--note`
    * `--status` — what the run still owes
    * `--finish` — close it, or say why it cannot be closed
    * `--abandon "<reason>"` — close a run that is being stopped rather than completed
    * `--stop "<reason>"` — stop a run from outside it, optionally `--by <who>`
    * `--accept-partial "<reason>"` — finish on a lane with an unavailable gate
    * `--paths a.ex,b.ex` — the changed paths, for the lane
    * `--run <id>` — act on a run other than the current one
  """

  use Mix.Task

  alias Noetic.Harness.{Dispatcher, Run, Usage, Workflow}

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          list: :boolean,
          prune_ephemeral: :boolean,
          start: :string,
          title: :string,
          bead: :string,
          agent: :string,
          lane: :string,
          parent_run: :string,
          step: :string,
          outcome: :string,
          evidence: :keep,
          artifact: :keep,
          note: :string,
          status: :boolean,
          finish: :boolean,
          abandon: :string,
          stop: :string,
          by: :string,
          accept_partial: :string,
          paths: :string,
          run: :string
        ]
      )

    shell = Mix.shell()

    cond do
      opts[:prune_ephemeral] -> prune(shell)
      opts[:stop] -> stop(shell, opts)
      opts[:list] -> list(shell)
      opts[:start] -> start(shell, opts)
      opts[:step] -> record(shell, opts)
      opts[:finish] || opts[:abandon] -> finish(shell, opts)
      opts[:status] -> status(shell, opts)
      true -> status(shell, opts)
    end
  end

  defp list(shell) do
    case Run.list() do
      [] ->
        shell.info("no runs yet — `noetic-harness run --start <WF-0xx> --title \"...\"`")

      runs ->
        Enum.each(runs, fn run ->
          shell.info(
            "#{String.pad_trailing(run["status"], 10)} #{run["id"]}" <>
              if(run["ephemeral"], do: "  (test)", else: "") <>
              "\n           #{run["workflow"]} · #{run["title"]}" <>
              if(run["bead"], do: " · #{run["bead"]}", else: "")
          )
        end)
    end
  end

  # A crashed test leaves its run file behind — it has happened twice — and
  # those files are now identifiable rather than merely suspicious. Only open
  # ephemeral runs are removed: a closed one is a record of a suite that
  # finished, and deleting records is not this command's job.
  #
  # What it keeps is printed as well as what it removes. Litter now
  # says which VM wrote it, and a VM that is still running, or that ran in a
  # pid namespace this one cannot see into, keeps its litter. A command that
  # said "nothing to prune" over a file it had decided to keep would send the
  # person looking somewhere else.
  defp prune(shell) do
    removed = Run.prune_ephemeral() ++ Noetic.Harness.Artifact.prune_test()

    kept =
      for(
        run <- Run.list(),
        run["ephemeral"] == true and run["status"] == "open",
        do: {run["id"], run["owner_vm"]}
      ) ++
        for {path, artifact} <- Noetic.Harness.Artifact.test_output(),
            do: {Path.basename(path, ".json"), artifact["owner_vm"]}

    Enum.each(removed, &shell.info("removed #{&1}"))
    Enum.each(kept, fn {id, owner} -> shell.info("kept #{id}: #{kept_because(owner)}") end)

    if removed == [] and kept == [] do
      shell.info("nothing to prune: the test suite left nothing in the registry")
    end
  end

  defp kept_because(%{"os_pid" => os_pid}) do
    "written by VM #{os_pid}, which is still running or ran in a pid namespace this one " <>
      "cannot see. If you know it is gone, remove the file by hand"
  end

  defp kept_because(_owner), do: "git tracks it, or it does not say which VM wrote it"

  # Abandoning is something a run's own owner does when the work is
  # not going to be finished; stopping is something *anyone else* does to a run
  # that is acting. They are different states and `--finish` refuses the second
  # one — a stop that can be finished over is a suggestion.
  defp stop(shell, opts) do
    with {:ok, id} <- resolve(opts),
         {:ok, run} <- Run.stop(id, reason: opts[:stop], by: opts[:by]) do
      stopped = run["stopped"]

      shell.info("stopped #{run["id"]} — #{stopped["reason"]}")
      shell.info("  by #{stopped["by"]} at #{stopped["at"]}")

      if stopped["at_step"], do: shell.info("  during #{stopped["at_step"]}")

      shell.info("")
      shell.info("The evidence and the run's worktree are kept, on purpose: a stopped run is")
      shell.info("diagnosable or it is nothing. Open a new run for the work that is left.")
    else
      {:error, message} -> abort(shell, message)
    end
  end

  # A runtime workflow is refused here by its rule. `Run.start/1`
  # refuses it too, because `Workflow.fetch/1` does not answer one, but its
  # message can only say there is no such workflow.
  defp start(shell, opts) do
    with :ok <- Workflow.development_refusal(opts[:start], "starts"),
         {:ok, run} <-
           Run.start(
             workflow: opts[:start],
             title: opts[:title],
             bead: opts[:bead],
             agent: opts[:agent],
             lane: opts[:lane],
             parent_run: opts[:parent_run]
           ) do
      # The run's id is the last line, whatever else is said. It
      # was the first, and a worker's `| tail -3` showed three lines that
      # were true of any run, so a start nobody could name went unnoticed.
      # A start that opened nothing exits non-zero through `abort/2`.
      shell.info("#{run["workflow"]} #{run["workflow_name"]} · lane #{run["lane"]}")
      shell.info("`noetic-harness workflows --show #{run["workflow"]}` is the steps you owe.")
      shell.info("opened #{run["id"]}")
    else
      {:error, message} -> abort(shell, message)
    end
  end

  defp record(shell, opts) do
    with {:ok, id} <- resolve(opts),
         {:ok, run} <-
           Run.record(id,
             step: opts[:step],
             outcome: opts[:outcome],
             evidence: Keyword.get_values(opts, :evidence),
             artifacts: Keyword.get_values(opts, :artifact),
             note: opts[:note],
             agent: opts[:agent]
           ) do
      entry = List.last(run["steps"])
      # The run id, always. `recorded implement: done` was the whole of this
      # line, and it was true while the evidence went into a run a test had
      # opened and was about to delete. A ledger command that does
      # not say what it wrote to cannot be checked by the person reading it.
      shell.info("recorded #{entry["step"]}: #{entry["outcome"]}  → #{id}")
      Enum.each(entry["evidence"], &shell.info("  · #{&1}"))
      report(shell, id)
    else
      {:error, message} -> abort(shell, message)
    end
  end

  defp status(shell, opts) do
    case resolve(opts) do
      {:ok, id} -> report(shell, id)
      {:error, message} -> abort(shell, message)
    end
  end

  defp finish(shell, opts) do
    with {:ok, id} <- resolve(opts),
         {:ok, run} <-
           Run.finish(id,
             abandon: opts[:abandon],
             accept_partial: opts[:accept_partial],
             paths: paths(opts)
           ) do
      shell.info("#{run["id"]} — #{run["status"]}")

      if gates = run["gates"] do
        shell.info("")
        shell.info(gates["summary"])
        # What a WF-021 worker copies into its handoff, and what merge-check
        # compares S with: printed, so the copy is made from this
        # line rather than from a guess at `git rev-parse HEAD` a commit later.
        shell.info("")

        shell.info(
          "ran at #{gates["head"] || "(git could not say which commit)"} in " <>
            "#{gates["seconds"]}s, over #{length(gates["paths"] || [])} path(s): " <>
            "#{gates["paths_from"]}"
        )
      end

      case run["acknowledged"] do
        %{"partial_accepted" => reason} ->
          shell.info("")
          shell.info("finished on a partial lane, on the record: #{reason}")

        %{"reason" => reason} ->
          shell.info("")
          shell.info("abandoned: #{reason}")

        _ ->
          :ok
      end
    else
      {:error, message} -> abort(shell, message)
    end
  end

  # How much of this run a trusted key signed, checked rather than
  # read off the records. Silent for a run with no signed step, which is every
  # run on a machine with no `aw` identity.
  # The decisions a model took part in, beside the run. Only
  # identifiers are recorded, so only identifiers can be printed.
  defp decisions(shell, run) do
    case List.wrap(run["decisions"]) do
      [] ->
        :ok

      decisions ->
        shell.info("  decisions #{length(decisions)}")

        Enum.each(decisions, fn d ->
          shell.info(
            "    #{d["question"]} → #{d["action"]}  (#{d["provider"]}/#{d["model"]}, " <>
              "policy #{d["policy_version"]}, projection #{String.slice(to_string(d["projection_hash"]), 0, 12)})"
          )
        end)
    end
  end

  defp attestation(shell, run) do
    case Run.attestation(run["id"]) do
      {:ok, %{duplicate_keys: true}} ->
        shell.info(
          "  signed  none: the file gives some object a key twice, so no record is attested"
        )

      {:ok, %{attested: 0}} ->
        :ok

      {:ok, %{steps: steps, attested: attested, stop: stop}} ->
        shell.info(
          "  signed  #{attested} of #{steps} step(s) attested" <>
            case stop do
              nil -> ""
              true -> " · the stop is attested"
              false -> " · the stop is NOT attested"
            end <>
            " — this workspace's key, not a person"
        )

      {:error, _} ->
        :ok
    end
  end

  # Only when there is something to say. A run nobody dispatched from has spent
  # nothing, and a line of zeroes on every `--status` teaches people to skip
  # the block that will one day matter.
  defp budget(shell, run) do
    spent = Run.spent(run["id"])
    depth = Run.depth(run["id"])

    if spent.elapsed_ms > 0 or depth > 0 do
      shell.info("")

      shell.info(
        "  budget  depth #{depth}/#{Dispatcher.depth_ceiling()}" <>
          " · #{div(spent.elapsed_ms, 1000)}s of " <>
          "#{div(Dispatcher.wall_clock_ceiling(), 1000)}s" <>
          cost_line(spent)
      )

      if run["parent_run"], do: shell.info("          dispatched by #{run["parent_run"]}")
    end

    sessions(shell, run)
  end

  # What the *sessions* cost, printed beside the dispatch budget and never
  # mixed into it. A dispatch is an agent call the harness bounded; a session
  # is somebody working here, which it does not bound and until an earlier change
  # could not see at all — 21 runs, zero dispatches, $0.00.
  #
  # Printed even when it is zero, and that is the point: a `SessionEnd` hook
  # that silently stopped working is indistinguishable from one that was never
  # installed, and this is the line where the difference shows.
  defp sessions(shell, run) do
    observed = Run.observed(run["id"])
    tokens = observed["tokens"]

    counted =
      Usage.counters()
      |> Enum.map(fn key ->
        {key |> String.replace("_tokens", "") |> String.replace("_input", ""), tokens[key] || 0}
      end)
      |> Enum.map(fn {label, value} -> "#{label} #{thousands(value)}" end)
      |> Enum.join(" · ")

    shell.info("")

    case observed["sessions"] do
      0 ->
        shell.info(
          "  tokens  nothing recorded. `noetic-harness usage --record`, or the SessionEnd hook"
        )

      n ->
        shell.info("  tokens  #{n} session(s), #{observed["messages"]} message(s)")
        shell.info("          #{counted}")
    end
  end

  defp thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1 ")
    |> String.reverse()
  end

  defp thousands(other), do: to_string(other)

  defp cost_line(%{cost_known?: true} = spent),
    do: " · $#{:erlang.float_to_binary(spent.cost_usd, decimals: 2)}"

  # §32: "at least" is the honest word. One adapter in the chain reported no
  # price, so the figure is a lower bound and the cost ceiling does not bind.
  defp cost_line(spent),
    do:
      " · at least $#{:erlang.float_to_binary(spent.cost_usd, decimals: 2)}" <>
        " (one adapter reported no price, so the cost ceiling does not bind)"

  defp report(shell, id) do
    case Run.status(id) do
      {:error, message} ->
        abort(shell, message)

      {:ok, state} ->
        run = state.run
        shell.info("")
        shell.info("#{run["id"]}  [#{run["status"]}]")
        shell.info("  #{run["workflow"]} #{run["workflow_name"]} · lane #{run["lane"]}")
        shell.info("  #{run["title"]}")

        if stopped = run["stopped"] do
          shell.info("")
          shell.info("  STOPPED by #{stopped["by"]} at #{stopped["at"]}: #{stopped["reason"]}")
          shell.info("  A stop is not a close. `--finish` refuses this run.")
        end

        budget(shell, run)
        attestation(shell, run)
        decisions(shell, run)
        shell.info("")

        Enum.each(state.workflow["steps"], fn step ->
          entry = Enum.reverse(run["steps"]) |> Enum.find(&(&1["step"] == step["id"]))

          mark =
            cond do
              entry && entry["outcome"] == "done" -> "done      "
              entry -> String.pad_trailing(entry["outcome"], 10)
              step["optional"] -> "optional  "
              true -> "—         "
            end

          shell.info("  #{mark} #{step["id"]}  #{step["name"]}")
        end)

        if state.outstanding != [] do
          shell.info("")
          shell.info("outstanding: #{Enum.join(state.outstanding, ", ")}")
        end

        if state.attention != [] do
          shell.info("")

          Enum.each(state.attention, fn {step, outcome} ->
            shell.info("needs attention: #{step} is #{outcome}")
          end)
        end

        finish_attempts(shell, run["finish_attempts"] || [])
    end
  end

  defp finish_attempts(_shell, []), do: :ok

  defp finish_attempts(shell, attempts) do
    shell.info("")

    shell.info(
      "finish attempts: #{length(attempts)} — " <>
        Enum.map_join(attempts, ", ", &"#{&1["lane"]} #{&1["status"]}")
    )
  end

  defp resolve(opts) do
    cond do
      id = opts[:run] ->
        {:ok, id}

      true ->
        case Run.current() do
          {:ok, run} -> {:ok, run["id"]}
          {:error, message} -> {:error, message}
          :error -> {:error, "no open run. `noetic-harness run --start <WF-0xx> --title \"...\"`"}
        end
    end
  end

  defp paths(opts) do
    case opts[:paths] do
      nil -> nil
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp abort(shell, message) do
    shell.error(message)
    exit({:shutdown, 1})
  end
end
