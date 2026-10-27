defmodule Mix.Tasks.Harness.Environments do
  @shortdoc "The tasks the evolution gates are scored on"

  @moduledoc """
  Executable environments derived from this repository's own fixed defects.

      noetic-harness environments                        # the three sets
      noetic-harness environments --show <id>            # one, with its statement
      noetic-harness environments --brief <id>           # only what a solver may see
      noetic-harness environments --rejected             # and why each was rejected
      noetic-harness environments --derive <sha>         # a new one from a commit
      noetic-harness environments --verify <id>          # run it both ways
      noetic-harness environments --assign <id> --set holdout
      noetic-harness environments --json

  An environment is kept **only if its verifier fails against the pre-fix
  source and passes at HEAD**. Three of the thirteen derived here did not, and
  they are in no set: the test their commit added exercises the feature and not
  the defect. `--rejected` lists them, because each one is a finding about a
  test somebody believed was a regression test.

  `--verify` runs in a git worktree of its own, checked out at HEAD and thrown
  away afterwards, so it rewrites nothing anybody else is standing in and can
  run beside other work. A verdict is therefore about HEAD: if the
  caller has uncommitted changes in the paths the verifier reads, the record
  says so rather than refusing.

  ## Options

    * `--show <id>` — one environment in full, **including the answer sheet**
    * `--brief <id>` — the statement, the app and the editable paths, and
      nothing else. This is what a solver is handed.
    * `--set <name>` — filter the listing, or the target of `--assign`
    * `--rejected` — the environments that failed the fail-before criterion
    * `--derive <sha>` — build an unverified environment from a commit
    * `--id <id>` — the id to give a derived environment
    * `--verify <id>` — run the verifier both ways and record the result
    * `--verify <id> --at-fix` — the same two passes in a worktree at the fix
      commit, recorded as `verification_at_fix` and read by nothing that
      scores: did this test discriminate this fix when it was written? The
      answer that survives later edits to the same file.
    * `--verify-all` — every environment that has never been verified
    * `--verify-all --stale` — every environment whose last verdict was taken
      at a commit that is no longer HEAD. A verdict is about a tree; `--stale`
      alone only lists them, and nothing re-asked the question until this.
      One that can no longer be asked comes back `unavailable`,
      which is the cue to `--retire` it with a reason rather than let it sit
      in the set as a warning.
    * `--assign <id>` — put a verified environment into `--set`. One-way.
    * `--json`

  ## Decision environments

  A versioned question asked of labelled corpus rows, in the same store and
  under the same `--verify`, `--assign` and `--retire` as the rest; see
  `Noetic.Harness.Environments.Decision`.

      noetic-harness environments --derive-decision failure.class --corpus failures.jsonl \\
        --from run --part 0/2 [--id <id>] [--bead <id>]
      noetic-harness environments --score <id> --answers answers.jsonl \\
        [--reference conductor | --reference other.jsonl] [--record]

    * `--derive-decision <question>` — rows from `--corpus`, optionally only
      the `--from` population and the `--part k/n` hash split
    * `--score <id> --answers <file>` — one JSON object per line:
      `{"id", "choice", "probabilities"}`. `--reference` is what the answers
      would replace, on the same rows; `conductor` asks `Conductor.classify/1`
      for `failure.class`. `--record` writes the report as a
      `CalibrationReport` artifact.
  """

  use Mix.Task

  alias Noetic.Harness.{Environments, Loader}
  alias Noetic.Harness.Environments.Decision

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          show: :string,
          brief: :string,
          set: :string,
          rejected: :boolean,
          derive: :string,
          id: :string,
          verify: :string,
          verify_all: :boolean,
          at_fix: :boolean,
          assign: :string,
          coverage: :boolean,
          derivable: :boolean,
          stale: :boolean,
          retired: :boolean,
          retire: :string,
          restore: :string,
          reason: :string,
          replaced_by: :string,
          limit: :integer,
          json: :boolean,
          derive_decision: :string,
          corpus: :string,
          from: :string,
          part: :string,
          bead: :string,
          score: :string,
          answers: :string,
          reference: :string,
          record: :boolean
        ]
      )

    shell = Mix.shell()

    cond do
      opts[:coverage] ->
        coverage(shell, opts)

      opts[:derivable] ->
        derivable(shell, opts)

      opts[:verify_all] && opts[:stale] ->
        verify(shell, stale_ids(), "every environment's verdict was taken at HEAD.")

      opts[:stale] ->
        stale(shell)

      opts[:retired] ->
        retired(shell)

      id = opts[:retire] ->
        retire(shell, id, opts)

      id = opts[:restore] ->
        restore(shell, id, opts)

      opts[:show] ->
        show(shell, opts[:show], opts)

      opts[:brief] ->
        brief(shell, opts[:brief], opts)

      opts[:derive] ->
        derive(shell, opts)

      opts[:derive_decision] ->
        derive_decision(shell, opts)

      opts[:score] ->
        score(shell, opts)

      opts[:verify] && opts[:at_fix] ->
        verify_at_fix(shell, opts[:verify])

      opts[:verify] ->
        verify(shell, [opts[:verify]])

      opts[:verify_all] ->
        verify(shell, unverified_ids())

      opts[:assign] ->
        assign(shell, opts)

      opts[:rejected] ->
        rejected(shell)

      # `set: nil` is a filter — it means "the unassigned" — so an absent
      # `--set` must not be passed at all. Passing it returned three of
      # thirteen environments and looked like a working command.
      opts[:json] ->
        shell.info(Loader.pretty!(Environments.list(filters(opts))))

      true ->
        overview(shell, opts)
    end
  end

  # A suite derived from history decays, and a decaying suite
  # scores everything the same while looking like it is working.
  defp coverage(shell, opts) do
    coverage = Environments.coverage()

    if opts[:json] do
      shell.info(Loader.pretty!(coverage))
    else
      head = Environments.current_head()

      shell.info(
        "coverage at #{String.slice(head || "?", 0, 8)} — floor is #{Environments.floor()} verified"
      )

      shell.info("")

      columns = ~w(members verified fresh discriminating unavailable retired)

      shell.info(
        "  " <>
          String.pad_trailing("set", 12) <>
          Enum.map_join(columns, " ", &String.pad_leading(&1, 14))
      )

      for {set, stats} <- Enum.sort(coverage) do
        row = Enum.map_join(columns, " ", &String.pad_leading(to_string(stats[&1]), 14))
        shell.info("  " <> String.pad_trailing(set, 12) <> row)
      end

      shell.info("")
      shell.info("`fresh` is verified at the current HEAD. `discriminating` counts members whose")

      shell.info(
        "verifier failed on an **assertion** before the fix — a compile error proves the"
      )

      shell.info("file was broken, not that the test discriminates anything.")
    end
  end

  defp derivable(shell, opts) do
    case Environments.derivable(limit: opts[:limit] || 20) do
      [] ->
        shell.info("nothing to derive: no commit since the newest environment fixes code and")
        shell.info("adds a test.")

      shas ->
        shell.info("#{length(shas)} commit(s) would yield an environment, oldest first:")
        shell.info("")

        for sha <- shas do
          {subject, _} =
            System.cmd("git", ["show", "-s", "--format=%s", sha], stderr_to_stdout: true)

          shell.info("  #{String.slice(sha, 0, 8)}  #{String.slice(String.trim(subject), 0, 70)}")
        end

        shell.info("")
        shell.info("`--derive <sha>` writes one; `--verify <id>` then establishes whether its")
        shell.info("test actually fails without the fix. Two of thirteen were rejected by that.")
    end
  end

  defp stale(shell) do
    head = Environments.current_head()

    case Environments.stale(head) do
      [] ->
        shell.info("every environment was verified at #{String.slice(head || "?", 0, 8)}.")

      environments ->
        shell.info("#{length(environments)} verified at a commit that is no longer HEAD:")
        shell.info("")

        for environment <- environments do
          at = get_in(environment, ["verification", "head"]) || "never"
          shell.info("  #{String.pad_trailing(environment["id"], 36)} #{String.slice(at, 0, 8)}")
        end
    end
  end

  defp retired(shell) do
    case Environments.list(retired: true) do
      [] ->
        shell.info("nothing has been retired.")

      environments ->
        for environment <- environments do
          retired = environment["retired"]
          shell.info("")
          shell.info("#{environment["id"]}  retired #{retired["at"]} by #{retired["by"]}")
          shell.info("  #{retired["reason"]}")

          if retired["replaced_by"] do
            shell.info("  replaced by #{retired["replaced_by"]}")
          end
        end
    end
  end

  defp retire(shell, id, opts) do
    case Environments.retire(id, reason: opts[:reason], replaced_by: opts[:replaced_by]) do
      :ok ->
        shell.info("#{id} retired. It is not deleted — `--retired` lists it with its reason.")

      {:error, message} ->
        shell.info(message)
    end
  end

  defp restore(shell, id, opts) do
    case Environments.restore(id, reason: opts[:reason]) do
      :ok ->
        shell.info("#{id} restored. The retirement stays on the file, in `retired_history`.")

      {:error, message} ->
        shell.info(message)
    end
  end

  defp overview(shell, opts) do
    if set = opts[:set] do
      render_set(shell, set)
    else
      Enum.each(Environments.sets(), &render_set(shell, &1))
      rejected(shell)
      loose(shell)
    end
  end

  defp render_set(shell, set) do
    suite = Environments.suite(set)

    shell.info("")
    shell.info("#{set} — #{length(suite)} verified")

    Enum.each(suite, fn environment ->
      shell.info(
        "  #{String.pad_trailing(environment["id"], 34)} " <>
          "#{String.pad_trailing(environment["verifier"]["app"], 16)} " <>
          "#{String.slice(environment["source"]["fix"], 0, 8)}"
      )
    end)

    if suite == [] do
      shell.info("  nothing verified in this set; a gate reading it is reading nothing")
    end

    # Listed apart: they are scored from answers files, and no harness
    # candidate's suite or floor counts them.
    for environment <- Environments.suite(set, "decision") do
      verifier = environment["verifier"]

      shell.info(
        "  #{String.pad_trailing(environment["id"], 34)} " <>
          "decision: #{verifier["question"]}@#{verifier["version"]}, #{length(verifier["rows"])} rows"
      )
    end
  end

  defp rejected(shell) do
    case Environments.list(state: "rejected") do
      [] ->
        :ok

      list ->
        shell.info("")
        shell.info("rejected — the verifier does not discriminate the defect (#{length(list)})")

        Enum.each(list, fn
          %{"verifier" => %{"kind" => "decision"}} = environment ->
            shell.info("  #{environment["id"]}  #{environment["verification"]["reason"]}")

          environment ->
            shell.info(
              "  #{environment["id"]}  #{Enum.join(environment["verifier"]["files"], " ")}"
            )

            # The commit subject names the fix. It is printed here on purpose —
            # `--rejected` is a report *about the suite*, read by whoever
            # maintains it, not by a solver — and it is labelled so that nobody
            # pastes it into a task by accident.
            shell.info("      answer sheet: #{environment["source"]["subject"]}")
        end)
    end
  end

  defp loose(shell) do
    %{errors: errors, warnings: warnings} = Environments.validate()

    Enum.each(errors, &shell.error("  ✗ #{&1}"))

    if warnings != [] do
      shell.info("")
      Enum.each(warnings, &shell.info("  ! #{&1}"))
    end
  end

  defp show(shell, id, opts) do
    case Environments.fetch(id) do
      :error ->
        shell.error("no environment #{id}")

      {:ok, environment} ->
        if opts[:json] do
          shell.info(Loader.pretty!(environment))
        else
          render(shell, environment)
        end
    end
  end

  # What a solver is handed, and nothing else. `Environments.brief/1` is the
  # allow-list and this only prints it; the two must not drift, so there is no
  # second list of fields here.
  defp brief(shell, id, opts) do
    case Environments.brief_by_id(id) do
      :error ->
        shell.error("no environment #{id}")

      {:ok, brief} ->
        if opts[:json] || brief["rows"] do
          # A decision brief is rows of evidence; JSON is its only useful form.
          shell.info(Loader.pretty!(brief))
        else
          shell.info(brief["id"])
          shell.info("  app    #{brief["app"]}")
          shell.info("  edit   #{Enum.join(brief["source_paths"], "\n         ")}")
          shell.info("")

          case brief["statement"] do
            nil -> shell.info("  (no statement — this one is not ready to hand to anybody)")
            statement -> Enum.each(String.split(statement, "\n"), &shell.info("  " <> &1))
          end
        end
    end
  end

  defp render(shell, environment) do
    verification = environment["verification"] || %{}

    shell.info(environment["id"])
    shell.info("  ANSWER SHEET — this is the maintainer's view. `--brief` is a solver's.")
    shell.info("  set          #{environment["set"] || "(none)"}")
    shell.info("  state        #{Environments.state(environment)}")
    render_verifier(shell, environment)

    if reason = verification["reason"] do
      shell.info("  verification #{reason}")
    end

    shell.info("")

    case environment["statement"] do
      nil -> shell.info("  (no statement — there is nothing to hand an agent yet)")
      statement -> Enum.each(String.split(statement, "\n"), &shell.info("  " <> &1))
    end
  end

  defp render_verifier(shell, %{"verifier" => %{"kind" => "decision"} = verifier}) do
    shell.info("  question     #{verifier["question"]}@#{verifier["version"]}")
    shell.info("  corpus       #{verifier["corpus"]}, #{length(verifier["rows"])} rows")
    shell.info("  populations  #{Enum.join(verifier["populations"] || [], ", ")}")
    shell.info("  thresholds   #{inspect(verifier["thresholds"])}")
  end

  defp render_verifier(shell, environment) do
    shell.info("  app          #{environment["verifier"]["app"]}")
    shell.info("  verifier     #{Enum.join(environment["verifier"]["files"], " ")}")

    shell.info(
      "  source       #{Enum.join(environment["verifier"]["source_paths"], "\n               ")}"
    )

    shell.info("  fix          #{environment["source"]["fix"]}")
    shell.info("  parent       #{environment["source"]["parent"]}")
  end

  defp derive(shell, opts) do
    with {:ok, environment} <- Environments.derive(opts[:derive], id: opts[:id]),
         {:ok, environment} <- Environments.put(environment) do
      shell.info("derived #{environment["id"]} (#{environment["verifier"]["app"]})")
      shell.info("  verifier #{Enum.join(environment["verifier"]["files"], " ")}")
      shell.info("")
      shell.info("It is unverified and in no set. Write its `statement` — the commit message")
      shell.info("is the answer sheet and must not become the task — then:")
      shell.info("  noetic-harness environments --verify #{environment["id"]}")
    else
      {:error, reason} -> shell.error(reason)
    end
  end

  defp derive_decision(shell, opts) do
    with {:ok, environment} <-
           Decision.derive(
             opts[:derive_decision],
             Keyword.take(opts, [:corpus, :from, :part, :id, :bead])
           ),
         {:ok, environment} <- Environments.put(environment) do
      shell.info("derived #{environment["id"]}: #{environment["title"]}")
      shell.info("  populations #{Enum.join(environment["verifier"]["populations"], ", ")}")
      shell.info("")
      shell.info("It is unverified and in no set:")
      shell.info("  noetic-harness environments --verify #{environment["id"]}")
    else
      {:error, reason} -> shell.error(reason)
    end
  end

  defp score(shell, opts) do
    with {:ok, environment} <- fetch_decision(opts[:score]),
         {:ok, answers} <- Decision.read_answers(caller_path(opts[:answers])),
         {:ok, reference} <- reference(environment, opts[:reference]),
         {:ok, report} <- Decision.score(environment, answers, reference: reference) do
      if opts[:json], do: shell.info(Loader.pretty!(report)), else: print_report(shell, report)

      if opts[:record] do
        case Decision.record(report,
               answers_file: caller_path(opts[:answers]),
               by: Environments.attribution()
             ) do
          {:ok, path} -> shell.info("recorded #{Path.relative_to_cwd(path)}")
          {:error, reason} -> shell.error(reason)
        end
      end
    else
      {:error, reason} -> shell.error(reason)
    end
  end

  defp fetch_decision(nil), do: {:error, "--score <environment id> is required"}

  defp fetch_decision(id) do
    case Environments.fetch(id) do
      {:ok, %{"verifier" => %{"kind" => "decision"}} = environment} -> {:ok, environment}
      {:ok, _} -> {:error, "#{id} is not a decision environment; it is scored by Scoring"}
      :error -> {:error, "no environment #{id}"}
    end
  end

  defp reference(_environment, nil), do: {:ok, nil}

  defp reference(environment, "conductor") do
    if environment["verifier"]["question"] == "failure.class",
      do: {:ok, Decision.conductor_answers(environment)},
      else: {:error, "--reference conductor answers failure.class only"}
  end

  defp reference(_environment, file), do: Decision.read_answers(caller_path(file))

  # `noetic-harness` runs mix from the harness's own app, so a relative path on
  # its command line is resolved against the caller's directory, which it
  # passes as NOETIC_HARNESS_CALLER_DIR — `usage --transcript`'s rule. The
  # first real `--score` read `.agents/...` against `apps/noetic_harness` and
  # answered "no answers file".
  defp caller_path(nil), do: nil

  defp caller_path(path),
    do: Path.expand(path, System.get_env("NOETIC_HARNESS_CALLER_DIR") || File.cwd!())

  defp print_report(shell, r) do
    shell.info(
      "#{r["environment"]} · #{r["question"]} · #{r["rows"]} rows, #{r["answered"]} answered"
    )

    shell.info(
      "accuracy #{r["accuracy"]} · always #{r["baseline"]["label"]} #{r["baseline"]["accuracy"]}" <>
        if(r["reference"], do: " · reference #{r["reference"]["accuracy"]}", else: "")
    )

    shell.info(
      "ECE #{r["ece"]} (ceiling #{r["thresholds"]["max_ece"]}) · " <>
        "#{r["confident_wrong"]["count"]} wrong at >= #{r["confident_wrong"]["at"]} " <>
        "(#{r["confident_wrong"]["rate"]}, ceiling #{r["thresholds"]["max_confident_wrong"]})"
    )

    if ref = r["reference"] do
      shell.info(
        "right where the reference is wrong: #{length(ref["right_where_reference_wrong"])} · " <>
          "wrong where it is right: #{length(ref["wrong_where_reference_right"])}"
      )
    end

    shell.info("selective risk")

    for %{"at" => at, "coverage" => c, "risk" => risk} <- r["selective"],
        do: shell.info("  p >= #{at}: coverage #{c}, error #{inspect(risk)}")

    shell.info(if r["passed"], do: "PASSED", else: "FAILED")
    for failure <- r["failures"], do: shell.info("  #{failure}")
  end

  defp verify(shell, ids, none \\ "every environment has been verified at least once.") do
    if ids == [] do
      shell.info(none)
    end

    Enum.each(ids, fn id ->
      shell.info(
        case Environments.fetch(id) do
          {:ok, %{"verifier" => %{"kind" => "decision"}}} ->
            "verifying #{id} — against its labels and four answerers built from them"

          _ ->
            "verifying #{id} — in a git worktree of its own, at HEAD, thrown away after"
        end
      )

      case Environments.verify(id, Environments.attribution()) do
        {:ok, environment} ->
          verification = environment["verification"]
          shell.info("  #{String.upcase(verification["state"])}  #{verification["reason"]}")

        {:error, reason} ->
          shell.error("  #{reason}")
      end
    end)
  end

  defp verify_at_fix(shell, id) do
    shell.info("verifying #{id} — in a git worktree at its fix commit, thrown away after")

    case Environments.verify_at_fix(id, Environments.attribution()) do
      {:ok, environment} ->
        verdict = environment["verification_at_fix"]
        shell.info("  #{String.upcase(verdict["state"])}  #{verdict["reason"]}")
        shell.info("  recorded as verification_at_fix; `verification` and the set are unchanged")

      {:error, reason} ->
        shell.error("  #{reason}")
    end
  end

  defp stale_ids do
    Environments.current_head() |> Environments.stale() |> Enum.map(& &1["id"])
  end

  defp unverified_ids do
    Environments.list(state: "unverified") |> Enum.map(& &1["id"])
  end

  defp assign(shell, opts) do
    case Environments.assign(opts[:assign], opts[:set]) do
      {:ok, environment} ->
        shell.info(
          "#{environment["id"]} is in the #{environment["set"]} set. This does not move."
        )

      {:error, reason} ->
        shell.error(reason)
    end
  end

  defp filters(opts) do
    Enum.reject([set: opts[:set]], fn {_key, value} -> is_nil(value) end)
  end
end
