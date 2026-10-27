defmodule Noetic.Harness.MCPTest do
  @moduledoc """
  The harness over MCP.

  Most of these are about what it must refuse: a tool on a writing task, a
  flag smuggled in an argument, a line on stdout that is not the protocol.
  """

  # async: false: `Mix.shell/1` is VM-global, and a tool call swaps it.
  use ExUnit.Case, async: false

  alias Noetic.Harness.MCP

  # The server runs on the pack (`Noetic.Harness.Pack`). `harness_kb_query`
  # answers from this repository's knowledge base and `noetic-harness mcp` is
  # this repository's script, so those are tagged `this_repository`.
  setup {Noetic.Harness.Pack, :root}

  setup do
    previous = Mix.shell()
    Mix.shell(Noetic.Harness.MCP.Shell)
    on_exit(fn -> Mix.shell(previous) end)

    {:ok, manifest} = MCP.manifest()
    {:ok, manifest: manifest}
  end

  defp tool(manifest, name), do: Enum.find(manifest["tools"], &(&1["name"] == name))

  describe "the manifest" do
    test "the one in .agents/ may be served", %{manifest: manifest} do
      assert MCP.validate(manifest) == []
    end

    test "a tool on a task outside the allow-list is refused" do
      for task <- ~w(run evolution dispatch sync) do
        manifest = %{"tools" => [%{"name" => "harness_x", "task" => task, "description" => "x"}]}
        assert [message] = MCP.validate(manifest)
        assert message =~ "not on the read-only allow-list"
      end
    end

    test "memory without --query, or gates without --plan, is refused" do
      memory = %{
        "name" => "harness_m",
        "task" => "memory",
        "description" => "x",
        "args" => [%{"name" => "query", "flag" => "--query", "type" => "string"}]
      }

      gates = %{"name" => "harness_g", "task" => "gates", "description" => "x"}

      assert [m] = MCP.validate(%{"tools" => [memory]})
      assert m =~ "does not always pass --query"
      assert [g] = MCP.validate(%{"tools" => [gates]})
      assert g =~ "must pass --plan to `gates` in `fixed`"
    end

    test "--plan as an argument the client sets is refused, even when required" do
      # Review: a required boolean validated clean and `{"plan": false}` then
      # ran the lane.
      gates = %{
        "name" => "harness_g",
        "task" => "gates",
        "description" => "x",
        "args" => [
          %{"name" => "plan", "flag" => "--plan", "type" => "boolean", "required" => true},
          %{"name" => "lane", "flag" => "--lane", "type" => "string", "required" => true}
        ]
      }

      assert [message] = MCP.validate(%{"tools" => [gates]})
      assert message =~ "in `fixed` and nowhere else"
    end

    test "route --bead and context --render are not servable" do
      # `bd show <id>` took flags from the id and wrote outside the repository
      # in review; `--render` prints the head of any path.
      for {task, flag} <- [{"route", "--bead"}, {"context", "--render"}] do
        tool = %{
          "name" => "harness_x",
          "task" => task,
          "description" => "x",
          "args" => [%{"name" => "x", "flag" => flag, "type" => "string"}]
        }

        assert [message] = MCP.validate(%{"tools" => [tool]})
        assert message =~ "#{flag}, which it may not be given"
      end
    end

    test "a writing flag on an allowed task is refused" do
      memory = %{
        "name" => "harness_m",
        "task" => "memory",
        "description" => "x",
        "fixed" => ["--add"],
        "args" => [%{"name" => "q", "flag" => "--query", "type" => "string", "required" => true}]
      }

      assert [message] = MCP.validate(%{"tools" => [memory]})
      assert message =~ "--add, which it may not be given"
    end

    test "harness.validate runs it" do
      assert :mcp in Noetic.Harness.Validation.checks()
    end
  end

  describe "arguments cannot become flags" do
    test "a value is one argv element", %{manifest: manifest} do
      assert {:ok, argv} = MCP.argv(tool(manifest, "harness_memory"), %{"query" => "--add"})
      assert argv == ["--query=--add"]
    end

    test "a positional value may not start with -", %{manifest: manifest} do
      prompt = tool(manifest, "harness_prompt")
      assert {:error, _} = MCP.argv(prompt, %{"agent" => "--check"})

      assert {:ok, ["backend.otp_architect"]} =
               MCP.argv(prompt, %{"agent" => "backend.otp_architect"})
    end

    test "an undeclared argument is refused rather than ignored", %{manifest: manifest} do
      assert {:error, message} =
               MCP.argv(tool(manifest, "harness_memory"), %{"query" => "x", "add" => true})

      assert message =~ "does not take add"
    end

    test "a missing required argument is refused", %{manifest: manifest} do
      assert {:error, message} = MCP.argv(tool(manifest, "harness_route"), %{})
      assert message =~ "needs title"
    end

    test "a list is joined, and one that could split differently is refused", %{
      manifest: manifest
    } do
      route = tool(manifest, "harness_route")

      assert {:ok, argv} = MCP.argv(route, %{"title" => "t", "paths" => ["a.ex", "b.ex"]})
      assert "--paths=a.ex,b.ex" in argv
      assert {:error, _} = MCP.argv(route, %{"title" => "t", "paths" => ["a.ex,--add"]})
    end

    test "null or empty for a required argument is missing, not present", %{manifest: manifest} do
      # Review: `{"query": null}` counted as present, emitted nothing, and
      # `memory` ran with no flags at all.
      for value <- [nil, ""] do
        assert {:error, message} = MCP.argv(tool(manifest, "harness_memory"), %{"query" => value})
        assert message =~ "needs query"
      end
    end

    test "paths must stay inside the repository", %{manifest: manifest} do
      context = tool(manifest, "harness_context")

      for bad <- ["/etc/passwd", "~/.ssh/id_ed25519", "../../outside", "a/../../b", "--x", ""] do
        assert {:error, _} = MCP.argv(context, %{"title" => "t", "paths" => [bad]}), bad
      end

      assert {:ok, _} =
               MCP.argv(context, %{"title" => "t", "paths" => ["apps/a.ex", "docs/b.md"]})
    end

    test "the argv is checked again, independently of the manifest" do
      assert :ok == MCP.argv_allowed("gates", ["--plan", "--lane=fast"])
      assert {:error, _} = MCP.argv_allowed("gates", ["--lane=full"])
      assert {:error, _} = MCP.argv_allowed("gates", ["--plan=false", "--lane=full"])
      assert {:error, _} = MCP.argv_allowed("gates", ["--plan", "--no-plan", "--lane=full"])
      assert {:error, _} = MCP.argv_allowed("memory", ["--query="])
      assert {:error, _} = MCP.argv_allowed("memory", ["--query=x", "--add"])
      assert {:error, _} = MCP.argv_allowed("memory", ["--query=x", "positional"])
      assert :ok == MCP.argv_allowed("prompt", ["backend.otp_architect"])
      assert {:error, _} = MCP.argv_allowed("run", ["--status"])
    end

    test "fixed flags come first and are always there", %{manifest: manifest} do
      assert {:ok, ["--plan", "--lane=fast"]} =
               MCP.argv(tool(manifest, "harness_gates_plan"), %{"lane" => "fast"})
    end
  end

  describe "the protocol" do
    test "initialize echoes a version it speaks and offers the newest otherwise", %{
      manifest: manifest
    } do
      ask = fn version ->
        %{"result" => result} =
          MCP.handle(
            %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "method" => "initialize",
              "params" => %{"protocolVersion" => version}
            },
            {:ok, manifest}
          )

        result
      end

      assert ask.("2025-06-18")["protocolVersion"] == "2025-06-18"
      assert ask.("1999-01-01")["protocolVersion"] == hd(MCP.protocol_versions())
      assert ask.("2025-06-18")["capabilities"] == %{"tools" => %{"listChanged" => false}}
    end

    test "tools/list is the manifest, every tool marked read-only", %{manifest: manifest} do
      %{"result" => %{"tools" => tools}} =
        MCP.handle(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}, {:ok, manifest})

      served = Enum.filter(manifest["tools"], &MCP.served?/1)
      assert Enum.map(tools, & &1["name"]) == Enum.map(served, & &1["name"])
      assert Enum.all?(tools, &(&1["annotations"]["readOnlyHint"] == true))
      assert Enum.all?(tools, &(&1["inputSchema"]["additionalProperties"] == false))
    end

    test "a tool call returns what the task printed", %{manifest: manifest} do
      %{"result" => result} =
        MCP.handle(
          %{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "tools/call",
            "params" => %{"name" => "harness_workflows", "arguments" => %{"show" => "WF-002"}}
          },
          {:ok, manifest}
        )

      assert result["isError"] == false
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert text =~ "WF-002"
    end

    test "a task's refusal is the tool's error text, not the server's stderr", %{
      manifest: manifest
    } do
      %{"result" => result} =
        MCP.handle(
          %{
            "jsonrpc" => "2.0",
            "id" => 4,
            "method" => "tools/call",
            "params" => %{"name" => "harness_workflows", "arguments" => %{"show" => "WF-999"}}
          },
          {:ok, manifest}
        )

      assert result["isError"] == true
      assert [%{"text" => text}] = result["content"]
      assert text =~ "WF-999"
    end

    test "a tool on a writing task is refused at call time even if nobody validated", %{} do
      unvalidated = %{
        "tools" => [%{"name" => "harness_sneaky", "task" => "run", "description" => "x"}]
      }

      %{"result" => result} =
        MCP.handle(
          %{
            "jsonrpc" => "2.0",
            "id" => 5,
            "method" => "tools/call",
            "params" => %{"name" => "harness_sneaky"}
          },
          {:ok, unvalidated}
        )

      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "not on the read-only allow-list"
    end

    test "an unknown tool, an unknown method, a notification, a batch and garbage", %{
      manifest: manifest
    } do
      m = {:ok, manifest}

      assert %{"error" => %{"code" => -32_602}} =
               MCP.handle(
                 %{"id" => 6, "method" => "tools/call", "params" => %{"name" => "nope"}},
                 m
               )

      assert %{"error" => %{"code" => -32_601}} =
               MCP.handle(%{"id" => 7, "method" => "resources/list"}, m)

      assert :noreply == MCP.handle(%{"method" => "notifications/initialized"}, m)

      assert %{"error" => %{"code" => -32_600}} =
               MCP.handle([%{"id" => 8, "method" => "ping"}], m)

      assert %{"error" => %{"code" => -32_700}} = MCP.respond("{not json", m)
      assert %{"result" => %{}} = MCP.handle(%{"id" => 9, "method" => "ping"}, m)
    end

    test "params that are not an object, and an id that is not a scalar, are refused", %{
      manifest: manifest
    } do
      m = {:ok, manifest}

      assert %{"id" => 11, "error" => %{"code" => -32_602}} =
               MCP.handle(%{"id" => 11, "method" => "tools/call", "params" => ["x"]}, m)

      assert %{"id" => nil, "error" => %{"code" => -32_600}} =
               MCP.handle(%{"id" => %{"a" => 1}, "method" => "ping"}, m)

      assert :noreply == MCP.handle(%{"method" => "notifications/x", "params" => "s"}, m)

      assert %{"result" => %{"isError" => true}} =
               MCP.handle(
                 %{
                   "id" => 12,
                   "method" => "tools/call",
                   "params" => %{"name" => "harness_memory", "arguments" => ["x"]}
                 },
                 m
               )
    end

    test "the logger is moved to stderr, and the move is checked" do
      {:ok, before} = :logger.get_handler_config(:default)

      on_exit(fn ->
        :logger.remove_handler(:default)
        :logger.add_handler(:default, before.module, Map.drop(before, [:id, :module]))
      end)

      assert :ok == MCP.quiet_stdout!()
      assert {:ok, %{config: %{type: :standard_error}}} = :logger.get_handler_config(:default)
    end

    test "a manifest that cannot be read is an error on the call, not a crash" do
      assert %{"error" => %{"code" => -32_603, "message" => message}} =
               MCP.handle(%{"id" => 10, "method" => "tools/list"}, {:error, "gone"})

      assert message =~ "gone"
    end
  end

  # A build may leave the evolution engine out, as the published harness did
  # for one cut.
  # `loaded?` stands in for that build here, where the engine is present.
  describe "the evolution engine's task" do
    setup do
      engine = Module.concat(Mix.Tasks.Harness, Environments)
      {:ok, without_engine: [loaded?: &(&1 != engine and Code.ensure_loaded?(&1))]}
    end

    # A build with the engine serves the tool, and one without it serves it
    # nowhere. This holds in both.
    test "is served exactly where the build has it", %{manifest: manifest} do
      engine? = Code.ensure_loaded?(Module.concat(Mix.Tasks.Harness, Environments))
      brief = tool(manifest, "harness_environment_brief")

      assert MCP.served?(brief) == engine?
      assert "harness_environment_brief" in Enum.map(MCP.tools(manifest), & &1["name"]) == engine?
      assert MCP.allowed()["environments"].engine
    end

    test "is not listed, not callable and not a defect in a build without it", %{
      manifest: manifest,
      without_engine: without
    } do
      brief = tool(manifest, "harness_environment_brief")
      refute MCP.served?(brief, without)

      assert MCP.validate(manifest, without) == []

      names = Enum.map(MCP.tools(manifest, without), & &1["name"])
      refute "harness_environment_brief" in names
      assert names == for(t <- manifest["tools"], t["task"] != "environments", do: t["name"])

      assert {:unknown, "harness_environment_brief"} =
               MCP.call(manifest, "harness_environment_brief", %{"id" => "env-x"}, without)
    end

    test "only the engine's: any other task with no module is still a defect", %{
      manifest: manifest
    } do
      none = [loaded?: fn _module -> false end]
      route = tool(manifest, "harness_route")

      assert MCP.served?(route, none)
      assert [message] = MCP.validate(%{"tools" => [route]}, none)
      assert message =~ "names `route`, and there is no Mix.Tasks.Harness.Route"
    end
  end
end
