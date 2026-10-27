defmodule Noetic.Harness.Corpus do
  @moduledoc """
  How often the router is right, measured, against the labelled
  corpus in `.agents/decisions/corpus/routing.jsonl`.

  The premise of the whole System One epic was that the router is bad, on the
  strength of one observed misroute. This repository's own rule — ten
  observations before a cluster is a family — applies to that premise too, so
  before any model is offered as a second opinion the deterministic router is
  measured, and measured against the dumbest thing that could replace it: the
  **majority class**, always answering the most common workflow. A router that
  does not beat that is not routing.

  Two ways, because the router is used two ways:

    * `:title` — the title alone, which is what the prompt hook routes;
    * `:bead` — title, body and the bead's type as a declared kind, which is
      what `noetic-harness route --bead` routes.

  **What the labels are.** Two blind raters and an adjudicator, all models,
  following the written procedure in the corpus README; κ is reported with
  the corpus. Rows are `human_confirmed: false` until a person confirms them,
  and every report says how many are — a number measured against unconfirmed
  labels is agreement with the raters, not correctness, and says so.

  A **third** blind rater, on a model family neither of the first two used,
  relabelled every row afterwards (in place of the person the
  bead asked for and nobody could be). A row is `contested` when that rater's
  answer is none of the row's recorded readings. Every report prints the
  count, and a change that wins only on contested rows has won on the rows
  the labels are least sure of.
  """

  alias Noetic.Harness.{Conductor, Router}

  @doc "The corpus file."
  @spec path() :: String.t()
  def path, do: Noetic.Harness.agents_path(["decisions", "corpus", "routing.jsonl"])

  @doc "Every row, decoded."
  @spec rows(String.t()) :: [map()]
  def rows(file \\ path()) do
    file
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    # JSON, not :json: Erlang decodes null to the atom :null, which is truthy
    # and not nil, so a row with no body would reach the router as a body.
    |> Enum.map(&JSON.decode!/1)
  end

  @doc """
  One half of a corpus, by a hash of each row's id.

  `:tune` is the half a change to `signals.json` may be made against, and
  `:heldout` the half it is reported on. The split is by sha256 rather than
  by position or by a shuffle, so it is one-way in the sense the environment
  sets are: a row cannot be moved to the half that flatters a change, and a
  row appended later lands in a half that was fixed before anybody saw it.
  """
  @spec split([map()], :tune | :heldout | :all) :: [map()]
  def split(rows, :all), do: rows

  def split(rows, half) when half in [:tune, :heldout] do
    want = if half == :tune, do: 0, else: 1

    Enum.filter(rows, fn row ->
      <<value::unsigned-32, _::binary>> = :crypto.hash(:sha256, row["id"])
      rem(value, 2) == want
    end)
  end

  @doc """
  Route every row and compare. Returns accuracy for the router in `mode`, the
  majority-class baseline, per-label recall for labels with at least five
  rows, the most frequent confusions, and how the router's own confidence
  lines up with being right.
  """
  @spec measure([map()], :title | :bead) :: map()
  def measure(rows, mode) do
    routed =
      Enum.map(rows, fn row ->
        {:ok, route} = Router.route(work(row, mode))
        got = route.workflow && route.workflow["id"]
        %{label: row["label"], got: got, confidence: route.confidence}
      end)

    n = length(routed)

    {majority, majority_n} =
      routed |> Enum.frequencies_by(& &1.label) |> Enum.max_by(&elem(&1, 1))

    %{
      mode: mode,
      rows: n,
      human_confirmed: Enum.count(rows, &(&1["human_confirmed"] == true)),
      contested: Enum.count(rows, &(&1["contested"] == true)),
      accuracy: rate(Enum.count(routed, &(&1.got == &1.label)), n),
      baseline: %{workflow: majority, accuracy: rate(majority_n, n)},
      recall:
        routed
        |> Enum.group_by(& &1.label)
        |> Enum.filter(fn {_label, group} -> length(group) >= 5 end)
        |> Map.new(fn {label, group} ->
          {label,
           %{
             rows: length(group),
             recall: rate(Enum.count(group, &(&1.got == label)), length(group))
           }}
        end),
      confusions:
        routed
        |> Enum.reject(&(&1.got == &1.label))
        |> Enum.frequencies_by(&{&1.label, &1.got})
        |> Enum.sort_by(fn {_pair, count} -> -count end)
        |> Enum.take(8),
      by_confidence:
        routed
        |> Enum.group_by(& &1.confidence)
        |> Map.new(fn {confidence, group} ->
          {confidence,
           %{
             rows: length(group),
             accuracy: rate(Enum.count(group, &(&1.got == &1.label)), length(group))
           }}
        end)
    }
  end

  # ---- failure evidence -----------------------------------------

  @doc "The failure-evidence corpus file."
  @spec failures_path() :: String.t()
  def failures_path, do: Noetic.Harness.agents_path(["decisions", "corpus", "failures.jsonl"])

  @doc """
  `Conductor.classify/1` against the labelled failure evidence.

  Three ways to be wrong, counted apart because they cost different things:

    * **false alarm** — the label is `unclassified` and a regex fired, so a
      step that did not fail in that way is routed to a role;
    * **miss** — the label is a class and nothing fired, so the failure
      routes nowhere, which `classify/1` says aloud;
    * **wrong class** — both named a class and they differ.

  `accuracy` is strict against the label; `lenient` also accepts the row's
  `also`, the second class the raters agreed genuinely applies. `ambiguous`
  counts rows two or more patterns match, which `classify/1` settles by file
  order. `precision` is the one to read first: how often a regex that fired
  was right, since a fired regex is what sends work to someone.
  """
  @spec measure_failures([map()]) :: map()
  def measure_failures(rows) do
    patterns = patterns()

    scored =
      Enum.map(rows, fn row ->
        got =
          case Conductor.classify(row["evidence"]) do
            {:ok, class} -> class["id"]
            :none -> "unclassified"
          end

        matching = Enum.count(patterns, fn {_id, re} -> Regex.match?(re, row["evidence"]) end)
        %{id: row["id"], label: row["label"], also: row["also"], got: got, matching: matching}
      end)

    n = length(scored)
    fired = Enum.reject(scored, &(&1.got == "unclassified"))

    {majority, majority_n} =
      scored |> Enum.frequencies_by(& &1.label) |> Enum.max_by(&elem(&1, 1))

    %{
      rows: n,
      human_confirmed: Enum.count(rows, &(&1["human_confirmed"] == true)),
      contested: Enum.count(rows, &(&1["contested"] == true)),
      accuracy: rate(Enum.count(scored, &(&1.got == &1.label)), n),
      lenient: rate(Enum.count(scored, &(&1.got in [&1.label, &1.also])), n),
      baseline: %{label: majority, accuracy: rate(majority_n, n)},
      fired: length(fired),
      precision: rate(Enum.count(fired, &(&1.got in [&1.label, &1.also])), length(fired)),
      false_alarms:
        Enum.count(scored, &(&1.label == "unclassified" and &1.got != "unclassified")),
      misses: Enum.count(scored, &(&1.label != "unclassified" and &1.got == "unclassified")),
      wrong_class:
        Enum.count(
          scored,
          &(&1.label != "unclassified" and &1.got not in ["unclassified", &1.label, &1.also])
        ),
      ambiguous: Enum.count(scored, &(&1.matching > 1)),
      recall:
        scored
        |> Enum.group_by(& &1.label)
        |> Map.new(fn {label, group} ->
          {label,
           %{
             rows: length(group),
             recall: rate(Enum.count(group, &(&1.got == label)), length(group))
           }}
        end),
      confusions:
        scored
        |> Enum.reject(&(&1.got in [&1.label, &1.also]))
        |> Enum.frequencies_by(&{&1.label, &1.got})
        |> Enum.sort_by(fn {pair, count} -> {-count, pair} end),
      errors: scored |> Enum.reject(&(&1.got in [&1.label, &1.also])) |> Enum.map(& &1.id)
    }
  end

  defp patterns do
    with {:ok, policy} <- Conductor.policy(),
         classes when is_list(classes) <- policy["classes"] do
      for %{"match" => m, "id" => id} when is_binary(m) <- classes,
          {:ok, re} <- [Regex.compile(m, "i")],
          do: {id, re}
    else
      _ -> []
    end
  end

  @doc false
  # What the router is given for a row in each mode. Public so that
  # `noetic-harness corpus --misroutes` routes exactly what `measure/2` routes.
  def work(row, :title), do: %{title: row["title"]}

  def work(row, :bead),
    do: %{title: row["title"], body: row["body"], kind: row["type"]}

  defp rate(_count, 0), do: nil
  defp rate(count, n), do: Float.round(count / n, 3)
end
