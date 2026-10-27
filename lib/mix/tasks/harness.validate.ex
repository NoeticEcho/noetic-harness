defmodule Mix.Tasks.Harness.Validate do
  @moduledoc """
  Check that the harness's definitions are internally consistent.

      noetic-harness validate                     everything
      noetic-harness validate --only registry,skills
      noetic-harness validate --strict            warnings fail too

  This is the gate. It is what turns every claim the harness makes — that a
  role's skills exist, that a gate's holder is a real role, that every workflow
  step's capability is supplied by somebody, that all 270 roles compose a prompt
  — from documentation into something that fails.

  Exits non-zero on any error, and on any warning under `--strict`.
  """
  @shortdoc "Validate the harness definitions"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]
  alias Noetic.Harness.Validation

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [only: :string, strict: :boolean])
    shell = Mix.shell()

    checks =
      case opts[:only] do
        nil ->
          Validation.checks()

        given ->
          requested = given |> String.split([",", " "], trim: true) |> Enum.map(&String.to_atom/1)
          unknown = requested -- Validation.checks()

          if unknown != [],
            do:
              Mix.raise(
                "unknown check(s): #{Enum.join(unknown, ", ")}. Known: #{Enum.join(Validation.checks(), ", ")}"
              )

          requested
      end

    case Validation.run(checks) do
      {:error, message} ->
        shell.error(message)
        exit({:shutdown, 1})

      {:ok, findings} ->
        errors = for {:error, message} <- findings, do: message
        warnings = for {:warning, message} <- findings, do: message

        Enum.each(warnings, &shell.info("warning  #{&1}"))
        Enum.each(errors, &shell.error("error    #{&1}"))

        shell.info("")

        shell.info(
          "#{length(checks)} checks: #{length(errors)} error(s), #{length(warnings)} warning(s)"
        )

        cond do
          errors != [] -> exit({:shutdown, 1})
          warnings != [] and opts[:strict] -> exit({:shutdown, 1})
          true -> shell.info("harness definitions are consistent")
        end
    end
  end
end
