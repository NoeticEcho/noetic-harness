defmodule Noetic.Harness.Hooks do
  @moduledoc """
  What the harness costs the session it is attached to, measured and bounded.

  ## Why this exists

  `.claude/settings.json` runs `noetic-harness hook` on `SessionStart`, on every
  prompt, before every `Edit`/`Write`, and at `SessionEnd`. That is the one
  door nobody has to walk through deliberately (`Attach`), and it is therefore
  the one whose price is paid whether or not anybody thinks it is worth
  paying. Until this module the harness had no idea what that price was.

  Measured on this machine on 2026-09-22, and the attribution is the finding.
  Every figure below was re-taken after an independent review could not
  reproduce the first set; where the two disagree, these are the ones that
  stand, and the first set is gone rather than softened.

  | | wall clock (from the log) | the harness's own work inside it |
  |---|---|---|
  | `user_prompt` | p50 1359 ms, p95 4023 ms, n=18 | `Attach.hook_json/2`: **97 ms cold, 182–207 ms warm** |
  | `pre_tool` | p50 1263 ms, p95 1842 ms, n=23 | the same routing |
  | `session_start` | p50 4786 ms, n=3 | 3863 ms, of which `Beads.ready/1` is **4152 ms** |

  A bare `elixir -e ":ok"` here is **777–992 ms over seven runs, median 844**.
  So `user_prompt` is roughly 850 ms of BEAM boot, ~300 ms of sourcing
  `scripts/lib/toolchain.sh`, and 100–200 ms of harness — and `session_start`
  is almost entirely one Dolt query inside `bd`.

  The first version of this table said **25 ms** for `hook_json/2`, and the
  number was wrong in a way worth recording: it was measured in a script that
  had already called `Router.route/1` twice, so the registry was warm and the
  measurement was of the third call, not the first. A hook boots a fresh BEAM
  every time and never gets the third call. The review that caught it
  measured 114–166 ms cold.

  That correction weakens one of the three arguments an earlier change proposed
  and does not rescue it:

  * A **route cache** would save the 100–200 ms that routing takes, and only
    on a prompt the session has seen before, which is rare. It is 8–15% of
    the hook, not the 2% the wrong number implied — worth stating properly,
    still not worth a cache-invalidation bug ahead of the 850 ms below it.
  * An **escript** would remove `mix`'s project loading, which
    `noetic-harness hook` already removes by loading the beams with `-pa`. It
    still boots a BEAM.
  * A **resident server** is the only one of the three that touches the
    ~850 ms floor, and it buys that at the cost of a stale server answering
    from an old registry. Not taken here; an earlier change records the numbers so
    that the decision is made against them rather than against a feeling.

  ## What "bounded" means here, and why it is not "made faster"

  A second or two is not the risk. The risk is that `noetic-harness hook` had
  **no upper bound at all**. `Beads.ready/1` shells out to `bd`, `bd` opens a
  Dolt database, and more than one session shares this working directory — so
  a lock held by another session is a hook that never returns, on an event the
  user cannot skip. It is not hypothetical: an independent reviewer caught
  `bd ready` at **327 seconds** during a run of this repository's own suite
  (since fixed at its source too: `Beads` bounds every call and
  reports a stuck tracker as `:timeout`). Rule 1 of `noetic-harness hook` is
  "exit 0, always", and an
  unbounded hook satisfies it by never exiting at all.

  So the bound is a wall-clock budget the hook enforces on itself with
  `timeout(1)`: `kill_budget/1` for the Elixir call and `stdin_budget/0` for
  reading the payload, which is the hook's *first* act and which the first
  version of this left unbounded — so a writer that never closed stdin hung
  before reaching the bound that the prose claimed covered "every event", and
  left no observation at all.

  Beside them, `ceiling/1`: the much tighter number the gate test checks the
  recorded median against. Two kinds of number because they answer different
  questions — "this session is not hostage to the harness", and "the harness
  has not quietly got slower".

  `timeout` exits 124 only when the child died *from* its signal, and the BEAM
  installs a SIGTERM handler: a killed run here exits **1**, or 0 when the
  signal lands during application boot. So the shell decides by the wall clock
  and not by the status, and a complete JSON object outranks the clock — a
  child that printed one settled the question by finishing.

  When `timeout` is not on the `PATH` the budget is not enforced, and the
  observation records `bounded: false` rather than claiming it was. A budget
  that reports itself as applied when it was not is worse than no budget.

  ## The log

  One JSON object per line under `.agents/telemetry/`, **git-ignored on
  purpose**. Hook latency is a property of one machine at one moment; a p50
  taken over a laptop, a container and a CI runner is a number drawn from
  three populations, which is the mistake this repository has already made
  once and written down. What is committed is the ceiling, not the
  measurements.

  The line is written by `noetic-harness hook` in shell, not here, for two
  reasons: it costs no second process, and it is still written on the paths
  where Elixir is exactly what could not be reached — `unbuilt`, `no_elixir`.
  Those are the observations most worth having. This module owns the *format*
  (`record/1` writes the same line, and an entry-point test runs the real hook
  and parses what it left behind, so the two cannot drift without failing).

  Appends are single short lines opened `O_APPEND`, which concurrent sessions
  can share. Trimming is not concurrency-safe: a trim racing an append can
  lose that append. That is accepted for telemetry and stated rather than
  hidden — the log is a rolling window of the last 500 observations, trimmed
  by the shell once it passes 600, so the file holds between 500 and 601 of
  them. It is not a ledger.
  """

  alias Noetic.Harness

  @max_lines 500
  @max_label 32

  # The bounded vocabulary. A value outside it is recorded as `unrecognised`,
  # for the reason `Usage.label/1` gives: a field nobody validated is a field
  # somebody can fill.
  # `session_end`'s six refusals are named rather than collapsed: a single
  # `refused` says the session was not recorded and not why, and "no open run"
  # is the ordinary state of most sessions while "two runs are open" is the
  # case worth noticing. `Usage.outcome/1` produces these.
  @outcomes ~w(injected silent error timeout unbuilt no_elixir
               recorded no_run many_runs foreign_run no_transcript bad_transcript bad_payload)
  @events ~w(session_start user_prompt pre_tool session_end)
  @unrecognised "unrecognised"

  # The kill budget: how long the hook may take before it is killed and the
  # session continues without it. Generous, because its job is to stop a hang,
  # not to trim a second. `session_end` gets the most: it reads a transcript
  # that can be hundreds of megabytes.
  #
  # These are duplicated in `noetic-harness hook`, which cannot call Elixir to
  # find out what its own budget is without paying the cost it is bounding.
  # `entry_points_test` asserts the two agree.
  @kill_budgets %{
    "session_start" => 20_000,
    "user_prompt" => 15_000,
    "pre_tool" => 15_000,
    "session_end" => 30_000
  }

  # The ceiling: the median the gate test refuses to see passed. Set from the
  # measurement above with room for a loaded machine, not from a wish.
  @ceilings %{
    "session_start" => 8_000,
    "user_prompt" => 3_000,
    "pre_tool" => 3_000,
    "session_end" => 10_000
  }

  # Which path the hook took. `cold` is the original: source
  # the toolchain, boot a BEAM, load the beams, answer, exit. `resident` is the
  # fast path — one TCP round trip to a harness that is already up, no
  # `elixir`, no `scripts/lib/toolchain.sh`.
  #
  # `unknown` is not a third path. It is what a line written before this field
  # existed reads as, and it is a **distinct word** on purpose: counting an old
  # line as `cold` would be a silent default of exactly the kind `parse/1`
  # exists to refuse, and it would put ~1000 ms observations into whichever
  # bucket happened to be convenient.
  @vias ~w(resident cold unknown)
  @unknown_via "unknown"

  # The ceiling the *fast* path is held to, which is the whole point of
  # lowering one. Measured on this machine at a p50 of ~77 ms for `user_prompt`
  # against 1299 ms cold; 500 ms is generous against a loaded two-core laptop
  # and still six times under the cold ceiling, so a resident server that
  # stopped being fast fails this rather than hiding inside the old number.
  #
  # `session_start` had a large one until an earlier change, because the fast path
  # did not remove its real cost: 3899 of its 3920 ms was `Beads.ready/1`
  # opening a Dolt database, and the resident shells out to the same `bd`. The
  # resident now serves its last ready list stamped with its age and refreshes
  # it in the background (`Noetic.Harness.Resident.Ready`), which put
  # `session_start` at 42–249 ms, p50 ≈ 72, over six hook invocations. 1000 ms
  # leaves room for the miss — the first request after a boot whose prefetch
  # has not landed, or a list past its max age — without letting the ordinary
  # case drift back to seconds unnoticed.
  #
  # `session_end` has **no** resident ceiling because it never takes the fast
  # path: it is the one event that writes, and a shared long-lived process
  # serving a write is a larger claim than this bead makes. It runs once per
  # session under a 30 s budget.
  @resident_ceilings %{
    "session_start" => 1_000,
    "user_prompt" => 500,
    "pre_tool" => 500
  }

  @resident_events ~w(session_start user_prompt pre_tool)

  # How saturated this machine may be before an observation stops being
  # evidence about the hook. A multiple of the scheduler count,
  # so it means the same thing on two cores and on sixteen.
  #
  # Four is deliberately generous. This repository's own suite runs four-way,
  # which puts a two-core machine at a load average of four to six while it
  # runs, and those observations are real conditions an agent works under — the
  # gate must keep them. What it must not keep is the window this constant was
  # written for: a session left 36 spinning shell loops running, two cores
  # carried a load average of **42**, and `user_prompt` recorded a median of
  # **15 598 ms** against a 3000 ms ceiling. That is a measurement of the
  # machine.
  #
  # The direction of the risk is the whole reason this is written down: "the
  # machine was busy" is exactly the excuse a latency gate must not accept, so
  # the threshold is high, it is a constant rather than an argument, and
  # `latency/1` reports how many observations it dropped. A gate that quietly
  # discards its inconvenient data is worse than one with no threshold at all.
  @load_ceiling_per_scheduler 4

  # Below this many observations for an event there is no median worth
  # defending — the same floor `Telemetry.clusters/2` applies, for the same
  # reason.
  @min_observations 10

  # How long the hook may spend reading its payload from stdin, in
  # milliseconds. Separate from the kill budget because it is a separate
  # `timeout`: the first version bounded only the Elixir call, and a writer
  # that never closed stdin hung the hook before it reached that bound and
  # left no observation at all.
  @stdin_budget 5_000

  # A duration above this is not credible for a hook whose largest kill budget
  # is 30 s, so it is a line this module did not write and is counted
  # `unreadable`. Without a ceiling any process on the machine can append one
  # absurd number and turn the gate red; without a floor — see `parse/1` — a
  # writer emitting `1200.5` instead of `1200` drives the median to zero and
  # turns it green forever. The second is the dangerous direction.
  @max_ms 600_000

  @max_at 40

  @type observation :: %{String.t() => term()}

  @doc "The four events `noetic-harness hook` answers to."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "The outcome words an observation may carry."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc "How long the hook may spend reading stdin, in milliseconds."
  @spec stdin_budget() :: pos_integer()
  def stdin_budget, do: @stdin_budget

  @doc "How many observations an event needs before its median is checked."
  @spec min_observations() :: pos_integer()
  def min_observations, do: @min_observations

  @doc "How long the hook may run before `timeout(1)` kills it, in milliseconds."
  @spec kill_budget(String.t()) :: pos_integer() | nil
  def kill_budget(event), do: Map.get(@kill_budgets, event)

  @doc "Every kill budget, keyed by event."
  @spec kill_budgets() :: %{String.t() => pos_integer()}
  def kill_budgets, do: @kill_budgets

  @doc "The median latency this event is not allowed to pass, in milliseconds."
  @spec ceiling(String.t()) :: pos_integer() | nil
  def ceiling(event), do: Map.get(@ceilings, event)

  @doc "Every ceiling, keyed by event."
  @spec ceilings() :: %{String.t() => pos_integer()}
  def ceilings, do: @ceilings

  @doc "The words the `via` field may carry."
  @spec vias() :: [String.t()]
  def vias, do: @vias

  @doc "The events the resident server may answer. `session_end` is not one."
  @spec resident_events() :: [String.t()]
  def resident_events, do: @resident_events

  @doc "The ceiling for one event on one path, or `nil` where none is written."
  @spec ceiling(String.t(), String.t()) :: pos_integer() | nil
  def ceiling(event, "resident"), do: Map.get(@resident_ceilings, event)
  def ceiling(event, _via), do: Map.get(@ceilings, event)

  @doc "The fast path's ceilings."
  @spec resident_ceilings() :: %{String.t() => pos_integer()}
  def resident_ceilings, do: @resident_ceilings

  @doc """
  The load average above which an observation stops being evidence about the
  hook, on this machine.

  `@load_ceiling_per_scheduler` times the scheduler count. Read from the
  *reading* machine rather than recorded by the writing one, which is sound
  only because the log is per-machine and git-ignored — that is already why the
  ceilings are committed and the numbers are not.
  """
  @spec load_ceiling() :: pos_integer()
  def load_ceiling do
    @load_ceiling_per_scheduler * :erlang.system_info(:schedulers_online)
  end

  @doc """
  Whether an observation was taken on a machine too busy to be measuring the
  hook.

  An observation with no `load` is **not** saturated: nobody measured, and a
  reader may not exclude what was never recorded.
  """
  @spec saturated?(observation(), pos_integer() | nil) :: boolean()
  def saturated?(observation, ceiling \\ nil) do
    case observation["load"] do
      nil -> false
      recorded -> recorded > (ceiling || load_ceiling())
    end
  end

  @doc """
  Where the rolling log lives.

  `NOETIC_HARNESS_HOOK_LOG` overrides it, and `noetic-harness hook` reads the
  same variable — that is how the test that proves the shell and this module
  write the same format points both at a temporary file without touching the
  real one.
  """
  @spec log_path() :: Path.t()
  def log_path do
    case System.get_env("NOETIC_HARNESS_HOOK_LOG") do
      nil -> Harness.agents_path(["telemetry", "hooks.jsonl"])
      path -> Path.expand(path, Harness.root())
    end
  end

  @doc """
  Append one observation. Returns `:ok` whatever happens.

  Never raises and never reports a failure upward: the only caller that
  matters is a hook, and a hook that fails because its telemetry failed has
  inverted its own priorities.
  """
  @spec record(map()) :: :ok
  def record(fields) when is_map(fields) do
    path = log_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:append, :utf8]) do
      IO.write(io, line(fields))
      File.close(io)
      trim(path)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  One log line, terminated: the format, owned here so the shell can copy it.

  Every field is normalised before it is written rather than after it is read.
  A log whose writer validates is a log whose reader can be simple, and this
  reader runs inside `telemetry`, where a surprise is a wrong number rather
  than a crash.
  """
  @spec line(map()) :: String.t()
  def line(fields) do
    JSON.encode!(%{
      "at" => at(Map.get(fields, "at")),
      "event" => label(Map.get(fields, "event"), @events),
      "ms" => written_ms(Map.get(fields, "ms")),
      "bytes" => count(Map.get(fields, "bytes")),
      "outcome" => label(Map.get(fields, "outcome"), @outcomes),
      "bounded" => Map.get(fields, "bounded") == true,
      "via" => via(Map.get(fields, "via")),
      "load" => load(Map.get(fields, "load"))
    }) <> "\n"
  end

  # Second precision, because that is what `date -u +%Y-%m-%dT%H:%M:%SZ` in
  # `noetic-harness hook` writes and the claim is that the two writers agree.
  # `DateTime.to_iso8601/1` carries microseconds, and an independent review
  # noticed the two formats diverging while the moduledoc said they could not.
  # A value that is not a plausible timestamp is replaced rather than passed
  # through: `line/1` claims every field is normalised before it is written,
  # and this was the field for which that was false.
  defp at(value) when is_binary(value) do
    if byte_size(value) <= @max_at and Regex.match?(~r/^\d{4}-\d{2}-\d{2}T[\d:.]+Z?$/, value),
      do: value,
      else: now()
  end

  defp at(_value), do: now()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc """
  Every observation on disk, oldest first, plus the lines that would not parse.

  Returns `%{"observations" => [...], "unreadable" => n, "path" => path}`. An
  absent log is not an error and not zero observations — it is
  `"observations" => []` with the path named, so that a caller can say "the
  hooks have not run here" rather than "the hooks are fast".
  """
  @spec observations() :: %{String.t() => term()}
  def observations do
    path = log_path()

    case File.read(path) do
      {:ok, contents} ->
        {good, bad} =
          contents
          |> String.split("\n", trim: true)
          |> Enum.reduce({[], 0}, fn raw, {acc, bad} ->
            case parse(raw) do
              {:ok, observation} -> {[observation | acc], bad}
              :error -> {acc, bad + 1}
            end
          end)

        %{"observations" => Enum.reverse(good), "unreadable" => bad, "path" => path}

      {:error, _} ->
        %{"observations" => [], "unreadable" => 0, "path" => path}
    end
  end

  @doc """
  The same read, with everything recorded after `cutoff` removed.

  The budget gate reads the *live* log, because the claim it makes
  is about this machine — and that is right. What is not right is that the act
  of running the suite contaminates the sample it reads: a lane run takes about
  fourteen minutes on two cores, the session driving it fires `pre_tool` on
  every `Edit` and `Write` while it runs, and a hook that normally answers in
  1.3 s is not going to during a four-way `mix test`. Those slow observations
  land in the log the gate is about to read.

  Measured 2026-09-22 on 72 recorded observations: five of forty `user_prompt`
  calls were already over the 3000 ms ceiling, the slowest at 4023 ms, and
  `session_start` reached 11319 ms against a ceiling of 8000. The median held
  at n=40. It would not have held at n=11, which is where the log was on the
  day the gate failed two lane runs in three and passed four standalone runs of
  the same command — the standalone runs were not editing anything, so nothing
  was firing hooks.

  So this is not a flake. It is a gate whose reading changes depending on how
  busy the session running it happens to be, which is the one thing a gate may
  not do.

  An observation whose `at` will not parse is **excluded**, not kept. It cannot
  be shown to predate the cutoff, and this module's rule is already that the
  reader fails closed on anything the gate depends on.
  """
  @spec until(map(), String.t() | DateTime.t()) :: map()
  def until(read, cutoff) when is_map(read) do
    case as_datetime(cutoff) do
      {:ok, cutoff} ->
        kept = Enum.filter(read["observations"] || [], &recorded_by?(&1, cutoff))

        read
        |> Map.put("observations", kept)
        |> Map.put("excluded", length(read["observations"] || []) - length(kept))
        |> Map.put("cutoff", DateTime.to_iso8601(cutoff))

      :error ->
        # A cutoff nobody can read is not a reason to widen the sample.
        read |> Map.put("observations", []) |> Map.put("excluded", :unreadable_cutoff)
    end
  end

  defp as_datetime(%DateTime{} = at), do: {:ok, at}

  defp as_datetime(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> {:ok, at}
      _ -> :error
    end
  end

  defp as_datetime(_at), do: :error

  defp recorded_by?(observation, cutoff) do
    case as_datetime(observation["at"]) do
      {:ok, at} -> DateTime.compare(at, cutoff) != :gt
      :error -> false
    end
  end

  @doc """
  Latency per event: count, p50, p95, slowest, and how many were unbounded.

  Percentiles by nearest rank, which for ten observations is an actual
  observation rather than an interpolation between two of them. `checked` says
  whether the count cleared `min_observations/0`; `over_ceiling` is only ever
  true when it did, because a median of three is not a median.
  """
  @spec latency(map() | nil) :: %{String.t() => map()}
  def latency(read \\ nil) do
    read = read || observations()

    read
    |> Map.get("observations", [])
    |> Enum.group_by(& &1["event"])
    |> Map.new(fn {event, all} ->
      # Split rather than filter, so the number dropped is reportable. The
      # moduledoc's rule: a gate that quietly discards its inconvenient data is
      # worse than one with no threshold at all.
      {excluded, group} = Enum.split_with(all, &saturated?/1)

      samples = group |> Enum.map(& &1["ms"]) |> Enum.sort()
      n = length(samples)
      ceiling = ceiling(event)
      p50 = percentile(samples, 0.5)
      checked = n >= @min_observations and is_integer(ceiling)

      {event,
       %{
         "count" => n,
         "saturated" => length(excluded),
         "p50" => p50,
         "p95" => percentile(samples, 0.95),
         "max" => List.last(samples),
         "bytes" => group |> Enum.map(& &1["bytes"]) |> Enum.sum(),
         "unbounded" => Enum.count(group, &(&1["bounded"] != true)),
         "outcomes" => Enum.frequencies_by(group, & &1["outcome"]),
         "ceiling" => ceiling,
         "checked" => checked,
         "over_ceiling" => checked and p50 > ceiling,
         "via" => by_via(event, group)
       }}
    end)
  end

  # The same arithmetic per path, because the whole claim of a
  # resident server is that one of these numbers is an order of magnitude
  # smaller than the other. Rolled into a single median they hide each other in
  # both directions: a fast path used half the time keeps the aggregate under a
  # ceiling that the cold path alone would breach, and a resident server that
  # quietly stopped being fast would never show up against a ceiling written
  # for a BEAM boot.
  defp by_via(event, group) do
    group
    |> Enum.group_by(& &1["via"])
    |> Map.new(fn {via, rows} ->
      samples = rows |> Enum.map(& &1["ms"]) |> Enum.sort()
      n = length(samples)
      ceiling = ceiling(event, via)
      p50 = percentile(samples, 0.5)
      checked = n >= @min_observations and is_integer(ceiling)

      {via,
       %{
         "count" => n,
         "p50" => p50,
         "p95" => percentile(samples, 0.95),
         "max" => List.last(samples),
         "ceiling" => ceiling,
         "checked" => checked,
         "over_ceiling" => checked and p50 > ceiling
       }}
    end)
  end

  # ---- internals -----------------------------------------------------------

  defp percentile([], _q), do: nil

  defp percentile(sorted, q) do
    index = max(ceil(length(sorted) * q) - 1, 0)
    Enum.at(sorted, index)
  end

  # Every field the writer emits must be present and well-formed, and a line
  # that is not is `unreadable` rather than defaulted. An independent review
  # showed what defaulting costs: renaming the shell's `bounded` key left the
  # suite green, made every observation read `bounded: false`, and made
  # `noetic-harness telemetry` print a confident and wrong explanation — that
  # `timeout` was not on the PATH. A silent default turns drift into a false
  # diagnosis, which is worse than a parse failure.
  @required ~w(at event ms bytes outcome bounded)

  defp parse(raw) do
    with {:ok, map} when is_map(map) <- JSON.decode(raw),
         true <- Enum.all?(@required, &Map.has_key?(map, &1)),
         event when event != @unrecognised <- label(map["event"], @events),
         {:ok, ms} <- duration(map["ms"]),
         true <- is_boolean(map["bounded"]),
         true <- is_binary(map["at"]) do
      {:ok,
       %{
         "at" => map["at"],
         "event" => event,
         "ms" => ms,
         "bytes" => count(map["bytes"]),
         "outcome" => label(map["outcome"], @outcomes),
         "bounded" => map["bounded"],
         "via" => via(map["via"]),
         "load" => load(map["load"])
       }}
    else
      _ -> :error
    end
  end

  # The one number the gate reads, so it fails **closed**. A float, a string or
  # a negative is not zero milliseconds — it is a line this module did not
  # write, and counting it as the fastest possible observation is how a median
  # stays under a ceiling forever.
  defp duration(ms) when is_integer(ms) and ms >= 0 and ms <= @max_ms, do: {:ok, ms}
  defp duration(_ms), do: :error

  # An unknown event is a line this module did not write, and grouping by it
  # would put a stranger's rows in a percentile. It is `unreadable` instead.
  defp label(value, allowed) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed in allowed and byte_size(trimmed) <= @max_label,
      do: trimmed,
      else: @unrecognised
  end

  defp label(_value, _allowed), do: @unrecognised

  # Absent is `unknown`, which is a word in the vocabulary rather than a
  # fallback outside it: every line written before an earlier change lacks this
  # field, and they are neither `cold` nor `resident` — nobody recorded which.
  # A value that is present and not in the vocabulary is `unrecognised`, the
  # same as every other label, because that is a writer this module did not
  # write and it must not be able to name itself into a bucket.
  defp via(nil), do: @unknown_via
  defp via(value), do: label(value, @vias)

  # `nil` means nobody measured — a line written before an earlier change, or a
  # machine with no `/proc/loadavg`. It is **kept**, because a reader cannot
  # exclude what was never recorded and excluding it by default would silently
  # empty an older log.
  defp load(value) when is_integer(value) and value >= 0 and value <= 10_000, do: value
  defp load(_value), do: nil

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_), do: 0

  # `bytes` may safely default to zero; the duration may not. `-1` is written
  # instead, which `duration/1` rejects on the way back in, so a caller that
  # hands `line/1` a float or a string produces a line the reader counts as
  # `unreadable` rather than one that claims the fastest possible observation.
  # Writing `0` there is the same fail-open the reader was just fixed for.
  defp written_ms(ms) when is_integer(ms) and ms >= 0 and ms <= @max_ms, do: ms
  defp written_ms(_ms), do: -1

  # Rewrite only when the window has actually overflowed. Reading 500 short
  # lines to decide is cheaper than the BEAM boot that preceded it, and it
  # happens once every #{@max_lines} hooks.
  defp trim(path) do
    lines = path |> File.read!() |> String.split("\n", trim: true)

    if length(lines) > @max_lines do
      kept = Enum.take(lines, -@max_lines)
      File.write!(path, Enum.join(kept, "\n") <> "\n")
    end
  rescue
    _ -> :ok
  end
end
