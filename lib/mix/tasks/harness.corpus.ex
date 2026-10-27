defmodule Mix.Tasks.Harness.Corpus do
  @moduledoc """
  The router, measured against the labelled routing corpus.

      noetic-harness corpus                 both modes, beside the majority-class baseline
      noetic-harness corpus --json
      noetic-harness corpus --failures      Conductor.classify/1 against failures.jsonl
      noetic-harness corpus --split tune    one half of the routing corpus (tune | heldout | all)
      noetic-harness corpus --misroutes     the rows the router gets wrong — refused on `heldout`

  `--split` is an earlier change's discipline: a change to `signals.json` is made
  against `tune` and reported on `heldout`, and `--misroutes` will not print
  the held-out half's rows, because reading them is how a held-out set stops
  being one.

  The corpus is `.agents/decisions/corpus/routing.jsonl`; its README is the
  labelling procedure. Until its rows are human-confirmed, these numbers are
  agreement with model raters, and the report says how many rows are
  confirmed so that nobody reads it as more.
  """
  @shortdoc "Measure the router against the labelled corpus"

  use Mix.Task

  @requirements ["compile"]
  alias Noetic.Harness.{Corpus, Loader, Router}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          json: :boolean,
          failures: :boolean,
          split: :string,
          misroutes: :boolean
        ]
      )

    shell = Mix.shell()

    if opts[:failures], do: failures(shell, opts), else: routing(shell, opts)
  end

  defp failures(shell, opts) do
    r = Corpus.measure_failures(Corpus.rows(Corpus.failures_path()))

    if opts[:json] do
      shell.info(
        Loader.pretty!(%{
          r
          | confusions:
              Enum.map(r.confusions, fn {{l, g}, c} ->
                %{"label" => l, "got" => g, "count" => c}
              end)
        })
      )
    else
      shell.info(
        "#{r.rows} rows · #{r.human_confirmed} human-confirmed · " <>
          "#{r.contested} contested by the third rater"
      )

      shell.info(
        "classify/1: #{pct(r.accuracy)} (#{pct(r.lenient)} accepting `also`) · " <>
          "always #{r.baseline.label}: #{pct(r.baseline.accuracy)}"
      )

      shell.info(
        "fired on #{r.fired} rows, right on #{pct(r.precision)} of them · " <>
          "#{r.false_alarms} false alarms · #{r.misses} misses · #{r.wrong_class} wrong class · " <>
          "#{r.ambiguous} rows match two or more patterns"
      )

      shell.info("  recall")

      for {label, %{rows: n, recall: rec}} <- Enum.sort_by(r.recall, fn {_, v} -> -v.rows end) do
        shell.info("    #{label}  #{String.pad_leading(to_string(n), 4)} rows  #{pct(rec)}")
      end

      shell.info("  errors (labelled → classified)")

      for {{label, got}, count} <- r.confusions,
          do: shell.info("    #{label} → #{got}  #{count}")
    end
  end

  defp routing(shell, opts) do
    half = half(opts[:split])
    rows = Corpus.split(Corpus.rows(), half)

    if opts[:misroutes] do
      misroutes(shell, rows, half)
    else
      report_routing(shell, rows, opts, half)
    end
  end

  defp half(nil), do: :all
  defp half("all"), do: :all
  defp half("tune"), do: :tune
  defp half("heldout"), do: :heldout
  defp half(other), do: Mix.raise("--split is tune, heldout or all, not #{inspect(other)}")

  defp misroutes(_shell, _rows, :heldout),
    do:
      Mix.raise(
        "--misroutes is refused on the held-out half: reading it is how it stops being held out"
      )

  defp misroutes(shell, rows, _half) do
    for mode <- [:title, :bead], row <- rows do
      {:ok, route} = Router.route(Corpus.work(row, mode))
      got = route.workflow && route.workflow["id"]

      if got != row["label"] do
        shell.info(
          "#{mode}  #{row["id"]}  #{row["label"]} → #{got || "none"} (#{route.confidence})  " <>
            String.slice(row["title"], 0, 90)
        )
      end
    end
  end

  defp report_routing(shell, rows, opts, half) do
    reports = Enum.map([:title, :bead], &Corpus.measure(rows, &1))

    if opts[:json] do
      shell.info(Loader.pretty!(Enum.map(reports, &jsonable/1)))
    else
      [first | _] = reports
      if half != :all, do: shell.info("split: #{half}")

      shell.info(
        "#{first.rows} rows · #{first.human_confirmed} human-confirmed · " <>
          "#{first.contested} contested by the third rater — " <>
          if(first.human_confirmed == first.rows,
            do: "these are measurements of correctness",
            else:
              "the rest are model-rated, so this is agreement with the raters, not correctness"
          )
      )

      shell.info(
        "majority class #{first.baseline.workflow} would score #{pct(first.baseline.accuracy)}"
      )

      Enum.each(reports, &report(shell, &1))
    end
  end

  defp report(shell, r) do
    shell.info("")
    shell.info("router, #{r.mode}: #{pct(r.accuracy)}")

    for {confidence, %{rows: n, accuracy: a}} <- Enum.sort(r.by_confidence) do
      shell.info(
        "  #{String.pad_trailing(to_string(confidence), 7)} #{String.pad_leading(to_string(n), 4)} rows  #{pct(a)} right"
      )
    end

    shell.info("  recall")

    for {label, %{rows: n, recall: rec}} <- Enum.sort_by(r.recall, fn {_, v} -> -v.rows end) do
      shell.info("    #{label}  #{String.pad_leading(to_string(n), 4)} rows  #{pct(rec)}")
    end

    shell.info("  most frequent confusions (labelled → routed)")

    for {{label, got}, count} <- r.confusions do
      shell.info("    #{label} → #{got || "none"}  #{count}")
    end
  end

  defp pct(nil), do: "n/a"
  defp pct(rate), do: "#{Float.round(rate * 100, 1)}%"

  defp jsonable(r) do
    %{
      "mode" => Atom.to_string(r.mode),
      "rows" => r.rows,
      "human_confirmed" => r.human_confirmed,
      "contested" => r.contested,
      "accuracy" => r.accuracy,
      "baseline" => %{"workflow" => r.baseline.workflow, "accuracy" => r.baseline.accuracy},
      "recall" =>
        Map.new(r.recall, fn {k, v} -> {k, %{"rows" => v.rows, "recall" => v.recall}} end),
      "confusions" =>
        Enum.map(r.confusions, fn {{l, g}, c} -> %{"label" => l, "routed" => g, "count" => c} end),
      "by_confidence" =>
        Map.new(r.by_confidence, fn {k, v} ->
          {Atom.to_string(k), %{"rows" => v.rows, "accuracy" => v.accuracy}}
        end)
    }
  end
end
