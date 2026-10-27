defmodule Noetic.Harness.AdapterTest do
  @moduledoc """
  The adapters are the only part of the harness that can spend money, so the
  first property tested is that this suite does not.

  This file is about *choosing* an adapter: the id-to-module table, the
  trust-to-model mapping, and credentials. Nothing here runs one. Where the
  choice depends on `claude` being installed, a stand-in `claude` is put
  first on `PATH`. It refuses to run, so a regression that starts executing
  it fails loudly instead of calling the real one behind it. A test with
  `PATH` emptied pins what a machine without Claude Code gets.

  Running `claude -p` against a fake that answers, and the one `:live` test
  against a real model, are in `Noetic.Harness.Adapter.ClaudeCodeTest`.
  """

  # async: false: these tests repoint PATH and application environment, both of
  # which are process-global.
  use ExUnit.Case, async: false

  alias Noetic.Harness.Adapter

  # On the pack (`Noetic.Harness.Pack`).
  setup {Noetic.Harness.Pack, :root}

  @env ~w(ANTHROPIC_API_KEY NOETIC_MODEL_ROUTER_URL NOETIC_MODEL_ROUTER_KEY)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    previous_id = Application.get_env(:noetic_harness, :dispatch_adapter_id)

    # A developer with a key in their environment must not get different
    # results from CI, so every test starts from "no credentials".
    Enum.each(@env, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      if previous_id,
        do: Application.put_env(:noetic_harness, :dispatch_adapter_id, previous_id),
        else: Application.delete_env(:noetic_harness, :dispatch_adapter_id)
    end)

    :ok
  end

  defp as(id) do
    Application.put_env(:noetic_harness, :dispatch_adapter_id, id)
  end

  # `claude_code` is available exactly when `System.find_executable("claude")`
  # finds something (`ClaudeCode.available?/0`; the policy gives it no `needs`).
  # The tests that resolve it are about what the *policy* gives each trust, and
  # they used to take `claude` from whatever machine ran them: green on the
  # workstation, where Claude Code is installed, and red on every GitHub run
  # since v0.5.0, where it is not. That was a test of the machine
  # wearing the name of a test of the policy.
  #
  # So they put a `claude` of their own on `PATH`, first, and the answer no
  # longer depends on what else is there. It refuses to run: resolving never
  # executes the binary, and a stand-in that answered would let a future
  # `resolve/1` that *did* execute it pass quietly — on a workstation, by
  # calling the real one behind it.
  defp claude_on_path!(tmp) do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)

    fake = Path.join(bin, "claude")

    File.write!(fake, """
    #!/bin/sh
    echo "stand-in claude from #{inspect(__MODULE__)}: resolving an adapter must not run it" >&2
    exit 97
    """)

    File.chmod!(fake, 0o755)
    path_is(Enum.join([bin | List.wrap(System.get_env("PATH"))], ":"))
    fake
  end

  defp path_is(path) do
    original = System.get_env("PATH")
    System.put_env("PATH", path)

    on_exit(fn ->
      if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
    end)
  end

  describe "choosing one" do
    test "the policy names an id, and the id-to-module table is in code" do
      # A policy file that could name a module would be a policy file that can
      # run arbitrary code. Every id the policy may use has to be here.
      {:ok, doc} = Adapter.policy()

      for %{"id" => id} <- doc["adapters"] do
        assert {:ok, module} = Adapter.module(id), "#{id} is in the policy and has no module"

        # An adapter that lives in another app is not loaded here, by design;
        # every other one must be.
        unless Map.has_key?(Adapter.elsewhere(), id), do: assert(Code.ensure_loaded?(module))
      end
    end

    test "an adapter that lives elsewhere is unavailable here, and says where" do
      # Not `refute Code.ensure_loaded?/1`: from the umbrella root the module
      # *is* loadable, and the first version of this test failed there.
      {:ok, module} = Adapter.module("jido")
      assert {:unavailable, why} = Adapter.available?(module, false)
      assert why =~ "my_app_agents"
    end

    test "an id nothing implements is unavailable, and says what does exist" do
      as("something-nobody-wrote")

      assert {:unavailable, why} = Adapter.resolve("T0")
      assert why =~ "no adapter is called"
      assert why =~ "claude_code"
      assert why =~ "models.json"
    end

    test "the default runs nothing" do
      # A default that dispatches for real is one misconfiguration away from
      # spending money in CI.
      assert Adapter.configured() == "null"
      assert {:ok, %{module: Noetic.Harness.Dispatcher.NullAdapter}} = Adapter.resolve("T0")
    end

    @tag :tmp_dir
    test "trust picks the model and whether there is a shell at all", %{tmp_dir: tmp} do
      claude_on_path!(tmp)
      as("claude_code")

      assert {:ok, %{model: "haiku", restricted: true}} = Adapter.resolve("T0")
      assert {:ok, %{model: "sonnet", restricted: true}} = Adapter.resolve("T1")
      assert {:ok, %{model: "sonnet", restricted: false}} = Adapter.resolve("T2")
      assert {:ok, %{model: "opus", restricted: false}} = Adapter.resolve("T3")
    end

    test "T4 and T5 have no entry, because they are not dispatched" do
      {:ok, doc} = Adapter.policy()
      levels = Enum.map(doc["by_trust"], & &1["trust"])

      refute "T4" in levels
      refute "T5" in levels
    end

    @tag :tmp_dir
    test "an unknown trust gets no model rather than a guessed one", %{tmp_dir: tmp} do
      claude_on_path!(tmp)
      as("claude_code")
      assert {:ok, %{model: nil}} = Adapter.resolve("T9")
    end

    @tag :tmp_dir
    test "without `claude` on PATH it is unavailable, and does not become another adapter",
         %{tmp_dir: tmp} do
      # The answer CI got for the two tests above, which no machine that has
      # Claude Code installed had ever produced. A `PATH` of one empty
      # directory holds it still: `resolve/1` runs no command on the way.
      empty = Path.join(tmp, "empty")
      File.mkdir_p!(empty)
      path_is(empty)
      as("claude_code")

      assert {:unavailable, why} = Adapter.resolve("T0")
      assert why =~ "`claude` is not on PATH"
      assert why =~ ":dispatch_adapter_id"
    end
  end

  describe "credentials" do
    test "a missing one is unavailable, and the dispatch does not become another adapter" do
      # §33. Falling back turns "which model produced this measurement?" into a
      # guess, and an earlier change's promotion gate has to answer it.
      as("api")
      assert {:unavailable, why} = Adapter.resolve("T0")
      assert why =~ "ANTHROPIC_API_KEY"

      as("router")
      assert {:unavailable, why} = Adapter.resolve("T0")
      assert why =~ "NOETIC_MODEL_ROUTER_URL"
      assert why =~ "NOETIC_MODEL_ROUTER_KEY"
    end

    test "the value is never read, only whether it is set" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-not-a-real-key-000")

      assert :ok = Adapter.credentials("api")
      assert {:ok, %{id: "api"}} = then(as("api"), fn _ -> Adapter.resolve("T0") end)
    end

    test "an empty string is not a credential" do
      System.put_env("ANTHROPIC_API_KEY", "")
      assert {:unavailable, _} = Adapter.credentials("api")
    end

    test "no message anywhere contains a credential's value" do
      secret = "sk-ant-SECRETVALUE-do-not-print"
      System.put_env("NOETIC_MODEL_ROUTER_KEY", secret)
      as("router")

      {:unavailable, why} = Adapter.resolve("T0")

      # Only the URL is missing now, and the message must name the variable
      # without ever having read the one that is set.
      assert why =~ "NOETIC_MODEL_ROUTER_URL"
      refute why =~ secret
    end
  end
end
