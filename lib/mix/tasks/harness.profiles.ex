defmodule Mix.Tasks.Harness.Profiles do
  @shortdoc "Who owns what: check profiles.json, or ask about one path"

  @moduledoc """
  `.agents/registry/profiles.json`, asked about.

      noetic-harness profiles                 # each profile and how many files it owns
      noetic-harness profiles --check         # every tracked file claimed, none twice
      noetic-harness profiles --who PATH      # the class of one path

  `--check` is `noetic-harness validate`'s `profiles` check on its own
  (`check_profiles` in `Noetic.Harness.Validation`), and exits non-zero
  on any error. It calls the validator's function rather than
  `Noetic.Harness.Profiles.validate/1`, which is only part of it, so the two
  commands cannot disagree about one file.
  """

  use Mix.Task

  alias Noetic.Harness.Profiles

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [check: :boolean, who: :string])
    shell = Mix.shell()

    if Noetic.Harness.Integrations.enabled?("workers"),
      do: run(opts, shell),
      else: shell.info(Noetic.Harness.Integrations.off("workers") <> ": there are no profiles")
  end

  defp run(opts, shell) do
    with {:ok, doc} <- Profiles.load(),
         {:ok, tracked} <- Profiles.tracked() do
      cond do
        opts[:check] -> check(shell)
        opts[:who] -> who(shell, doc, opts[:who])
        true -> summary(shell, doc, tracked)
      end
    else
      {:error, message} ->
        shell.error(message)
        exit({:shutdown, 1})
    end
  end

  defp check(shell) do
    findings = Noetic.Harness.Validation.check_profiles(nil)

    for {severity, message} <- findings do
      if severity == :error,
        do: shell.error("error    " <> message),
        else: shell.info("warning  " <> message)
    end

    errors = Enum.count(findings, &match?({:error, _}, &1))
    shell.info("#{errors} error(s), #{length(findings) - errors} warning(s)")
    if errors > 0, do: exit({:shutdown, 1})
  end

  defp who(shell, doc, path) do
    shell.info(
      case Profiles.classifier(doc).(path) do
        {:owned, [id]} -> "#{path}: #{id}'s"
        {:owned, ids} -> "#{path}: shared by #{Enum.join(ids, ", ")}"
        {:held, glob} -> "#{path}: coordinator-held (#{glob}); a grant, and --ack to land"
        {:fenced, glob} -> "#{path}: fenced (#{glob}); the person approves it"
        {:refused, glob} -> "#{path}: refused (#{glob}); no epic changes it"
        {:add_only, glob} -> "#{path}: add-only (#{glob}); any epic adds, none modifies"
        {:per_epic, glob} -> "#{path}: per-epic (#{glob}); only its own epic writes it"
        :unowned -> "#{path}: nobody's, which `--check` reports"
      end
    )
  end

  defp summary(shell, doc, tracked) do
    classify = Profiles.classifier(doc)
    counts = Enum.frequencies_by(tracked, &label(classify.(&1)))

    for {label, count} <- Enum.sort_by(counts, fn {_label, count} -> -count end) do
      shell.info(String.pad_leading(Integer.to_string(count), 6) <> "  " <> label)
    end
  end

  defp label({:owned, ids}), do: Enum.join(ids, " + ")
  defp label({class, _glob}), do: Atom.to_string(class)
  defp label(:unowned), do: "unowned"
end
