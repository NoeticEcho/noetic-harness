defmodule Noetic.Harness.HookMcpTasksTest do
  @moduledoc """
  `harness.hook` and `harness.mcp`: the hook and the MCP server
  as subcommands, `noetic-harness hook <event>` and `noetic-harness mcp`, so
  that a repository with no scripts of its own can name them.

  The executable's own `mcp` and `hook` are run by `CutTest`, in the public
  tree with no Erlang or Elixir in sight. These are the tasks themselves.
  """

  # async: false: moves the harness root, and the Mix shell is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Noetic.Harness.{CLI, Hooks}

  setup do
    root =
      Path.join(System.tmp_dir!(), "harness-hook-mcp-#{System.os_time(:microsecond)}")
      |> Noetic.Harness.Pack.populate()

    previous = Noetic.Harness.root_override()
    Noetic.Harness.put_root(root)

    on_exit(fn ->
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  describe "hook" do
    test "is a subcommand, as mcp is" do
      assert CLI.commands()["hook"] == Mix.Tasks.Harness.Hook
      assert CLI.commands()["mcp"] == Mix.Tasks.Harness.Mcp
    end

    test "answers a known event with Claude Code's envelope, from the payload on stdin" do
      payload = JSON.encode!(%{"prompt" => "fix the parser's handling of empty input"})
      out = capture_io(payload, fn -> assert CLI.main(["hook", "user_prompt"]) == 0 end)

      assert %{"hookSpecificOutput" => %{"hookEventName" => "UserPromptSubmit"} = envelope} =
               JSON.decode!(out)

      assert envelope["additionalContext"] =~ "workflow"
    end

    test "a payload that is not JSON is not a failure" do
      capture_io("not json", fn -> assert CLI.main(["hook", "session_start"]) == 0 end)
    end

    test "an unknown event exits non-zero and names the events it knows" do
      err =
        capture_io(:stderr, fn ->
          capture_io("{}", fn -> assert CLI.main(["hook", "frob"]) == 1 end)
        end)

      assert err =~ ~s(no event "frob")
      for event <- Hooks.events(), do: assert(err =~ event)
    end

    test "no event, or two, is refused the same way" do
      for args <- [["hook"], ["hook", "session_start", "user_prompt"]] do
        err = capture_io(:stderr, fn -> assert CLI.main(args) == 1 end)
        assert err =~ "hook takes exactly one event"
      end
    end
  end

  describe "mcp" do
    # A process of its own, as a client starts it: `serve/0` moves the logger
    # and reads stdin until it closes, neither of which a test process should.
    @tag timeout: 120_000
    test "answers initialize over stdio, and nothing else reaches stdout", %{root: root} do
      ebin = :code.which(Noetic.Harness.MCP) |> to_string() |> Path.dirname()

      messages = [
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "0"}
          }
        },
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}
      ]

      input = Path.join(root, "mcp-in.jsonl")
      File.write!(input, Enum.map_join(messages, "", &(JSON.encode!(&1) <> "\n")))

      {stdout, status} =
        System.cmd(
          "sh",
          [
            "-c",
            ~s|"$0" -pa "$1" -e 'Mix.Tasks.Harness.Mcp.run([])' < "$2" 2>/dev/null|,
            System.find_executable("elixir"),
            ebin,
            input
          ],
          env: [{"NOETIC_HARNESS_ROOT", root}]
        )

      assert status == 0
      replies = stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      assert Enum.map(replies, & &1["id"]) == [1, 2]
      assert hd(replies)["result"]["protocolVersion"] == "2025-06-18"
      assert hd(replies)["result"]["serverInfo"]["name"] == "noetic-harness"
      assert [_ | _] = List.last(replies)["result"]["tools"]
    end

    test "takes no arguments" do
      assert_raise Mix.Error, ~r/mcp takes no arguments/, fn ->
        Mix.Tasks.Harness.Mcp.run(["--stdio"])
      end
    end
  end
end
