defmodule Mix.Tasks.Harness.Telemetry do
  @shortdoc "What the development system keeps doing wrong, counted"

  @moduledoc """
  The input to WF-020: gate outcomes, run outcomes, step retries and memory
  scopes, counted across `.agents/runs/` and `.agents/memory/`.

      noetic-harness telemetry                     # the counts
      noetic-harness telemetry --clusters          # the shapes seen three or more times
      noetic-harness telemetry --since 2026-09-01
      noetic-harness telemetry --json              # for a diff, or for a fitness map
      noetic-harness telemetry --metrics           # the rates, higher is better

  It reports; it does not instrument. Everything counted here was already
  written down by `noetic-harness run`.

  **A cluster needs a population.** `--clusters` refuses below ten runs and
  says how many more it needs, because three failures out of three observations
  is not a weakness cluster — it is all the data there is, and opening an
  evolution experiment against it optimises the measure of the process rather
  than the work.

  ## Options

    * `--clusters` — the weakness clusters instead of the raw counts
    * `--baseline` — take the frozen efficiency baseline, once
    * `--file-beads` — file a bead for each cluster that has none (`--dry-run` first)
    * `--threshold N` — how many of the same shape make a cluster (default 3)
    * `--min-population N` — runs required before clustering (default 10)
    * `--since <iso8601>` — only runs and records from this date onward
    * `--metrics` — the rates, oriented so higher is better
    * `--json` — the whole summary as JSON
  """

  use Mix.Task

  alias Noetic.Harness.{Beads, Loader, Telemetry}

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          clusters: :boolean,
          threshold: :integer,
          min_population: :integer,
          since: :string,
          metrics: :boolean,
          baseline: :boolean,
          file_beads: :boolean,
          dry_run: :boolean,
          parent: :string,
          json: :boolean
        ]
      )

    shell = Mix.shell()
    summary = Telemetry.collect(since: opts[:since])

    cond do
      opts[:json] -> shell.info(Loader.pretty!(summary))
      opts[:baseline] -> baseline(shell, summary)
      opts[:file_beads] -> file_beads(shell, summary, opts)
      opts[:metrics] -> metrics(shell, summary) && costs(shell, summary)
      opts[:clusters] -> clusters(shell, summary, opts)
      true -> counts(shell, summary)
    end
  end

  defp counts(shell, summary) do
    population = summary["population"]

    shell.info("population")
    shell.info("  runs                 #{population["runs"]}")
    shell.info("  memory records       #{population["memory_records"]}")
    shell.info("  gate observations    #{population["gate_observations"]}")
    shell.info("  step observations    #{population["step_observations"]}")
    shell.info("  session observations #{population["session_observations"]}")

    section(shell, "runs by status", summary["runs"]["by_status"])

    if summary["runs"]["partial_accepted"] > 0 do
      shell.info(
        "  #{summary["runs"]["partial_accepted"]} finished on a partial lane, on the record"
      )
    end

    shell.info("")
    shell.info("gates")

    if summary["gates"] == %{} do
      shell.info("  nothing recorded yet — a run that finishes writes its gate results here")
    else
      Enum.each(Enum.sort(summary["gates"]), fn {id, outcomes} ->
        shell.info("  #{String.pad_trailing(id, 20)} #{render(outcomes)}")
      end)
    end

    section(shell, "lanes", Map.new(summary["lanes"] || %{}, fn {k, v} -> {k, render(v)} end))

    shell.info("")
    shell.info("steps that took more than one attempt")

    retried =
      (summary["steps"] || %{})
      |> Enum.filter(fn {_key, stats} -> stats["worst_run"] > 1 end)
      |> Enum.sort_by(fn {_key, stats} -> -stats["worst_run"] end)

    if retried == [] do
      shell.info("  none")
    else
      Enum.each(retried, fn {key, stats} ->
        shell.info(
          "  #{String.pad_trailing(key, 28)} worst run #{stats["worst_run"]} attempts; " <>
            "#{stats["attempts"]} over #{stats["runs"]} run(s)  #{render(stats["by_outcome"])}"
        )
      end)
    end

    section(shell, "memory scopes", summary["memory"])
    usage(shell, summary["usage"])
    hooks(shell, summary["hooks"])
    unverified(shell, summary)
  end

  # What the work cost, beside what it did. Printed even at zero, because a
  # `SessionEnd` hook that silently stopped working is indistinguishable from
  # one that was never installed.
  defp usage(shell, nil), do: shell

  defp usage(shell, usage) do
    shell.info("")
    shell.info("what the sessions cost")

    if usage["sessions"] == 0 do
      shell.info(
        "  nothing recorded yet — `noetic-harness usage --record`, or the SessionEnd hook"
      )
    else
      shell.info(
        "  #{usage["sessions"]} session(s) over #{usage["runs_with_usage"]} run(s), " <>
          "#{grouped(usage["messages"])} message(s)"
      )

      for key <- Noetic.Harness.Usage.counters() do
        shell.info("  #{String.pad_trailing(key, 28)} #{grouped(usage["tokens"][key])}")
      end

      shell.info(
        "  #{String.pad_trailing("thinking_tokens", 28)} #{grouped(usage["thinking_tokens"])}"
      )

      usage["tools"]
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.take(5)
      |> case do
        [] ->
          :ok

        top ->
          shell.info(
            "  busiest tools: " <>
              Enum.map_join(top, ", ", fn {name, n} -> "#{name} #{grouped(n)}" end)
          )
      end
    end
  end

  # What the harness costs the session that carries it. Printed with the
  # ceiling beside the median, because a latency without the budget it is
  # measured against is a number nobody can act on.
  defp hooks(shell, nil), do: shell

  defp hooks(shell, hooks) do
    shell.info("")
    shell.info("what the harness itself costs")

    events = hooks["events"] || %{}

    if events == %{} do
      shell.info("  nothing recorded on this machine yet — #{hooks["path"]}")
      shell.info("  the hooks write it themselves; this is not measured, which is not the")
      shell.info("  same as fast")
    else
      Enum.each(Noetic.Harness.Hooks.events(), fn event ->
        case events[event] do
          nil -> :ok
          stats -> hook_line(shell, event, stats)
        end
      end)

      unbounded =
        events |> Map.values() |> Enum.map(fn stats -> stats["unbounded"] end) |> Enum.sum()

      if unbounded > 0 do
        shell.info(
          "  #{unbounded} observation(s) ran with no budget enforced: `timeout` was not on " <>
            "the PATH, so the hook could not be bounded and does not claim it was"
        )
      end

      saturated =
        events |> Map.values() |> Enum.map(fn stats -> stats["saturated"] || 0 end) |> Enum.sum()

      if saturated > 0 do
        shell.info(
          "  #{saturated} observation(s) excluded: recorded while this machine's load average " <>
            "was above #{Noetic.Harness.Hooks.load_ceiling()}, which measures the machine " <>
            "rather than the hook"
        )
      end

      if hooks["unreadable"] > 0 do
        shell.info("  #{hooks["unreadable"]} line(s) in the log would not parse")
      end
    end
  end

  defp hook_line(shell, event, stats) do
    verdict =
      cond do
        stats["over_ceiling"] -> "  median OVER the #{stats["ceiling"]} ms ceiling"
        stats["checked"] -> "  median under #{stats["ceiling"]} ms"
        true -> "  not checked: #{Noetic.Harness.Hooks.min_observations()} observations needed"
      end

    shell.info(
      "  #{String.pad_trailing(event, 14)} n=#{String.pad_trailing(to_string(stats["count"]), 4)}" <>
        " p50 #{grouped(stats["p50"])} ms   p95 #{grouped(stats["p95"])} ms   " <>
        "max #{grouped(stats["max"])} ms" <> verdict
    )

    outcomes =
      stats["outcomes"]
      |> Enum.reject(fn {outcome, _n} -> outcome == "injected" end)
      |> Enum.sort_by(fn {_o, n} -> -n end)

    if outcomes != [] do
      shell.info(
        "  #{String.duplicate(" ", 14)}" <>
          Enum.map_join(outcomes, ", ", fn {outcome, n} -> "#{outcome} #{n}" end) <>
          silent_note(event, outcomes)
      )
    end

    # The split by path, printed whenever there is more than
    # one, because the aggregate above is an average over two populations that
    # differ by an order of magnitude and says nothing true about either.
    split = stats["via"] || %{}

    if map_size(split) > 1 do
      for via <- ~w(resident cold unknown), row = split[via] do
        verdict =
          cond do
            row["over_ceiling"] -> "  OVER the #{row["ceiling"]} ms ceiling"
            row["checked"] -> "  under #{row["ceiling"]} ms"
            row["ceiling"] -> "  not checked"
            true -> "  no ceiling written for this path"
          end

        shell.info(
          "  #{String.duplicate(" ", 14)}via #{String.pad_trailing(via, 9)}" <>
            "n=#{String.pad_trailing(to_string(row["count"]), 4)} " <>
            "p50 #{grouped(row["p50"])} ms" <> verdict
        )
      end
    end
  end

  defp grouped(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1 ")
    |> String.reverse()
  end

  defp grouped(other), do: to_string(other)

  defp clusters(shell, summary, opts) do
    options =
      [threshold: opts[:threshold], min_population: opts[:min_population]]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Telemetry.clusters(summary, options) do
      {:insufficient, message} ->
        shell.info("not enough evidence yet")
        shell.info("")
        shell.info("  " <> message)

      {:ok, []} ->
        shell.info("no weakness cluster: nothing has failed the same way often enough.")

      {:ok, clusters} ->
        # Actionable first, and the rest under a heading that
        # says what they are — a cluster that names no change passed the
        # population floor and taught nothing, and printing it beside one that
        # does teaches a reader to skim both.
        {actionable, artifacts} = Enum.split_with(clusters, & &1["actionable"])

        Enum.each(actionable, fn cluster ->
          shell.info("")
          shell.info("#{cluster["shape"]}  #{cluster["subject"]}")
          shell.info("  #{cluster["count"]} of #{cluster["of"]}")
          shell.info("  #{cluster["reading"]}")
          shell.info("  → #{cluster["change"]}")
        end)

        if actionable == [] do
          shell.info("")
          shell.info("no cluster names a change. That is a result, not an empty one:")
          shell.info("  everything above the threshold is a property of the population.")
        end

        if artifacts != [] do
          shell.info("")
          shell.info("above the threshold, naming no change:")

          Enum.each(artifacts, fn cluster ->
            shell.info("")

            shell.info(
              "  #{cluster["shape"]}  #{cluster["subject"]}  " <>
                "(#{cluster["count"]} of #{cluster["of"]})"
            )

            shell.info("  #{cluster["reading"]}")
          end)
        end

        shell.info("")
        shell.info("WF-020 is the workflow for these: `noetic-harness workflows --show WF-020`.")
    end

    unverified(shell, summary)
  end

  # A weakness the harness detected used to survive only as long
  # as somebody read this output.
  defp file_beads(shell, summary, opts) do
    if Noetic.Harness.Integrations.enabled?("beads"),
      do: file_clusters(shell, summary, opts),
      else:
        shell.info(Noetic.Harness.Integrations.off("beads") <> ": no cluster is filed as a bead")
  end

  defp file_clusters(shell, summary, opts) do
    case Telemetry.clusters(summary, opts) do
      {:insufficient, message} ->
        shell.info(message)

      {:ok, clusters} ->
        population = summary["population"] || %{}

        Enum.each(clusters, fn cluster ->
          label = "#{cluster["shape"]} on #{cluster["subject"]}"

          case Beads.fileable(cluster, population: population) do
            {:error, reason} ->
              shell.info("skipped  #{label}")
              shell.info("         #{reason}")

            {:ok, attrs} ->
              if opts[:dry_run] do
                # Stops here, before anything is written. The key is printed
                # because it is what a reader needs to check by hand: two
                # clusters sharing one would mean one silent bead.
                shell.info("would file  #{label}")
                shell.info("            #{attrs.key}")
              else
                write_bead(shell, cluster, population, label, opts)
              end
          end
        end)
    end
  end

  defp write_bead(shell, cluster, population, label, opts) do
    case Beads.file(cluster, population: population, parent: opts[:parent]) do
      {:filed, id} ->
        shell.info("filed    #{id}  #{label}")

      {:known, id} ->
        shell.info("known    #{id}  #{label}")

      {:returned, id} ->
        shell.info("RETURNED #{id}  #{label}")
        shell.info("         it was closed and the weakness came back; noted on the bead")

      {:error, reason} ->
        shell.info("refused  #{label}")
        shell.info("         #{reason}")
    end
  end

  defp baseline(shell, summary) do
    case Telemetry.take_baseline(summary) do
      {:ok, document} ->
        shell.info("baseline written to #{Path.relative_to_cwd(Telemetry.baseline_path())}")

        shell.info(
          "  #{map_size(document["metrics"])} metric(s) over " <>
            "#{get_in(document, ["population", "beads_measured"])} measured bead(s)"
        )

        if document["provisional"] do
          shell.info("")

          shell.info(
            "  PROVISIONAL: below the population floor. " <> document["provisional_note"]
          )
        end

        shell.info("")
        shell.info("It is frozen. Re-taking it means deleting the file in a commit with a")
        shell.info("reason — a diff a reviewer can see, rather than a number that quietly")
        shell.info("became easier to beat.")

      {:error, message} ->
        shell.info(message)
    end
  end

  defp costs(shell, summary) do
    # Printed beside the rates and labelled the other way round,
    # because a reader who sees two lists of numbers and one legend will read
    # the second list with the first one's legend.
    case Telemetry.efficiency(summary) do
      empty when empty == %{} ->
        shell.info("")
        shell.info("no cost has a denominator yet: no closed bead has a recorded session.")

      costs ->
        measured = get_in(summary, ["beads", "measured"]) || 0
        closed = get_in(summary, ["beads", "closed"]) || 0

        shell.info("")

        shell.info(
          "costs — lower is better, over #{measured} measured bead(s) of #{closed} closed"
        )

        Enum.each(Enum.sort(costs), fn {name, value} ->
          shell.info("  #{String.pad_trailing(name, 32)} #{format_cost(value)}")
        end)

        if measured < 10 do
          shell.info("")
          shell.info("  #{measured} measured bead(s) is below the population floor. These are")
          shell.info("  true and they are not yet a baseline anyone should optimise against.")
        end
    end
  end

  # A token count and a ratio do not want the same precision, and rounding a
  # nine-figure number to three decimals prints noise.
  defp format_cost(value) when value >= 1000, do: value |> round() |> Integer.to_string()
  defp format_cost(value), do: value |> Float.round(3) |> Float.to_string()

  defp metrics(shell, summary) do
    case Telemetry.metrics(summary) do
      empty when empty == %{} ->
        shell.info("no rate has any observation behind it yet.")

      metrics ->
        shell.info("rates — higher is better")

        Enum.each(Enum.sort(metrics), fn {name, value} ->
          shell.info("  #{String.pad_trailing(name, 24)} #{Float.round(value, 3)}")
        end)

        shell.info("")
        shell.info("`--json` twice, around an experiment, is a fitness map for a candidate.")
    end

    unverified(shell, summary)
  end

  defp section(_shell, _title, nil), do: :ok
  defp section(_shell, _title, map) when map == %{}, do: :ok

  defp section(shell, title, map) do
    shell.info("")
    shell.info(title)

    Enum.each(Enum.sort(map), fn {key, value} ->
      shell.info("  #{String.pad_trailing(to_string(key), 20)} #{value}")
    end)
  end

  defp render(counts) when is_map(counts) do
    counts
    |> Enum.sort()
    |> Enum.map_join("  ", fn {outcome, count} -> "#{outcome} #{count}" end)
  end

  defp render(other), do: to_string(other)

  defp unverified(_shell, %{"unverified" => []}), do: :ok

  defp unverified(shell, summary) do
    shell.info("")
    shell.info("unverified:")
    Enum.each(summary["unverified"], &shell.info("  - #{&1}"))
  end

  # A silent prompt hook is, most often, the router answering
  # `:low` — too thin to place, so the hook injects nothing rather than a
  # guess — and its only trace was the word "silent". An empty prompt and a
  # router error are silent too, and the log does not record which, so this
  # names all three rather than claiming one.
  defp silent_note("user_prompt", outcomes) do
    if List.keymember?(outcomes, "silent", 0),
      do: " (silent: a route too thin to place, an empty prompt, or a router error)",
      else: ""
  end

  defp silent_note(_event, _outcomes), do: ""
end
