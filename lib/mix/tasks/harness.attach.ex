defmodule Mix.Tasks.Harness.Attach do
  @shortdoc "What a Claude Code hook injects: the route, the open run, the gates"

  @moduledoc """
  The harness, attached to a session rather than remembered by it.

      noetic-harness attach --event session_start
      echo '{"prompt":"fix the product channel"}' | noetic-harness attach --event user_prompt --hook-json

  `--hook-json` prints Claude Code's hook envelope on stdout and reads that
  hook's own JSON payload on stdin, exactly as `bd prime --hook-json` does.
  Without it the same text is printed plainly, which is how you look at what a
  hook would have said without installing it.

  ## It cannot fail

  Not "should not": the task exits 0 whatever happens, and a failure becomes a
  line of injected text saying what went wrong. A hook that exits non-zero, or
  prints something that is not JSON, damages the session it was supposed to
  help. `Noetic.Harness.Attach` catches; this task catches again around the
  encode, because the one thing worse than an unhelpful hook is an unparseable
  one.

  ## Prefer `noetic-harness hook`

  This task boots `mix`, which costs about a second and a half more than the
  work does. `noetic-harness hook` runs the same module straight off the compiled
  beams. `.claude/settings.json` uses that; this task exists so the behaviour
  has one implementation and so you can read it by hand.
  """

  use Mix.Task

  alias Noetic.Harness.Attach

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [event: :string, hook_json: :boolean, payload: :string])

    event = opts[:event] || "session_start"
    payload = payload(opts)

    if opts[:hook_json] do
      IO.write(safe_json(event, payload))
    else
      case Attach.context(event, payload) do
        :skip -> IO.puts("(nothing would be injected for this event)")
        {:ok, text} -> IO.write(text)
      end
    end
  end

  defp safe_json(event, payload) do
    Attach.hook_json(event, payload)
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
  end

  # stdin, `--payload`, or nothing. Reading stdin is what a hook does; the
  # option is for looking at one by hand without building a pipeline.
  defp payload(opts) do
    raw = opts[:payload] || read_stdin()

    case JSON.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      data when is_binary(data) -> data
      _ -> ""
    end
  end
end
