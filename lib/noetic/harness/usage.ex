defmodule Noetic.Harness.Usage do
  @moduledoc """
  What a session cost, counted from the transcript the agent already writes.

  ## Why this exists

  `Run.spend/2` records what a dispatch cost, and `Dispatcher` is its only
  caller. Measured on 2026-09-22: **21 runs in the ledger, zero dispatches,
  total cost known $0.00** — because work in this repository is not done by
  the dispatcher, it is done by a Claude Code session, and the session
  reported nothing. So the harness could say what was done and never what it
  cost, which makes "the harness is getting more efficient" a sentence with no
  denominator.

  The data was on disk the whole time. Every assistant message in
  `~/.claude/projects/<slug>/<session>.jsonl` carries a `usage` object —
  `input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
  `cache_read_input_tokens`, `output_tokens_details.thinking_tokens` — and a
  `model`. Tool calls are `tool_use` blocks in `message.content`, so "how many
  shell commands did this take" is countable too.

  ## What it will not read

  **Nothing that carries content.** Not message text, not tool arguments, not
  tool results. A transcript is a record of everything a person said and
  everything their files contained, and the ledger is committed to git. The
  only thing taken out of a `tool_use` block is `name`; the only thing taken
  out of a message is its `usage` and its `model`.

  That is a stronger rule than redaction and deliberately so.
  `Environments.squeeze/1` exists because evidence sometimes must quote what a
  command printed, and it redacts by value. Here nothing has to be quoted, so
  the safe version is to never look — a redactor that is never asked to run
  cannot be wrong.

  **But "we only take `name` and `model`" is not on its own an argument**, and
  an independent review said so by writing a credential into a `model` field
  and watching it land in the ledger verbatim. Those two fields are strings
  chosen by whatever produced the transcript, so they are *bounded* as well as
  narrow: `label/1` keeps a value only if it is a binary, is printable, and
  is at most `#{80}` bytes, and buckets everything else under `unrecognised`.
  `cap/1` then keeps at most `#{40}` distinct keys and sums the rest under
  `other`, because 20 000 distinct tool names in one transcript grew a run
  file from 6 KB to 1.1 MB in a single observation.

  Neither bound is a privacy mechanism — a 79-byte printable model id can
  still carry a secret. They are the reason the *claim* is true rather than
  incidental: a field nobody validated is a field somebody can fill.

  ## The four counters stay four

  Two billion cache-read tokens and eight million cache-creation tokens are
  not the same quantity and do not price the same way; a single `tokens`
  number would hide the one worth optimising. They are recorded separately and
  summed by whoever knows the prices.

  A malformed line is counted in `unreadable` rather than skipped, for the
  reason `Telemetry` gives about its own sources: a file that could not be
  read and a file with nothing in it are different facts, and only one of them
  means "nothing happened here".
  """

  @type summary :: %{String.t() => term()}

  @counters ~w(input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens)

  # Bounds on the two fields that come out of the transcript as free strings.
  # See `label/1` and `cap/1`.
  @max_label 80
  @max_keys 40
  @unrecognised "unrecognised"
  @token ~r{^[A-Za-z0-9._:/<>-]+$}
  @other "other"

  @doc """
  Aggregate one transcript.

  Returns counts and nothing else. The path is read line by line — a session
  transcript reaches tens of megabytes, and this runs in a hook.
  """
  @spec read(String.t()) :: {:ok, summary()} | {:error, String.t()}
  def read(path) when is_binary(path) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.reduce(empty(path), &fold/2)
      |> finish()
    else
      {:error, "no transcript at #{path}"}
    end
  rescue
    # `File.regular?/1` answering yes does not mean the file can be read —
    # permissions, a race between the check and the open, a device that is not
    # seekable. The `@spec` and `record/1`'s docstring both promise a refusal,
    # and an independent review found `Usage.read("/etc/shadow")` raising
    # instead; the hook then swallows it (`2>/dev/null`, `exit 0`) and the
    # session is silently never recorded, which is the §33 failure exactly.
    error -> {:error, "could not read #{path}: #{Exception.message(error)}"}
  end

  def read(other), do: {:error, "#{inspect(other)} is not a path to a transcript"}

  @doc """
  What a `SessionEnd` hook should do with its payload.

  The hook is handed `transcript_path`, so nothing has to be inferred. Reads
  it, aggregates, and records against the current run.

  **This is the one place the attach machinery writes**, and it is
  deliberately not in `Noetic.Harness.Attach`, whose moduledoc rests on
  "read-only by construction: it routes, it never dispatches, records a step
  or denies a tool call". That sentence stays true. What this
  writes is an observation and never an outcome — the same asymmetry
  `Dispatcher` has, where it may record a `failed` and can never record a
  `done`. A session's token count cannot make a step done, cannot close a run
  and cannot move a ceiling.

  Refuses rather than guesses in all five ways it can fail to know which run
  this was: no payload, no path, a transcript it could not read, no single
  open run, and an open run that is another epic's. `session_run/1` supplies
  the last two: it refuses when **two runs are open** for this session, which
  is not the same as two sessions — two sessions sharing one open run both
  record against it, which is what `observe/2`'s idempotency key is for — and
  when the only open runs belong to other epics.

  **When it refuses, nothing is printed.** The hook is silent by design, so
  the only sign is the run's token line in `noetic-harness run --status` not
  moving — and once one session has been recorded, that line no longer says
  "nothing recorded". Two open runs is the case this actually happens in, and
  An earlier change, which gives the hooks a place to record their own outcome, is
  where it stops being invisible. Stated rather than implied.
  """
  @spec record(map(), keyword()) :: {:ok, String.t(), summary()} | {:error, String.t()}
  def record(payload, opts \\ [])

  def record(payload, opts) when is_map(payload) do
    with {:ok, path} <- path(payload),
         {:ok, summary} <- read(path),
         {:ok, run} <- current_run(opts),
         {:ok, _} <- Noetic.Harness.Run.observe(run, summary) do
      {:ok, run, summary}
    end
  end

  def record(_payload, _opts), do: {:error, "the hook payload was not an object"}

  @doc """
  `record/1`, reduced to one word `noetic-harness hook` can put in its log.

  `record/1` answers `{:error, message}` for every one of five different
  situations, and an independent review of an earlier change pointed out that
  collapsing them to a single `refused` tells you *that* the session was not
  recorded and not *why* — while "no open run" is the ordinary state of most
  sessions and "two runs are open" is the case worth noticing. So the word
  names the stage that refused.

  The stage is read from the control flow, never from the message text: a
  classifier that matches on prose breaks the first time somebody improves a
  sentence, and it would break silently.

  `many_runs` and `foreign_run` are the ones that matter: two runs this
  session could mean, and only other epics' runs open.
  `no_run` is the ordinary state of most sessions.
  """
  @spec outcome(term(), keyword()) :: String.t()
  def outcome(payload, opts \\ [])

  def outcome(payload, opts) when is_map(payload) do
    with {:ok, path} <- take(path(payload), "no_transcript"),
         {:ok, summary} <- take(read(path), "bad_transcript"),
         {:ok, run} <- open_run(opts) do
      case Noetic.Harness.Run.observe(run, summary) do
        {:ok, _} -> "recorded"
        _ -> "error"
      end
    else
      word -> word
    end
  end

  def outcome(_payload, _opts), do: "bad_payload"

  defp take({:ok, value}, _word), do: {:ok, value}
  defp take(_other, word), do: word

  defp open_run(opts) do
    case session_run(opts) do
      {:ok, id} -> {:ok, id}
      {:many, _message} -> "many_runs"
      {:foreign, _message} -> "foreign_run"
      :none -> "no_run"
    end
  end

  @doc """
  The open run this session's cost belongs to, or why there is none.

  **Picked by this session's epic when there is one**. A
  worker's `SessionEnd` appended its usage to another worker's run: the only
  open run it could see, left open on develop by an epic that had landed.
  "Exactly one open run" is a fact about the ledger, not about this session.
  So when the session has an epic, only an open run whose `bead` is that epic
  is its run; when none is, and other epics' runs are open, the answer is
  `{:foreign, message}` naming them, and nothing is recorded.

  The epic is the one whose handoff (`.agents/handoff/<epic>.json`) names the
  checked-out branch, which a cloud worker's first commit writes. It is not
  parsed out of the branch name: the coordinator's session branch is
  `claude/<something>` too, and reading `<something>` as an epic would make
  its own runs foreign. With no handoff for the branch — the coordinator, a
  local session, a detached head — the old rule stands: exactly one open run.

  `opts[:epic]` states the epic instead (`nil` for none), for the tests.
  """
  @spec session_run(keyword()) ::
          {:ok, String.t()} | :none | {:many, String.t()} | {:foreign, String.t()}
  def session_run(opts \\ []) do
    epic = Keyword.get_lazy(opts, :epic, &session_epic/0)

    open =
      Enum.filter(
        Noetic.Harness.Run.list(),
        &(&1["status"] == "open" and &1["ephemeral"] != true)
      )

    mine = if epic, do: Enum.filter(open, &(&1["bead"] == epic)), else: open

    case {mine, open} do
      {[run], _} ->
        {:ok, run["id"]}

      {[], []} ->
        :none

      {[], others} ->
        {:foreign,
         "no open run is this session's epic #{epic}, and this does not record into " <>
           "another epic's run: " <> Enum.map_join(others, ", ", &"#{&1["id"]} (#{&1["bead"]})")}

      {runs, _} ->
        {:many,
         "#{length(runs)} runs are open#{if epic, do: " for #{epic}", else: ""} " <>
           "and I will not guess which one is yours: " <> Enum.map_join(runs, ", ", & &1["id"])}
    end
  end

  @doc """
  The epic whose handoff names the checked-out branch, or `nil`.
  """
  @spec session_epic() :: String.t() | nil
  def session_epic do
    with {:ok, branch} when branch not in ["", "HEAD"] <- Noetic.Harness.Git.branch(),
         {:ok, files} <- File.ls(Noetic.Harness.agents_path("handoff")) do
      Enum.find_value(files, fn file ->
        with true <- String.ends_with?(file, ".json"),
             {:ok, bytes} <- File.read(Path.join(Noetic.Harness.agents_path("handoff"), file)),
             {:ok, %{"branch" => ^branch, "epic" => epic}} when is_binary(epic) <-
               JSON.decode(bytes) do
          epic
        else
          _ -> nil
        end
      end)
    else
      _ -> nil
    end
  end

  defp path(payload) do
    case payload["transcript_path"] do
      p when is_binary(p) and p != "" ->
        {:ok, p}

      _ ->
        {:error,
         "the hook payload carries no transcript_path, and this does not go looking: a " <>
           "transcript found by guessing is a transcript that might belong to another session"}
    end
  end

  defp current_run(opts) do
    case session_run(opts) do
      {:ok, id} -> {:ok, id}
      {:many, message} -> {:error, message}
      {:foreign, message} -> {:error, message}
      :none -> {:error, "no open run, so there is nothing to record this session against"}
    end
  end

  @doc """
  The counter names, in the order anything printing them should use.

  Read rather than repeated, for the reason `Evolution.set_keys/0` gives: two
  lists that agree by coincidence stop agreeing silently.
  """
  @spec counters() :: [String.t()]
  def counters, do: @counters

  defp empty(path) do
    %{
      # The basename is for a person to read; `session` is what identity is
      # keyed on. Two transcripts in different directories can share a
      # basename, and `Run.observe/2` replaces by identity — so keyed on the
      # basename, `--transcript /a/x.jsonl` and `/b/x.jsonl` silently
      # overwrite each other. A digest rather than the path itself because the
      # path contains a home directory and the ledger is committed.
      "session" =>
        path
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16),
      "transcript" => Path.basename(path),
      "messages" => 0,
      "unreadable" => 0,
      "models" => %{},
      "tools" => %{},
      "tokens" => Map.new(@counters, &{&1, 0}),
      "thinking_tokens" => 0
    }
  end

  defp fold(line, acc) do
    case JSON.decode(line) do
      {:ok, entry} when is_map(entry) -> entry |> Map.get("message") |> message(acc)
      _ -> Map.update!(acc, "unreadable", &(&1 + 1))
    end
  end

  defp message(message, acc) when is_map(message) do
    acc
    |> tokens(message["usage"], message["model"])
    |> tools(message["content"])
  end

  defp message(_message, acc), do: acc

  # A `usage` object with none of the four counters in it is not a turn that
  # cost nothing — it is a shape this code did not recognise, and counting the
  # message would let it past `finish/1`'s "no usage anywhere is an error"
  # guard one message at a time. An independent review found `"usage": {}`
  # doing exactly that.
  defp tokens(acc, usage, model) when is_map(usage) do
    if Enum.any?(@counters, &Map.has_key?(usage, &1)) do
      count(acc, usage, model)
    else
      Map.update!(acc, "unreadable", &(&1 + 1))
    end
  end

  defp tokens(acc, _usage, _model), do: acc

  defp count(acc, usage, model) do
    counted =
      Enum.reduce(@counters, acc["tokens"], fn key, tokens ->
        Map.update!(tokens, key, &(&1 + number(usage[key])))
      end)

    thinking =
      case usage["output_tokens_details"] do
        %{"thinking_tokens" => n} -> number(n)
        _ -> 0
      end

    acc
    |> Map.put("tokens", counted)
    |> Map.update!("thinking_tokens", &(&1 + thinking))
    |> Map.update!("messages", &(&1 + 1))
    |> Map.update!("models", &bump(&1, label(model)))
  end

  # `name` and nothing else. See the moduledoc: a `tool_use` block's `input`
  # is the command that was run, the file that was written or the text that
  # was searched for, and none of that belongs in a file the repository
  # commits.
  defp tools(acc, content) when is_list(content) do
    Enum.reduce(content, acc, fn
      %{"type" => "tool_use", "name" => name}, inner ->
        Map.update!(inner, "tools", &bump(&1, label(name)))

      _block, inner ->
        inner
    end)
  end

  defp tools(acc, _content), do: acc

  defp bump(counts, nil), do: counts
  defp bump(counts, key), do: Map.update(counts, key, 1, &(&1 + 1))

  # A model id or a tool name, or `unrecognised`.
  #
  # Both are strings chosen by whatever wrote the transcript and neither was
  # checked before an independent review put a credential in a `model` field
  # and watched it reach the ledger verbatim — along with a `model` of
  # `["secret", 2]`, which `to_string/1` flattens as iodata and appends a raw
  # control byte to, and a `model` that was a map, which made `Loader.pretty!`
  # raise inside `Enum.sort_by/3` so that `noetic-harness hook` swallowed the
  # whole observation.
  #
  # The shape is a **token**: letters, digits and `._:/<>-`, and in particular
  # no whitespace. `String.printable?/1` alone was the first version and the
  # test that now guards this caught it — `"claude-opus-5 ghp_zzz…"` is
  # printable, is inside the length bound, and reached the ledger with the
  # credential intact. Every model id and tool name this repository has
  # actually seen is a token: `claude-opus-5`, `<synthetic>`, `Bash`,
  # `mcp__Claude_Browser__navigate`.
  #
  # What this still does **not** stop, said rather than implied: a bare
  # `ghp_…` with no spaces, under 80 bytes, is a token and would be kept. The
  # bound narrows the blast radius of a field nobody validated; it is not a
  # secret scanner, and the thing that makes the privacy claim true is that
  # no *content* field is read at all.
  defp label(nil), do: nil

  defp label(value) when is_binary(value) do
    cond do
      value == "" -> @unrecognised
      byte_size(value) > @max_label -> @unrecognised
      not Regex.match?(@token, value) -> @unrecognised
      true -> value
    end
  end

  defp label(_value), do: @unrecognised

  # At most `@max_keys` distinct keys, the rest summed under `other`.
  #
  # A map keyed by values from the transcript is a map an author of one can
  # make arbitrarily large, and the run file is committed: 20 000 distinct
  # tool names took one from 6 KB to 1.1 MB in a single `observe/2`. The
  # biggest counts are kept, because "which tools did this session lean on"
  # is the question these answer.
  defp cap(counts) when map_size(counts) <= @max_keys, do: counts

  defp cap(counts) do
    {kept, rest} =
      counts
      |> Enum.sort_by(fn {_key, n} -> -n end)
      |> Enum.split(@max_keys - 1)

    Map.put(Map.new(kept), @other, Enum.reduce(rest, 0, fn {_key, n}, sum -> sum + n end))
  end

  defp number(n) when is_integer(n) and n >= 0, do: n
  defp number(_), do: 0

  # A transcript with no usage in it at all is not a session that cost
  # nothing; it is a file this code did not understand. §32: do not convert
  # uncertainty into a number.
  defp finish(%{"messages" => 0, "unreadable" => unreadable} = acc) do
    {:error,
     "#{acc["transcript"]} holds no assistant message carrying a usage object " <>
       "(#{unreadable} line(s) could not be parsed), so there is nothing to record. " <>
       "A transcript that cannot be read is not a session that cost nothing"}
  end

  defp finish(acc) do
    {:ok, acc |> Map.update!("models", &cap/1) |> Map.update!("tools", &cap/1)}
  end
end
