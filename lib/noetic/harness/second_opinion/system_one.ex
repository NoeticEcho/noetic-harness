defmodule Noetic.Harness.SecondOpinion.SystemOne do
  @moduledoc """
  A second opinion on a route from a local `POST /v1/systemone` server,
  asked the versioned `route.workflow` question
  (`.agents/decisions/questions/`).

  **No new dependency.** `:httpc`, whose application this app already declares
  for `Adapter.HTTP`. The harness's zero-hex-dependency property is what lets
  `noetic-harness hook` load its beams with `-pa` and answer in about a second, and
  a model client with a NIF could not be added at any price.

  **Not configured by default.** `config :noetic_harness, :second_opinion,
  #{inspect(__MODULE__)}` turns it on; `:system_one_url` moves it (default
  `http://127.0.0.1:8765`, the address `scripts/systemone_server.py` binds).

  **On the development laptop it will never answer in time**, and that is the
  correct outcome rather than a defect: a warm Laya answer is ~2 s
  and `SecondOpinion.deadline/0` is 250 ms. The HTTP timeout here
  is set under that deadline, so a slow model is a timed-out request that
  `SecondOpinion` reads as no opinion — never a route delayed past its budget,
  never a guess. A server that is down, loading, or answering nonsense is the
  same no opinion.
  """

  @behaviour Noetic.Harness.SecondOpinion

  alias Noetic.Harness.{Questions, SecondOpinion}

  @question "route.workflow"

  @doc "Where the server is."
  @spec base_url() :: String.t()
  def base_url,
    do: Application.get_env(:noetic_harness, :system_one_url, "http://127.0.0.1:8765")

  @impl true
  def consult(%{title: title}) when is_binary(title) and title != "" do
    with {:ok, question} <- question(),
         {:ok, answer} <-
           post(%{"state" => %{"title" => title}, "questions" => %{@question => question}}),
         %{"choice" => id} = verdict when is_binary(id) <- get_in(answer, ["answers", @question]) do
      {:ok, %{workflow: id, why: why(verdict)}}
    else
      _ -> :error
    end
  end

  def consult(_route), do: :error

  defp question do
    case Enum.find(Questions.list(), &(&1["id"] == @question)) do
      nil ->
        :error

      q ->
        {:ok,
         %{"type" => "choice", "instructions" => q["instructions"], "criteria" => q["criteria"]}}
    end
  end

  defp post(body) do
    # Under the deadline, so that the request gives up before SecondOpinion
    # stops waiting and nothing is left running behind the answer.
    timeout = SecondOpinion.deadline() - 10

    request =
      {~c"#{base_url()}/v1/systemone", [], ~c"application/json",
       IO.iodata_to_binary(:json.encode(body))}

    case :httpc.request(:post, request, [timeout: timeout, connect_timeout: timeout], []) do
      {:ok, {{_, 200, _}, _headers, reply}} -> {:ok, JSON.decode!(IO.iodata_to_binary(reply))}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp why(verdict) do
    case verdict["probabilities"] do
      %{} = p when map_size(p) > 0 ->
        "#{@question} p=#{:erlang.float_to_binary(Map.get(p, verdict["choice"], 0) / 1, decimals: 2)}"

      _ ->
        @question
    end
  end
end
