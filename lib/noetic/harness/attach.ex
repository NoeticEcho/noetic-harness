defmodule Noetic.Harness.Attach do
  @moduledoc """
  The harness announcing itself, so that nobody has to remember it.

  Four doors already exist — the skill, the slash commands, the 28 subagents
  and `noetic-harness` — and every one of them needs somebody to walk through it.
  An agent that must *remember* to route will forget, and routing that did not
  happen leaves no trace, which is the worst property a missing step can have.
  `.claude/settings.json` already proves the mechanism: a `SessionStart` hook
  runs `bd prime --hook-json` and every session gets the beads context whether
  it asked for it or not. This is the same shape for `.agents/`.

  ## What it is allowed to do

  **It reads.** It does not dispatch, does not record a step, does not touch a
  bead and does not block a tool call. An auto-attached harness that also
  dispatches is auto-dispatching, and that waits for the whole dispatch track
  (an earlier change says so in as many words).

  ## What it must never do

  **Break the session.** Every entry point here returns a string; the callers
  catch, and a failure becomes one line of injected text naming what went
  wrong. A hook that raises takes the session with it, and a harness that can
  do that is worse than no harness. A hook that fails *silently* is worse
  still: it is indistinguishable from one that is not installed.

  ## Why the routing can be wrong and that is fine

  A route this produces is advisory. When it is wrong the repair is a line in
  `.agents/registry/signals.json` — three routing defects were found and fixed
  exactly that way while the overlays were being built, and a fourth
  while this bead was being written. What is *not* fine is a hook that refuses
  a tool call on a route nobody has audited, which is why `pre_tool` is
  advisory and says so in its own text.

  ## The events

  | event | when | what it injects |
  |---|---|---|
  | `session_start` | a session opens | open runs, a bead database that is not the coordinator's, ready work, whether the services answer |
  | `user_prompt` | every prompt | the route: workflow, lane, team, gates, and the memory the router found |
  | `pre_tool` | before `Edit`/`Write` | the gate lane those paths will have to pass |

  `user_prompt` injects **nothing** for a prompt the router cannot place — a
  low-confidence route presented as an answer is read as authority, and is
  worse than no answer. The measured cost of the ones that do fire is in
  A design note; it is the reason `noetic-harness hook` exists rather
  than the hooks calling `mix`.
  """

  alias Noetic.Harness.{Beads, Memory, Router, Run}

  @events ~w(session_start user_prompt pre_tool)

  @doc "The event names this module answers to."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc """
  The hook's stdout: one JSON object, or an empty string for "inject nothing".

  The shape is Claude Code's own — `hookSpecificOutput.additionalContext` —
  and it is built here rather than in the caller so that the mix task and
  `noetic-harness hook` cannot drift apart about it.
  """
  @spec hook_json(String.t(), map(), keyword()) :: String.t()
  def hook_json(event, payload, opts \\ []) do
    case context(event, payload, opts) do
      :skip ->
        ""

      {:ok, text} ->
        JSON.encode!(%{
          "hookSpecificOutput" => %{
            "hookEventName" => hook_event_name(event),
            "additionalContext" => text
          }
        })
    end
  end

  @doc """
  The text to inject, or `:skip`.

  Never raises: an exception anywhere below becomes a one-line report. The
  caller is a hook, and the hook's contract with the session is that it cannot
  hurt it.
  """
  @spec context(String.t(), map(), keyword()) :: {:ok, String.t()} | :skip
  def context(event, payload, opts \\ [])

  def context(event, payload, opts) when event in @events do
    case build(event, payload, opts) do
      :skip -> :skip
      {:ok, body} -> {:ok, header(event) <> body}
    end
  rescue
    error ->
      {:ok,
       header(event) <>
         "the harness could not answer: #{Exception.message(error)}\n" <>
         "This is a hook failing, not your work failing. `noetic-harness route --title \"...\"`\n" <>
         "runs the same code with a stack trace.\n"}
  catch
    :exit, reason ->
      {:ok, header(event) <> "the harness exited: #{inspect(reason)}\n"}
  end

  def context(event, _payload, _opts),
    do: {:ok, header("session_start") <> "unknown hook event #{inspect(event)}\n"}

  # ---- the three events ----------------------------------------------------

  defp build("session_start", _payload, opts) do
    {:ok,
     Enum.join(
       [
         runs_line(),
         database_line(opts),
         ready_line(opts),
         services_line(),
         "Route before you start: `noetic-harness route --title \"<what you are about to do>\" --explain`.",
         "`noetic-harness workflows --show <id>` is the contract; `noetic-harness run --start` is the ledger."
       ]
       |> Enum.reject(&is_nil/1),
       "\n\n"
     ) <> "\n"}
  end

  defp build("user_prompt", payload, _opts) do
    case String.trim(to_string(payload["prompt"] || "")) do
      "" ->
        :skip

      prompt ->
        route_block(prompt)
    end
  end

  defp build("pre_tool", payload, _opts) do
    case touched_paths(payload) do
      [] -> :skip
      paths -> paths_block(paths)
    end
  end

  # ---- session_start -------------------------------------------------------

  defp runs_line do
    case Run.current() do
      {:ok, run} ->
        "An open run: #{run["id"]}\n" <>
          "  #{run["workflow"]} · #{run["title"]}\n" <>
          "  `noetic-harness run --status` says what it still owes."

      {:error, message} ->
        "The ledger will not guess which run is yours:\n" <> indent(message)

      :error ->
        "No open run. `noetic-harness run --start <WF-0xx> --title \"...\" --bead <id>` opens one."
    end
  end

  # Said only when it is wrong, and then first after the run, because it is the
  # one thing here that loses work silently: a write to a second bead database
  # is invisible to the coordinator that lands everything.
  # Never in a cloud session, which has no main checkout of the person's and
  # never writes beads.
  #
  # `:remote`, `:beads_dir` and `:beads_db` stand in for the environment
  # variables so a test need not set a VM-global. On the resident path the
  # environment read is the resident's, the session that started it, not the
  # session asking: a second session in the same checkout with a different
  # BEADS_DIR gets the first one's answer. Accepted, because sessions in one
  # checkout share one `.claude/settings.json`; a cold hook reads its own.
  defp database_line(opts) do
    remote = Keyword.get_lazy(opts, :remote, fn -> System.get_env("CLAUDE_CODE_REMOTE") end)
    split_opts = Keyword.take(opts, [:beads_dir, :beads_db])

    with true <- remote in [nil, ""],
         true <- Noetic.Harness.Integrations.enabled?("beads"),
         {:split, why, where, coordinator} <-
           Beads.database_split(Noetic.Harness.root(), split_opts) do
      "**NOT THE COORDINATOR'S BEAD DATABASE.** `bd` here would use #{where} " <>
        "(#{why}), not #{coordinator}.\n" <>
        "a design decision allows one. A write here never reaches the work graph the " <>
        "coordinator lands from. Move that database aside (do not delete it), or " <>
        "unset BEADS_DIR or BEADS_DB, or fix the redirect, until `bd where --json` " <>
        "names the main checkout's." <> beads_guide()
    else
      _ -> nil
    end
  end

  # Three outcomes, not two. `:timeout` means `bd` is there and stuck, almost
  # always on a Dolt lock held by another session in this working directory,
  # and the useful thing to say is which one it was.26` was filed
  # after one ran for 327 seconds and took a suite with it.
  #
  # `:ready` in `opts` is how the resident server hands in its last list:
  # a zero-arity function returning `{:cached, result, age_ms}`
  # or `{:live, result}`. This module does not know a cache exists, and the cold
  # path — which passes nothing — is exactly what it was.
  defp ready_line(opts) do
    case Keyword.get(opts, :ready) do
      nil -> render_ready(Beads.ready(6), nil)
      source when is_function(source, 0) -> ready_from(source)
    end
  end

  defp ready_from(source) do
    case source.() do
      {:cached, result, age_ms} -> render_ready(result, age_ms)
      {:live, result} -> render_ready(result, nil)
    end
  end

  # The age goes in the heading, where it cannot be skimmed past. A list that
  # is four minutes old and says so is information; the same list unmarked is
  # a claim about now that nobody checked.
  defp render_ready(result, age_ms) do
    case result do
      {:ok, ""} ->
        "`bd ready` returned nothing" <> as_of(age_ms) <> "."

      {:ok, output} ->
        "Ready work (`bd ready`" <> as_of(age_ms) <> "):\n" <> indent(output)

      :timeout ->
        "`bd` did not answer within #{div(Beads.timeout(), 1000)}s, so there is no work graph " <>
          "in this context. That is usually a Dolt lock held by another session here." <>
          if(Beads.bounded?(),
            do: "",
            else:
              " `timeout` is not installed, so the `bd` that " <>
                "did not answer is still running."
          )

      :error ->
        "`bd` did not answer, so there is no work graph in this context."

      :off ->
        Noetic.Harness.Integrations.off("beads") <> ", so there is no work graph in this context."
    end
  end

  defp as_of(nil), do: ""

  defp as_of(age_ms) do
    seconds = div(age_ms, 1000)

    ago =
      cond do
        seconds < 90 -> "#{seconds} s"
        true -> "#{div(seconds + 30, 60)} min"
      end

    ", as of #{ago} ago — run it for now"
  end

  defp beads_guide do
    case Noetic.Harness.Project.beads_guide() do
      nil -> ""
      guide -> " `#{guide}` says how a split one is merged back."
    end
  end

  # A TCP connect rather than `docker ps`, and the difference is the point: the
  # question a session has is "can I reach Postgres", not "is there a container
  # whose name looks right". It also costs milliseconds and needs no docker.
  # Which services, and what starts them, is the project's (`services` in
  # `.agents/registry/project.json`); a project with none is not
  # probed, and the line is left out.
  defp services_line do
    services_line(Noetic.Harness.Project.services(), Noetic.Harness.Project.services_start())
  end

  defp services_line([], _start), do: nil

  defp services_line(services, start) do
    {up, down} = Enum.split_with(services, fn {_name, port} -> listening?(port) end)
    hint = if start, do: " `#{start}`.", else: ""

    case {up, down} do
      {_, []} ->
        "All #{count(length(services))} services answer."

      {[], _} ->
        "None of #{names(services)} answers." <> hint

      {_, down} ->
        "Not answering: #{Enum.map_join(down, ", ", &elem(&1, 0))}." <> hint
    end
  end

  defp count(1), do: "one"
  defp count(2), do: "two"
  defp count(3), do: "three"
  defp count(n), do: Integer.to_string(n)

  # "postgres, typedb or qdrant", as the line has always read.
  defp names([{name, _port}]), do: name

  defp names(services) do
    {init, [{last, _}]} = Enum.split(services, -1)
    Enum.map_join(init, ", ", &elem(&1, 0)) <> " or " <> last
  end

  defp listening?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  # ---- user_prompt ---------------------------------------------------------

  defp route_block(prompt) do
    case Router.route(%{title: prompt}, max_team: 5) do
      {:error, _message} ->
        :skip

      {:ok, %{confidence: :low}} ->
        # Deliberately silent. A low-confidence route is the router saying the
        # request is too thin to place, and injecting it anyway dresses a guess
        # as an answer — which is exactly the failure this whole file exists to
        # avoid somewhere else.
        :skip

      {:ok, route} ->
        {:ok,
         Enum.join(
           [
             workflow_line(route),
             # `nil` for every way of not getting an opinion, and
             # `Enum.reject(&is_nil/1)` below already drops it — so with no
             # provider configured, which is the state today and may stay it,
             # this adds one function call that returns before spawning
             # anything. When a provider does exist it costs at most
             # `SecondOpinion.deadline/0`, and the hook's own latency gate
             # is what will say whether that was affordable.
             Noetic.Harness.SecondOpinion.on(route),
             "lane #{route.lane} · highest trust #{route.trust}",
             team_line(route),
             uncovered_line(route),
             "gates that will have to pass: #{Enum.join(route.gates, ", ")}",
             memory_line(prompt)
           ]
           |> Enum.reject(&is_nil/1),
           "\n"
         ) <> "\n"}
    end
  end

  defp workflow_line(%{workflow: nil} = route),
    do: "no workflow fits: #{route.workflow_reason}"

  defp workflow_line(route),
    do:
      "workflow #{route.workflow["id"]} #{route.workflow["name"]}" <>
        "  (`noetic-harness workflows --show #{route.workflow["id"]}`)"

  defp team_line(route) do
    case route.team do
      [] -> nil
      team -> "who: " <> Enum.map_join(team, ", ", & &1["id"])
    end
  end

  defp uncovered_line(%{uncovered: []}), do: nil

  defp uncovered_line(route),
    do: "NOT COVERED by any role: " <> Enum.join(route.uncovered, ", ")

  # `relevant/2` rather than `search/1`: it scores a record's declared scope
  # above a chance mention in its body, and it excludes retired records, which
  # `search/1` deliberately does not. Three at most — this is a pointer to the
  # memory, not the memory.
  defp memory_line(prompt) do
    case Memory.relevant([prompt], limit: 3) do
      [] ->
        nil

      records ->
        "what earlier work learned (`noetic-harness memory --query ...`):\n" <>
          Enum.map_join(records, "\n", &"  · #{&1["title"]}")
    end
  end

  # ---- pre_tool ------------------------------------------------------------

  defp touched_paths(payload) do
    case payload["tool_name"] do
      name when name in ["Edit", "Write", "NotebookEdit", "MultiEdit"] ->
        payload
        |> Map.get("tool_input", %{})
        |> then(&[&1["file_path"], &1["notebook_path"]])
        |> Enum.reject(&(is_nil(&1) or &1 == ""))

      _ ->
        []
    end
  end

  defp paths_block(paths) do
    relative = Enum.map(paths, &relative_to_root/1)

    case Router.route(%{paths: relative}, max_team: 3) do
      {:error, _message} ->
        :skip

      {:ok, route} ->
        {:ok,
         "#{Enum.join(relative, ", ")} → lane #{route.lane}, " <>
           "gates #{Enum.join(route.gates, ", ")}.\n" <>
           "Advisory. `noetic-harness gates --lane #{route.lane} --plan --paths " <>
           "#{Enum.join(relative, ",")}` resolves it without running anything.\n"}
    end
  end

  defp relative_to_root(path) do
    root = Noetic.Harness.root()

    case Path.relative_to(path, root) do
      ^path -> Path.relative_to_cwd(path)
      relative -> relative
    end
  end

  # ---- framing -------------------------------------------------------------

  # Headed, always. A block of injected text with no provenance is read as the
  # user's words, and this is a machine's opinion about them.
  defp header("session_start"),
    do: "[harness] This repository develops itself through `.agents/`.\n\n"

  defp header("user_prompt"), do: "[harness] Routing for what you just asked:\n\n"
  defp header("pre_tool"), do: "[harness] "

  defp hook_event_name("session_start"), do: "SessionStart"
  defp hook_event_name("user_prompt"), do: "UserPromptSubmit"
  defp hook_event_name("pre_tool"), do: "PreToolUse"

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("  " <> &1))
  end
end
