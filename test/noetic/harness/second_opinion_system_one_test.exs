defmodule Noetic.Harness.SecondOpinionSystemOneTest do
  @moduledoc """
  A local System One server as the route's second opinion — heard
  when it disagrees in time, silent when it is down or slow, and never able to
  delay the route past its budget. The server here is a socket in this test,
  because the property is about the harness, not about a model.
  """

  # `:second_opinion` and `:system_one_url` are application env keys, which
  # are VM-global: a concurrent routing test would consult this test's fake
  # server and print its disagreement.
  use ExUnit.Case, async: false

  alias Noetic.Harness.{Router, SecondOpinion}
  alias Noetic.Harness.SecondOpinion.SystemOne

  # The routes these comment on are the pack's (`Noetic.Harness.Pack`).
  setup {Noetic.Harness.Pack, :root}

  setup do
    keys = [:second_opinion, :system_one_url, :second_opinion_deadline_ms]
    previous = Map.new(keys, &{&1, Application.get_env(:noetic_harness, &1)})
    Application.put_env(:noetic_harness, :second_opinion, SystemOne)

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:noetic_harness, key, value),
          else: Application.delete_env(:noetic_harness, key)
      end
    end)
  end

  # One request, one canned reply after `delay` ms, then close.
  defp serve(reply, delay \\ 0) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      _request = read_request(socket, "")
      Process.sleep(delay)
      body = IO.iodata_to_binary(:json.encode(reply))

      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: " <>
          "#{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
      )

      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end)

    Application.put_env(:noetic_harness, :system_one_url, "http://127.0.0.1:#{port}")
  end

  defp read_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data

        with [head, body] <- String.split(acc, "\r\n\r\n", parts: 2),
             [_, length] <- Regex.run(~r/content-length: (\d+)/i, head),
             true <- byte_size(body) >= String.to_integer(length) do
          acc
        else
          _ -> read_request(socket, acc)
        end

      _ ->
        acc
    end
  end

  defp answer(workflow),
    do: %{
      "answers" => %{
        "route.workflow" => %{
          "type" => "choice",
          "choice" => workflow,
          "probabilities" => %{workflow => 0.61}
        }
      }
    }

  @title "the product channel crashes mid-ritual"

  # "In time" is `SecondOpinion.deadline/0`, and whether an answer lands inside
  # 250 ms is the machine's to say as much as the code's. With eight
  # busy processes on two schedulers this test failed 3 runs in 9, `line` nil,
  # exactly as it did on the loaded workstation: the fake server answered at
  # once and the answer was still late. These two tests are about what happens
  # to an answer *inside* the deadline, so they set one no machine running this
  # suite misses. The last two are about the deadline and keep the real one.
  defp in_time, do: Application.put_env(:noetic_harness, :second_opinion_deadline_ms, 30_000)

  test "a disagreement that arrives in time is printed, with the question and its probability" do
    in_time()
    {:ok, route} = Router.route(title: @title)
    theirs = if route.workflow["id"] == "WF-002", do: "WF-001", else: "WF-002"
    serve(answer(theirs))

    line = SecondOpinion.on(route)
    assert line =~ theirs
    assert line =~ "route.workflow p=0.61"
  end

  # Without `in_time/0` this passed on a late answer too, and said nothing
  # about agreement.
  test "agreement says nothing" do
    in_time()
    {:ok, route} = Router.route(title: @title)
    serve(answer(route.workflow["id"]))
    assert SecondOpinion.on(route) == nil
  end

  test "no server is no opinion, and the route is not delayed" do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    Application.put_env(:noetic_harness, :system_one_url, "http://127.0.0.1:#{port}")

    {:ok, route} = Router.route(title: @title)
    {micros, line} = :timer.tc(fn -> SecondOpinion.on(route) end)
    assert line == nil
    assert micros < (SecondOpinion.deadline() + 100) * 1000
  end

  test "a model slower than the deadline is no opinion, however it would have answered" do
    {:ok, route} = Router.route(title: @title)
    serve(answer("WF-020"), 2_000)

    {micros, line} = :timer.tc(fn -> SecondOpinion.on(route) end)
    assert line == nil
    assert micros < (SecondOpinion.deadline() + 100) * 1000
  end
end
