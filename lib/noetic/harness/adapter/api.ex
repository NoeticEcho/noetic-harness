defmodule Noetic.Harness.Adapter.Api do
  @moduledoc """
  The Anthropic API, with a key this process is given and never reads.

  For a dispatch that must not consume the interactive session, or must pin a
  model the CLI would not select. Prefer `Noetic.Harness.Adapter.ClaudeCode`
  where it works: it needs no key, and a credential that does not exist cannot
  leak.

  ## The key

  `ANTHROPIC_API_KEY`, from the environment, at the moment of the call. It is
  never written to a bead, a prompt, an artifact, a log line, a run ledger
  entry or an exception message. `available?/0` reports whether it is *set* and
  says nothing about what it is.

  Missing means `unavailable` and the dispatch is refused. It does not mean
  "try the CLI instead": §33, and an earlier change's promotion gate has to be able to
  say which model produced a measurement.

  ## What this is not

  **It has no tools.** This adapter sends one message and reads one reply,
  which makes it right for a T0 step that reads and maps and wrong for a T2
  step that has to edit files and run tests. `by_trust` in the policy is where
  that is decided; this module only reports what it did.

  That limitation is worth stating plainly because the shape of the two
  adapters is otherwise similar enough to hide it: `claude -p` is an *agent*
  with a working directory, and this is a *completion*.
  """

  @behaviour Noetic.Harness.Adapter

  alias Noetic.Harness.Adapter.HTTP

  @endpoint "https://api.anthropic.com/v1/messages"
  @version "2023-06-01"
  @max_tokens 16_000

  @impl true
  def available?, do: Noetic.Harness.Adapter.credentials("api")

  @impl true
  def call(prompt, opts) do
    with {:ok, key} <- key(),
         {:ok, model} <- model(opts) do
      body = %{
        model: model,
        max_tokens: Keyword.get(opts, :max_tokens, @max_tokens),
        messages: [%{role: "user", content: prompt}]
      }

      headers = [
        {"x-api-key", key},
        {"anthropic-version", @version}
      ]

      case HTTP.post_json(@endpoint, headers, body) do
        {:ok, doc} -> {:ok, shape(doc, model)}
        {:error, message} -> {:error, message}
      end
    end
  end

  defp key do
    case System.get_env("ANTHROPIC_API_KEY") do
      value when value in [nil, ""] ->
        {:error, "ANTHROPIC_API_KEY is not set, so this adapter is unavailable"}

      value ->
        {:ok, value}
    end
  end

  # No default model. The policy says which model a trust level gets, and an
  # adapter that picks one when nobody told it is an adapter that silently
  # spends a T3 budget on a T0 step.
  defp model(opts) do
    case Keyword.get(opts, :model) do
      nil ->
        {:error,
         "no model was named. `.agents/policies/models.json` maps a trust level " <>
           "to one, and this adapter does not guess"}

      model ->
        {:ok, model}
    end
  end

  defp shape(doc, model) do
    usage = doc["usage"] || %{}

    %{
      output: text(doc["content"]),
      cost_usd: nil,
      usage: usage,
      turns: 1,
      denials: [],
      session: doc["id"],
      model: doc["model"] || model,
      stop_reason: doc["stop_reason"],
      adapter: "api"
    }
  end

  # `cost_usd` is deliberately nil rather than computed. Pricing is not in the
  # response and a table of prices in this repository would be wrong within the
  # quarter and believed anyway. `usage` is the fact; the price is not ours.
  defp text(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
  end

  defp text(_), do: ""
end
