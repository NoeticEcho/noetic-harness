defmodule Noetic.Harness.Adapter.HTTPTest do
  @moduledoc """
  The two key-bearing adapters, and the one property that matters about them:
  a credential never reaches a message.

  Nothing here talks to a provider. The request either refuses before it is
  built, or goes to a closed port on loopback — which is a real socket error
  from the real client, and free.
  """

  # `async: false` (an earlier change — an eighth file with no written reason; the
  # bead listed six and missed the two under `adapter/`). Every test here sets
  # `ANTHROPIC_API_KEY`, `NOETIC_MODEL_ROUTER_KEY` or
  # `NOETIC_MODEL_ROUTER_URL` with `System.put_env/2`, and an environment
  # variable is a VM-global. Concurrently, one test's credential would be read
  # by another test's request — which is the failure this file exists to
  # detect, arriving from the wrong direction.
  use ExUnit.Case, async: false

  alias Noetic.Harness.Adapter.{Api, HTTP, Router}

  # The model policy is the pack's (`Noetic.Harness.Pack`).
  setup {Noetic.Harness.Pack, :root}

  # Port 1 on loopback: nothing listens, and it is not a service anyone runs.
  @closed "http://127.0.0.1:1/v1/messages"

  @secret "sk-ant-SECRET-must-never-appear-in-a-message"

  setup do
    previous =
      Map.new(
        ~w(ANTHROPIC_API_KEY NOETIC_MODEL_ROUTER_URL NOETIC_MODEL_ROUTER_KEY),
        &{&1, System.get_env(&1)}
      )

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(Map.keys(previous), &System.delete_env/1)
    :ok
  end

  describe "the client" do
    test "a connection that cannot be made is an error, not a crash" do
      assert {:error, why} = HTTP.post_json(@closed, [], %{a: 1}, 2_000)
      assert why =~ "did not complete"
    end

    test "the headers never appear in the failure" do
      # The one place a key could escape into a transcript is an exception
      # message, which is why the messages here are written by hand rather than
      # produced by inspecting the request.
      assert {:error, why} =
               HTTP.post_json(@closed, [{"x-api-key", @secret}], %{a: 1}, 2_000)

      refute why =~ @secret
      refute why =~ "SECRET"
    end
  end

  describe "the API adapter" do
    test "no key is unavailable, and the message names the variable not the value" do
      assert {:unavailable, why} = Api.available?()
      assert why =~ "ANTHROPIC_API_KEY"
    end

    test "a key present is available" do
      System.put_env("ANTHROPIC_API_KEY", @secret)
      assert :ok = Api.available?()
    end

    test "no model is refused rather than guessed" do
      # An adapter that picks a model when nobody told it is an adapter that
      # silently spends a T3 budget on a T0 step.
      System.put_env("ANTHROPIC_API_KEY", @secret)

      assert {:error, why} = Api.call("hello", cwd: "/tmp")
      assert why =~ "no model was named"
      assert why =~ "models.json"
    end

    test "no key is refused at call time too, not only at available?" do
      assert {:error, why} = Api.call("hello", model: "claude-haiku-4-5-20251001")
      assert why =~ "ANTHROPIC_API_KEY"
      refute why =~ @secret
    end
  end

  describe "the router adapter" do
    test "both variables are named when both are missing" do
      assert {:unavailable, why} = Router.available?()
      assert why =~ "NOETIC_MODEL_ROUTER_URL"
      assert why =~ "NOETIC_MODEL_ROUTER_KEY"
    end

    test "one present and one missing still refuses, naming the missing one" do
      System.put_env("NOETIC_MODEL_ROUTER_KEY", @secret)

      assert {:unavailable, why} = Router.available?()
      assert why =~ "NOETIC_MODEL_ROUTER_URL"
      refute why =~ @secret
    end

    test "no model is refused, because a router without one is a router choosing" do
      System.put_env("NOETIC_MODEL_ROUTER_URL", "http://127.0.0.1:1/v1")
      System.put_env("NOETIC_MODEL_ROUTER_KEY", @secret)

      assert {:error, why} = Router.call("hello", [])
      assert why =~ "choosing for you"
    end

    test "a base URL works with or without the completions path" do
      # Both are what people paste, and getting it wrong is a 404 that reads
      # like a broken key.
      System.put_env("NOETIC_MODEL_ROUTER_KEY", @secret)

      for base <- [
            "http://127.0.0.1:1/v1",
            "http://127.0.0.1:1/v1/",
            "http://127.0.0.1:1/v1/chat/completions"
          ] do
        System.put_env("NOETIC_MODEL_ROUTER_URL", base)

        # It reaches the socket, which means the URL was built; the connection
        # failing is the expected end of the journey here.
        assert {:error, why} = Router.call("hello", model: "anything")
        assert why =~ "did not complete"
        refute why =~ @secret
      end
    end
  end
end
