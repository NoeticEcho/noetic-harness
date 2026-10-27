defmodule Mix.Tasks.Harness.Hook do
  @shortdoc "Answer a Claude Code hook: session_start, user_prompt, pre_tool, session_end"

  @moduledoc """
  The harness as a Claude Code hook, by event.

      noetic-harness hook session_start
      noetic-harness hook user_prompt      # the hook's JSON payload on stdin
      noetic-harness hook pre_tool
      noetic-harness hook session_end

  A hook's settings name this command and the event. It reads the hook's own
  JSON payload on stdin and prints what the hook injects:

  - for `session_start`, `user_prompt` and `pre_tool`, Claude Code's envelope,
    `hookSpecificOutput.additionalContext`, from `Noetic.Harness.Attach`; or
    nothing, when there is nothing worth injecting;
  - for `session_end`, the one word `Noetic.Harness.Usage.outcome/1` returns
    after recording what the session cost against the open run.

  ## Which failures are failures

  A known event never fails: a hook that exits non-zero, or prints something
  that is not JSON, damages the session it was meant to help. A failure inside
  the harness becomes no output and status 0, and `Attach` already turns its
  own failures into a line of injected text.

  An event the harness does not know is the opposite case. It is a mistake in
  the hook's settings, not a failure during a session, and staying quiet would
  hide it for good. So it is refused: the events it knows are named on
  standard error, and the status is not 0.

  ## Where it is fast

  In the single executable this is the whole hook. From a checkout, `mix`
  boots first and costs about a second and a half more than the work; the
  development repository's own hook script runs the same modules straight
  off the compiled beams, with a time budget around them, and stays the
  faster path there.
  """

  use Mix.Task

  alias Noetic.Harness.{Attach, Hooks, Usage}

  @requirements ["app.config"]

  @impl Mix.Task
  def run([event]) do
    if event in Hooks.events(), do: answer(event), else: unknown(event)
  end

  def run(_args) do
    Mix.raise(
      "hook takes exactly one event, and the hook's JSON payload on stdin: " <>
        Enum.join(Hooks.events(), ", ")
    )
  end

  defp unknown(event) do
    Mix.raise(
      "hook: no event #{inspect(event)}. The events are " <> Enum.join(Hooks.events(), ", ")
    )
  end

  defp answer(event) do
    IO.write(safely(event, payload()))
  end

  defp safely(event, payload) do
    if event == "session_end",
      do: Usage.outcome(payload),
      else: Attach.hook_json(event, payload)
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
  end

  defp payload do
    raw =
      case IO.read(:stdio, :eof) do
        data when is_binary(data) -> data
        _ -> ""
      end

    case JSON.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end
end
