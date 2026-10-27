defmodule Noetic.Harness.Adapter.HTTP do
  @moduledoc """
  The one POST the two key-bearing adapters need.

  ## Why `:httpc` and not `Req`

  `noetic_harness` has **zero hex dependencies** — `JSON` is built in and
  `boundary` is compile-time only — and that is a property worth more than the
  ergonomics of a nicer client. The harness is what an agent reaches for when
  it is working out whether the rest of the repository compiles; a harness that
  cannot start because a transitive dependency of its HTTP client failed to
  resolve is a harness that is not there when it is needed. `:httpc` ships with
  OTP.

  The cost is real and is stated rather than hidden: no connection pooling, no
  retries, no streaming, and an API that takes charlists. None of those matter
  for one request per dispatched step that already takes minutes.

  ## What it never does

  It never logs, returns or includes in an error the value of a header. A
  failed request reports the status and the body; the `Authorization` header
  the caller built is not part of either. The one place a key could escape into
  a transcript is an exception message, so the exception messages here are
  written by hand.
  """

  @doc """
  POST JSON, get JSON.

  `headers` is a list of `{name, value}` string pairs and is treated as secret
  in its entirety: nothing here puts it in a message.
  """
  @spec post_json(String.t(), [{String.t(), String.t()}], map(), timeout()) ::
          {:ok, map()} | {:error, String.t()}
  def post_json(url, headers, body, timeout \\ 10 * 60 * 1000) do
    with :ok <- ensure_started(),
         {:ok, encoded} <- encode(body) do
      request =
        {String.to_charlist(url),
         Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end),
         ~c"application/json", encoded}

      case :httpc.request(:post, request, [{:timeout, timeout}], body_format: :binary) do
        {:ok, {{_version, status, _reason}, _headers, response}} when status in 200..299 ->
          decode(response)

        {:ok, {{_version, status, _reason}, _headers, response}} ->
          {:error, "the provider answered #{status}: #{excerpt(response)}"}

        {:error, reason} ->
          # `inspect(reason)` on an httpc failure carries the URL and never the
          # headers, which is why this is safe to print and the headers are not.
          {:error, "the request did not complete: #{inspect(reason)}"}
      end
    end
  end

  # `:inets` and `:ssl` are OTP applications rather than dependencies, and
  # neither is started by this umbrella — the harness is a CLI, not a server.
  defp ensure_started do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      :ok
    else
      {:error, reason} -> {:error, "could not start the HTTP client: #{inspect(reason)}"}
    end
  end

  defp encode(body) do
    {:ok, JSON.encode!(body)}
  rescue
    error -> {:error, "the request body could not be encoded: #{Exception.message(error)}"}
  end

  defp decode(response) do
    case JSON.decode(response) do
      {:ok, doc} -> {:ok, doc}
      {:error, _} -> {:error, "the provider did not return JSON: #{excerpt(response)}"}
    end
  end

  defp excerpt(body) when is_binary(body), do: body |> String.slice(0, 500) |> String.trim()
  defp excerpt(body), do: body |> to_string() |> excerpt()
end
