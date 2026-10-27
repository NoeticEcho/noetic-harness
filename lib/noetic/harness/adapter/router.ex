defmodule Noetic.Harness.Adapter.Router do
  @moduledoc """
  Several providers behind one endpoint.

  This is the adapter that makes "several keys, several providers" a
  *configuration* rather than a change to this repository. It speaks the
  OpenAI-compatible chat-completions shape, which LiteLLM, OpenRouter and most
  self-hosted gateways all accept, and it names the model per request. Which
  provider that model belongs to, and whose key pays for it, is the router's
  business and deliberately not ours.

      NOETIC_MODEL_ROUTER_URL=https://openrouter.ai/api/v1    # or a LiteLLM you run
      NOETIC_MODEL_ROUTER_KEY=<the router's key, not a provider's>

  ## Why one key and not several

  The obvious design is a key per provider in this process. It is the wrong
  one: every provider added is another secret in another environment variable,
  another place it can be logged, and another thing to rotate. A router holds
  the provider keys, and this holds one key to the router. Rotating a provider
  then touches nothing here.

  ## A better model is not more trust

  A router can reach a model more capable than the one the policy would have
  chosen, and it changes nothing about what the dispatched agent may do.
  `Policy.derive_trust/3` is the only place trust is decided and it only
  narrows. If that stops being true, this module is not where it broke.

  ## Same limitation as the API adapter

  One message, one reply, no tools. Right for reading and drafting; wrong for a
  step that has to edit files and run a test suite. `claude -p` is the agent;
  this is a completion.
  """

  @behaviour Noetic.Harness.Adapter

  alias Noetic.Harness.Adapter.HTTP

  @max_tokens 16_000

  @impl true
  def available?, do: Noetic.Harness.Adapter.credentials("router")

  @impl true
  def call(prompt, opts) do
    with {:ok, base} <- env("NOETIC_MODEL_ROUTER_URL"),
         {:ok, key} <- env("NOETIC_MODEL_ROUTER_KEY"),
         {:ok, model} <- model(opts) do
      body = %{
        model: model,
        max_tokens: Keyword.get(opts, :max_tokens, @max_tokens),
        messages: [%{role: "user", content: prompt}]
      }

      case HTTP.post_json(endpoint(base), [{"authorization", "Bearer " <> key}], body) do
        {:ok, doc} -> {:ok, shape(doc, model)}
        {:error, message} -> {:error, message}
      end
    end
  end

  # A base URL with or without the trailing path, because both are what people
  # paste. Getting this wrong produces a 404 that reads like a broken key.
  defp endpoint(base) do
    trimmed = String.trim_trailing(base, "/")

    if String.ends_with?(trimmed, "/chat/completions"),
      do: trimmed,
      else: trimmed <> "/chat/completions"
  end

  defp env(name) do
    case System.get_env(name) do
      value when value in [nil, ""] ->
        {:error, "#{name} is not set, so this adapter is unavailable"}

      value ->
        {:ok, value}
    end
  end

  defp model(opts) do
    case Keyword.get(opts, :model) do
      nil ->
        {:error,
         "no model was named, and a router without a model name is a router " <>
           "choosing for you. `.agents/policies/models.json` maps a trust level to one"}

      model ->
        {:ok, model}
    end
  end

  defp shape(doc, model) do
    %{
      output: text(doc),
      cost_usd: nil,
      usage: doc["usage"] || %{},
      turns: 1,
      denials: [],
      session: doc["id"],
      model: doc["model"] || model,
      stop_reason: doc |> choices() |> List.first() |> then(&(&1 && &1["finish_reason"])),
      adapter: "router"
    }
  end

  defp text(doc) do
    doc
    |> choices()
    |> List.first()
    |> case do
      %{"message" => %{"content" => content}} when is_binary(content) -> content
      _ -> ""
    end
  end

  defp choices(doc) do
    case doc["choices"] do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
