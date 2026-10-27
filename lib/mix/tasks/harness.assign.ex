defmodule Mix.Tasks.Harness.Assign do
  @shortdoc "Give an epic to a profile, refusing a scope another live epic shares"

  @moduledoc """
  Give an epic to a profile, or refuse to (plan 02 §3).

      noetic-harness assign --epic E --profile P [--session URL] [--slug S]
                         [--scope GLOB]... [--grant GLOB]... [--adr N]...
                         [--ack] [--reassign] [--dry-run] [--by NAME]
      noetic-harness assign --release E [--dry-run] [--by NAME]

  The scope is the profile's paths (`.agents/registry/profiles.json`), or the
  `--scope` globs, which must stay inside them. A `--grant` is a path outside
  the profile; a coordinator-held or fenced one needs `--ack`, and `.beads/**`
  is never granted. It refuses, naming the files, when the epic's tracked files
  meet another live epic's, when the profile holds its `max_concurrent`
  already, or when an `--adr` number is taken. Every reason is printed at once.

  On success it prints the brief. Unless `--dry-run`, it records the
  assignment in bd (assignee, status `in_progress`, label `profile:P`, and an
  assignment block in the notes) and writes a coordination record under
  `.agents/coordination/`. `--dry-run` asks bd for the epic's text and its
  status, and writes nothing, in bd or on disk.

  `--reassign` moves a live epic to a new branch, `claude/<epic>-<slug>-<n>`;
  `--release` ends a live assignment without a new one. Both record the old
  branch's head sha.

  It runs where bd is: the coordinator's workstation. A cloud worker has no bd
  and never assigns.
  """

  use Mix.Task

  alias Noetic.Harness.{Assign, Beads}

  # The bd calls go through this module. `:assign_beads` replaces it in the
  # tests, which must not read or write this repository's tracker.
  defp beads, do: Application.get_env(:noetic_harness, :assign_beads, Beads)

  @requirements ["app.config"]

  @switches [
    epic: :string,
    profile: :string,
    session: :string,
    slug: :string,
    scope: :keep,
    grant: :keep,
    adr: :keep,
    ack: :boolean,
    reassign: :boolean,
    release: :string,
    dry_run: :boolean,
    by: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    # The coordinator protocol is an integration: a repository
    # without it is told so, and nothing is planned, written or run.
    if Noetic.Harness.Integrations.enabled?("workers"),
      do: run(opts, :workers),
      else:
        Mix.shell().info(Noetic.Harness.Integrations.off("workers") <> ": nothing is assigned")
  end

  defp run(opts, :workers) do
    live = Assign.live(status: fn epic -> beads().status(epic) end)

    case opts[:release] do
      nil -> assign(opts, live)
      epic -> release(epic, opts, live)
    end
  end

  defp assign(opts, live) do
    epic = opts[:epic] || Mix.raise("--epic is required (or --release E)")

    request = %{
      epic: epic,
      profile: opts[:profile],
      session: opts[:session],
      scope: Keyword.get_values(opts, :scope),
      grants: Keyword.get_values(opts, :grant),
      adrs: Enum.map(Keyword.get_values(opts, :adr), &adr!/1),
      ack: opts[:ack] == true,
      reassign: opts[:reassign] == true
    }

    case Assign.plan(request, live: live) do
      {:error, reasons} ->
        refuse(epic, reasons)

      {:ok, plan} ->
        {title, text} = bead(epic, opts[:dry_run])
        branch = Assign.branch(plan, opts[:slug] || Assign.slug(title))
        brief = Assign.brief(plan, branch, text)
        act = if plan.previous, do: "reassign", else: "assign"

        record =
          Assign.record(act, plan,
            at: now(),
            nonce: nonce(),
            by: opts[:by] || System.get_env("BEADS_ACTOR"),
            branch: branch,
            previous_head: plan.previous && Assign.head(plan.previous["branch"])
          )

        report(plan)

        if opts[:dry_run] do
          Mix.shell().info("dry run: bd and .agents/coordination/ are untouched\n")
        else
          commit!(
            fn ->
              beads().assign(
                epic,
                plan.profile,
                Assign.notes(record, branch),
                Assign.holder(plan)
              )
            end,
            record
          )
        end

        IO.write(brief)
    end
  end

  defp release(epic, opts, {live, _unscoped}) do
    previous = Map.get(live, epic) || Mix.raise("#{epic} has no live assignment to release")

    record =
      Assign.release_record(previous,
        at: now(),
        nonce: nonce(),
        by: opts[:by] || System.get_env("BEADS_ACTOR"),
        previous_head: Assign.head(previous["branch"])
      )

    if opts[:dry_run] do
      Mix.shell().info("dry run: would release #{epic} from #{previous["branch"]}")
    else
      note = "released (noetic-harness assign --release, #{record["id"]}): #{previous["branch"]}"
      commit!(fn -> beads().release(epic, previous["profile"], note) end, record)
    end
  end

  # bd first, because it is the step that can fail on its own; the record is
  # written only after it did not.
  defp commit!(bd, record) do
    with :ok <- bd.(),
         {:ok, path} <- Assign.write(record) do
      Mix.shell().info("recorded: #{Path.relative_to(path, Noetic.Harness.root())}\n")
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp bead(epic, dry_run?) do
    case beads().work_item(epic) do
      {:ok, item} ->
        {item.title, item.body}

      other when dry_run? == true ->
        {nil, "(bd did not answer (#{inspect(other)}), so the epic's text is not in this brief)"}

      other ->
        Mix.raise("bd did not answer for #{epic} (#{inspect(other)}); assign runs where bd is")
    end
  end

  defp report(plan) do
    shell = Mix.shell()

    shell.info(
      "#{plan.epic} → #{plan.profile}: #{plan.files} tracked file(s) in scope and grants"
    )

    for glob <- plan.unmatched,
        do: shell.info("  #{glob} matches no tracked file yet (a file the epic will add)")

    if plan.unscoped > 0,
      do:
        shell.info(
          "  #{plan.unscoped} older coordination record(s) carry no scope and were not compared"
        )
  end

  defp refuse(epic, reasons) do
    Mix.shell().error("refused: #{epic}")
    for reason <- reasons, do: Mix.shell().error("  - " <> reason)
    exit({:shutdown, 1})
  end

  defp adr!(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> Mix.raise("--adr takes a number, not #{inspect(value)}")
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp nonce, do: :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
end
