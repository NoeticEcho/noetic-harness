defmodule Mix.Tasks.Harness.Questions do
  @moduledoc """
  The versioned questions a decision model may be asked.

      noetic-harness questions                          every question, its version, whether it matches
      noetic-harness questions --bump <id> --why "..."  record an edit as a new version

  Editing a question file is allowed; leaving the edit unrecorded is not.
  `harness validate` fails on a question whose content no longer matches the
  fingerprint of its current version, and `--bump` is how an edit becomes a
  version: the old versions stay, because a decision citing a version nobody
  can find is worse than one citing nothing.
  """
  @shortdoc "List decision questions, or record an edit as a new version"

  use Mix.Task

  @requirements ["compile"]
  alias Noetic.Harness.Questions

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [bump: :string, why: :string])
    shell = Mix.shell()

    case opts[:bump] do
      nil ->
        for q <- Questions.list() do
          state = if Questions.check([q]) == [], do: "matches", else: "EDITED WITHOUT A BUMP"

          shell.info(
            "#{String.pad_trailing("#{q["id"]}@#{q["version"]}", 28)} " <>
              "#{String.pad_trailing(q["type"], 7)} #{state}"
          )
        end

      id ->
        why = opts[:why] || Mix.raise("--bump needs --why: a version nobody can explain is noise")

        case Questions.bump(id, why) do
          {:ok, version} -> shell.info("#{id} is now version #{version}")
          {:error, reason} -> Mix.raise(reason)
        end
    end
  end
end
