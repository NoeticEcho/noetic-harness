defmodule Noetic.Harness.MCP do
  @moduledoc """
  The harness over MCP, for an agent that is not Claude Code.

  Claude Code gets the harness through hooks, a skill and slash commands. Codex,
  Cursor and Gemini get none of those, and each of them speaks MCP. This module
  is a stdio MCP server whose tools are the harness's own read-only tasks —
  `route`, `context`, `prompt`, `workflows`, `gates --plan`, `memory --query`,
  `kb --query`, `environments --brief`, `conduct --classify` — run in-process
  and returned as the text a person would see. `noetic-harness mcp` starts it.

  `environments` is the evolution engine's, and a build may leave the engine
  out: the published harness did, for one cut, until its guards were
  complete. Where the build has no `mix harness.environments`, a tool on it is
  not listed, a call to it is a call to no tool, and the manifest naming it is
  not a defect.

  `kb` writes one thing, and it is not a record: the index it
  builds from `docs/kb/extraction/` is cached under `.agents/cache/kb/`, which
  is git-ignored and derived entirely from committed files. Deleting it costs
  the next query a rebuild and nothing else.

  ## Read-only is the design, not a first phase

  There is no tool here for `run --step`, dispatch, `evolution --record`,
  `environments --verify` or `memory --add`, and there is no mechanism by which
  one could be added in data. Two things stand in the way, and both are code:

  - `@allowed` names every task that may be served, the flags each may be
    given, and the flag some must always carry (`gates` without `--plan` runs
    the lane; `memory` without `--query` can `--add`). `validate/1` refuses a
    manifest that steps outside it, and `noetic-harness validate` runs that.
  - `argv_allowed/2` checks the argv a call has built, before running it and
    independently of the manifest: only allowed flags, no `--no-*`, and the
    read-only flag present. A manifest nobody validated still cannot reach a
    writing task.

  The first independent review broke "read-only" four ways, and each is now
  a test: `route --bead` handed `bd` a flag, `null` satisfied a required
  argument, a manifest could make `--plan` switchable, and the call-time
  check only re-asked the validator's question. A design note has the detail.

  A caller that can start a dispatching run is a caller that can spend money
  and write code, and a remote one would be doing it unauthenticated.

  ## Why stdio, and why not in the Phoenix application

  An MCP endpoint mounted in the application is an unauthenticated remote
  execution surface. Tidewave is safe here only because its plug sits inside a
  compile-time `Mix.env() == :dev`, so it is absent from a release rather than
  present and refusing. A stdio server has no listener at all — one process per
  client, spawned by that client, with that client's permissions — and a
  surface that does not exist is the only kind that cannot be misconfigured.

  ## Arguments cannot become flags

  Every argument reaches the task as one argv element, `--flag=value`. A title
  of `--add` is a title. A positional argument — `prompt`'s role id — may not
  start with `-` at all. The server never goes through a shell.

  ## stdout is the protocol

  Anything else written to stdout corrupts the stream the client is parsing.
  A tool runs in its own process with a `StringIO` as its group leader, so
  whatever the task prints is captured and returned as the tool's text; Mix's
  shell is swapped for `Noetic.Harness.MCP.Shell`, which writes errors there
  too rather than to stderr, and never prompts; and the default logger handler
  is pointed at stderr. `noetic-harness mcp` sends the toolchain notice and the
  compile to stderr for the same reason.
  """

  alias Noetic.Harness.Loader

  @manifest "policies/mcp.json"

  # The newest first. The client's version is echoed when it is one of these;
  # otherwise the newest is offered and the client decides (MCP lifecycle).
  @protocol_versions ~w(2025-11-25 2025-06-18 2025-03-26 2024-11-05)

  # Every task that may be served, the flags it may be given (`nil` is a
  # positional argument), and the flag that keeps it read-only. A task that is
  # not a key here cannot be served, whatever the manifest says.
  #
  # `must` comes in two kinds, and review found both could be switched off. A
  # `{:switch, flag}` must be in the tool's `fixed` list, because a boolean
  # argument the client sets can be `false` and a string one can be
  # `--plan=false`, which OptionParser reads as off. A `{:value, flag}` must be
  # a required string argument, and a call must give it a non-empty value —
  # `{"query": null}` used to count as present and emit nothing.
  #
  # What is *not* here, and why: `route --bead` runs `bd show <id>`, which
  # takes flags from the id and writes `.beads/last-touched` even for a real
  # one — review created a Dolt database outside the repository through it.
  # `context --render` prints the first lines of any path it is given.
  #
  # `engine: true` marks a task of the evolution engine, which a build may
  # leave out (`Noetic.Harness.Validation`'s `@engine`). It is served only
  # where the build has it (`served?/2`).
  @allowed %{
    "route" => %{flags: ~w(--title --body --kind --risk --paths --workflow --explain), must: nil},
    # `--kb` so that the manifest can fix `--kb=cached`: an agent
    # asking for context must not wait ~7 s for a knowledge-base build.
    # `--format` and `--check-brief` are not here: the second reads any path.
    "context" => %{flags: ~w(--title --body --paths --capability --limit --kb), must: nil},
    "prompt" => %{
      flags: [nil | ~w(--workflow --step --task --title --lane --trust --render-context)],
      must: nil
    },
    "workflows" => %{flags: ~w(--show --pipelines), must: nil},
    "gates" => %{flags: ~w(--lane --plan --paths), must: {:switch, "--plan"}},
    "memory" => %{flags: ~w(--query), must: {:value, "--query"}},
    # `--query` rather than the positional words `noetic-harness kb` also takes,
    # so that the `must` rule can see the query is there. `--json` is left
    # out: the tool's answer is the text a person reads.
    "kb" => %{flags: ~w(--query --limit --group --kind), must: {:value, "--query"}},
    "environments" => %{flags: ~w(--brief), must: {:value, "--brief"}, engine: true},
    "conduct" => %{flags: ~w(--classify), must: {:value, "--classify"}}
  }

  @call_timeout_ms 120_000

  @doc "The tasks that may be served, and nothing else."
  @spec allowed() :: map()
  def allowed, do: @allowed

  @doc "The protocol versions this server speaks, newest first."
  @spec protocol_versions() :: [String.t()]
  def protocol_versions, do: @protocol_versions

  @doc "The manifest, `.agents/policies/mcp.json`."
  @spec manifest() :: {:ok, map()} | {:error, String.t()}
  def manifest, do: Loader.load(Noetic.Harness.agents_path(@manifest))

  # ---- validation ------------------------------------------------------------

  @doc """
  What is wrong with a manifest, as sentences. Empty means it may be served.

  `opts` takes `loaded?`, which answers whether a module is in the build; it
  is `Code.ensure_loaded?/1`, and a test passes another to ask about a build
  without the evolution engine.
  """
  @spec validate(map(), keyword()) :: [String.t()]
  def validate(manifest, opts \\ [])

  def validate(%{"tools" => tools}, opts) when is_list(tools) do
    duplicates =
      tools
      |> Enum.frequencies_by(& &1["name"])
      |> Enum.filter(fn {_name, n} -> n > 1 end)
      |> Enum.map(fn {name, _} -> "mcp: tool #{name} is defined more than once" end)

    duplicates ++ Enum.flat_map(tools, &tool_errors(&1, opts))
  end

  def validate(_, _opts), do: ["mcp: the manifest has no tools list"]

  defp tool_errors(%{"name" => name, "task" => task} = tool, opts) do
    case Map.fetch(@allowed, task) do
      :error ->
        [
          "mcp: #{name} serves `#{task}`, which is not on the read-only allow-list in " <>
            "Noetic.Harness.MCP — widening it is a code change and a review, not a line of data"
        ]

      {:ok, %{flags: flags, must: must}} ->
        used = Map.get(tool, "fixed", []) ++ Enum.map(Map.get(tool, "args", []), & &1["flag"])

        stray =
          for flag <- Enum.uniq(used), flag not in flags do
            "mcp: #{name} gives `#{task}` #{flag || "a positional argument"}, which it may not be given"
          end

        missing = must_errors(name, task, must, tool)

        # A tool on the engine's task, in a build without the engine, is not
        # served at all, so it is not a tool that fails.
        module =
          if loaded?(opts).(task_module(task)) or not served?(tool, opts),
            do: [],
            else: ["mcp: #{name} names `#{task}`, and there is no #{inspect(task_module(task))}"]

        stray ++ missing ++ module
    end
  end

  defp tool_errors(tool, _opts), do: ["mcp: a tool has no name or no task: #{inspect(tool)}"]

  @doc """
  Whether a tool is served by this build: every tool is, except one on a task
  of the evolution engine (`engine: true` in the allow-list) where the build
  has no such task. `opts` is `validate/2`'s.
  """
  @spec served?(map(), keyword()) :: boolean()
  def served?(tool, opts \\ [])

  def served?(%{"task" => task}, opts) do
    case Map.fetch(@allowed, task) do
      {:ok, %{engine: true}} -> loaded?(opts).(task_module(task))
      _ -> true
    end
  end

  def served?(_tool, _opts), do: true

  defp loaded?(opts), do: Keyword.get(opts, :loaded?, &Code.ensure_loaded?/1)

  defp must_errors(_name, _task, nil, _tool), do: []

  defp must_errors(name, task, {:switch, flag}, tool) do
    if flag in Map.get(tool, "fixed", []) and
         not Enum.any?(Map.get(tool, "args", []), &(&1["flag"] == flag)),
       do: [],
       else: [
         "mcp: #{name} must pass #{flag} to `#{task}` in `fixed` and nowhere else — " <>
           "an argument the client sets can switch it off, and without it the task writes"
       ]
  end

  defp must_errors(name, task, {:value, flag}, tool) do
    ok? =
      Enum.any?(
        Map.get(tool, "args", []),
        &(&1["flag"] == flag and &1["required"] == true and &1["type"] == "string")
      )

    if ok?,
      do: [],
      else: [
        "mcp: #{name} does not always pass #{flag} to `#{task}` as a required string, " <>
          "and without it the task writes"
      ]
  end

  # ---- the tool list ---------------------------------------------------------

  @doc "The manifest's tools this build serves (`served?/2`), as MCP `tools/list` entries."
  @spec tools(map(), keyword()) :: [map()]
  def tools(%{"tools" => tools}, opts \\ []),
    do: for(tool <- tools, served?(tool, opts), do: describe(tool))

  defp describe(tool) do
    args = Map.get(tool, "args", [])

    %{
      "name" => tool["name"],
      "description" =>
        tool["description"] <> " Runs `noetic-harness #{command(tool)}` and returns its text.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => Map.new(args, &{&1["name"], schema(&1)}),
        "required" => for(arg <- args, arg["required"], do: arg["name"]),
        "additionalProperties" => false
      },
      "annotations" => %{"readOnlyHint" => true, "openWorldHint" => false}
    }
  end

  defp command(tool), do: Enum.join([tool["task"] | Map.get(tool, "fixed", [])], " ")

  defp schema(%{"type" => "array"} = arg),
    do: %{
      "type" => "array",
      "items" => %{"type" => "string"},
      "description" => arg["description"]
    }

  defp schema(arg), do: %{"type" => arg["type"], "description" => arg["description"]}

  # ---- calling ---------------------------------------------------------------

  @doc """
  The argv a tool call becomes, or why it cannot be made.

  Every value is one element, `--flag=value`; a positional value may not start
  with `-`; an argument the tool does not declare is refused rather than
  ignored, because an ignored argument is a caller believing it narrowed a
  query it did not.
  """
  @spec argv(map(), map()) :: {:ok, [String.t()]} | {:error, String.t()}
  def argv(tool, arguments) when is_map(arguments) do
    args = Map.get(tool, "args", [])
    unknown = Map.keys(arguments) -- Enum.map(args, & &1["name"])

    missing =
      for arg <- args,
          arg["required"],
          Map.get(arguments, arg["name"]) in [nil, ""],
          do: arg["name"]

    cond do
      unknown != [] ->
        {:error, "#{tool["name"]} does not take #{Enum.join(unknown, ", ")}"}

      missing != [] ->
        {:error, "#{tool["name"]} needs #{Enum.join(missing, ", ")}"}

      true ->
        Enum.reduce_while(args, {:ok, Map.get(tool, "fixed", [])}, fn arg, {:ok, acc} ->
          case element(arg, Map.get(arguments, arg["name"])) do
            {:ok, more} -> {:cont, {:ok, acc ++ more}}
            {:error, _} = error -> {:halt, error}
          end
        end)
    end
  end

  def argv(tool, nil), do: argv(tool, %{})
  def argv(tool, _), do: {:error, "#{tool["name"]}: arguments must be an object"}

  defp element(_arg, nil), do: {:ok, []}

  defp element(%{"flag" => nil, "name" => name}, value) when is_binary(value) do
    if String.starts_with?(value, "-") or value == "",
      do: {:error, "#{name} may not be empty or start with `-`"},
      else: {:ok, [value]}
  end

  defp element(%{"type" => "string", "flag" => flag}, value) when is_binary(value),
    do: {:ok, ["#{flag}=#{value}"]}

  defp element(%{"type" => "integer", "flag" => flag}, value) when is_integer(value),
    do: {:ok, ["#{flag}=#{value}"]}

  defp element(%{"type" => "boolean", "flag" => flag}, true), do: {:ok, [flag]}
  defp element(%{"type" => "boolean"}, false), do: {:ok, []}

  # Every list argument is a list of repository paths. An absolute path or one
  # that climbs out let `context` say whether a file anywhere on the machine
  # exists, in review.
  defp element(%{"type" => "array", "flag" => flag, "name" => name}, values)
       when is_list(values) do
    if Enum.all?(values, &repository_path?/1),
      do: {:ok, ["#{flag}=#{Enum.join(values, ",")}"]},
      else:
        {:error,
         "#{name} must be repository-relative paths: no leading `/` or `~`, no `..`, no commas"}
  end

  defp element(%{"name" => name, "type" => type}, value),
    do: {:error, "#{name} must be #{article(type)} #{type}, not #{inspect(value)}"}

  defp repository_path?(value) when is_binary(value) do
    value != "" and not String.contains?(value, [",", "\n", <<0>>]) and
      Path.type(value) == :relative and not String.starts_with?(value, ["~", "-"]) and
      ".." not in Path.split(value)
  end

  defp repository_path?(_), do: false

  defp article("integer"), do: "an"
  defp article("array"), do: "an"
  defp article(_), do: "a"

  @doc """
  Run a tool. `{:ok, text}` when the task succeeded, `{:error, text}` when it
  refused, failed, or could not be run — the text says which. `{:unknown, name}`
  when the manifest has no such tool, or this build does not serve it.

  `opts`: `timeout` in milliseconds, and `validate/2`'s `loaded?`.
  """
  @spec call(map(), String.t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()} | {:unknown, String.t()}
  def call(manifest, name, arguments, opts \\ []) do
    with {:ok, tool} <- find(manifest, name, opts),
         :ok <- still_allowed(tool, opts),
         {:ok, argv} <- argv(tool, arguments),
         :ok <- argv_allowed(tool["task"], argv) do
      run_task(tool["task"], argv, Keyword.get(opts, :timeout, @call_timeout_ms))
    end
  end

  defp find(%{"tools" => tools}, name, opts) do
    case Enum.find(tools, &(&1["name"] == name and served?(&1, opts))) do
      nil -> {:unknown, name}
      tool -> {:ok, tool}
    end
  end

  # The same table `validate/1` checks, checked again at the moment it matters.
  defp still_allowed(tool, opts) do
    case tool_errors(tool, opts) do
      [] -> :ok
      errors -> {:error, "refused: " <> Enum.join(errors, "; ")}
    end
  end

  @doc """
  Whether an argv may be handed to `task` — checked on the argv itself, after
  it is built, and independently of the manifest.

  `still_allowed/1` asks the manifest the question `validate/1` does, so it
  cannot catch what `validate/1` missed; this can. Every element is an allowed
  flag, `flag=value` for an allowed flag, or a positional value where the task
  takes one. `--no-*` is refused outright, since OptionParser reads it as a
  boolean switched off. The `must` flag is there — `--plan` exactly, or
  `--query=<something>`.
  """
  @spec argv_allowed(String.t(), [String.t()]) :: :ok | {:error, String.t()}
  def argv_allowed(task, argv) do
    case Map.fetch(@allowed, task) do
      :error ->
        {:error, "refused: `#{task}` is not on the read-only allow-list"}

      {:ok, %{flags: flags, must: must}} ->
        stray = Enum.reject(argv, &element_allowed?(&1, flags))

        cond do
          stray != [] ->
            {:error, "refused: `#{task}` may not be given #{Enum.join(stray, " ")}"}

          not must_present?(must, argv) ->
            {:error, "refused: `#{task}` without #{elem(must, 1)} writes"}

          true ->
            :ok
        end
    end
  end

  defp element_allowed?("--no-" <> _, _flags), do: false

  defp element_allowed?("-" <> _ = element, flags) do
    [flag | _] = String.split(element, "=", parts: 2)
    flag in flags
  end

  defp element_allowed?(_positional, flags), do: nil in flags

  defp must_present?(nil, _argv), do: true
  defp must_present?({:switch, flag}, argv), do: flag in argv

  defp must_present?({:value, flag}, argv) do
    Enum.any?(argv, fn element ->
      case String.split(element, "=", parts: 2) do
        [^flag, value] -> value != ""
        _ -> false
      end
    end)
  end

  defp task_module(task), do: Module.concat(Mix.Tasks.Harness, Macro.camelize(task))

  defp run_task(task, argv, timeout) do
    module = task_module(task)
    {:ok, io} = StringIO.open("")
    root = Noetic.Harness.root_override()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.group_leader(self(), io)
        if root, do: Noetic.Harness.put_root(root)
        exit({:mcp, outcome(module, argv)})
      end)

    result =
      receive do
        {:DOWN, ^ref, :process, ^pid, {:mcp, outcome}} -> outcome
        {:DOWN, ^ref, :process, ^pid, reason} -> {:crashed, inspect(reason)}
      after
        timeout ->
          Process.exit(pid, :kill)
          receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
          {:timeout, timeout}
      end

    {_, output} = StringIO.contents(io)
    StringIO.close(io)
    text = String.trim_trailing(output)

    case result do
      :ok -> {:ok, text}
      {:refused, message} -> {:error, join(text, message)}
      {:failed, status} -> {:error, join(text, "`#{task}` exited with status #{status}.")}
      {:crashed, detail} -> {:error, join(text, "`#{task}` failed: #{detail}")}
      {:timeout, ms} -> {:error, join(text, "`#{task}` did not finish within #{div(ms, 1000)}s.")}
    end
  end

  # `Mix.raise/1` is how a task refuses — "no workflow WF-999" — and a
  # refusal is a sentence, not a stack trace.
  defp outcome(module, argv) do
    module.run(argv)
    :ok
  rescue
    error in Mix.Error -> {:refused, Exception.message(error)}
  catch
    :exit, {:shutdown, 0} -> :ok
    :exit, :normal -> :ok
    :exit, {:shutdown, status} -> {:failed, status}
    kind, reason -> {:crashed, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp join("", note), do: note
  defp join(text, note), do: text <> "\n\n" <> note

  # ---- JSON-RPC --------------------------------------------------------------

  @doc """
  One JSON-RPC message in, at most one out. Pure apart from running the tool,
  which is what makes the protocol testable without a pipe.
  """
  @spec handle(term(), {:ok, map()} | {:error, String.t()}) :: map() | :noreply
  # JSON-RPC ids are strings, numbers or null. Anything else is not echoed.
  def handle(%{"id" => id}, _manifest) when not (is_binary(id) or is_number(id) or is_nil(id)),
    do: error(nil, -32_600, "an id must be a string or a number")

  # `params`, when present, is an object. A list crashed the server in review
  # and every later request went unanswered.
  def handle(%{"params" => params} = message, _manifest)
      when not is_map(params) and not is_nil(params) do
    if Map.has_key?(message, "id"),
      do: error(message["id"], -32_602, "params must be an object"),
      else: :noreply
  end

  def handle(%{"method" => "initialize", "id" => id} = message, manifest) do
    requested = get_in(message, ["params", "protocolVersion"])

    reply(id, %{
      "protocolVersion" =>
        if(requested in @protocol_versions, do: requested, else: hd(@protocol_versions)),
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => "noetic-harness", "version" => version()},
      "instructions" => instructions(manifest)
    })
  end

  def handle(%{"method" => "ping", "id" => id}, _manifest), do: reply(id, %{})

  def handle(%{"method" => "tools/list", "id" => id}, {:ok, manifest}),
    do: reply(id, %{"tools" => tools(manifest)})

  def handle(%{"method" => "tools/call", "id" => id} = message, {:ok, manifest}) do
    name = get_in(message, ["params", "name"])

    case call(manifest, name, get_in(message, ["params", "arguments"])) do
      {:unknown, name} -> error(id, -32_602, "no tool named #{inspect(name)}")
      {:ok, text} -> reply(id, content(text, false))
      {:error, text} -> reply(id, content(text, true))
    end
  end

  def handle(%{"method" => method, "id" => id}, {:error, message})
      when method in ["tools/list", "tools/call"],
      do: error(id, -32_603, "the harness could not read its MCP manifest: #{message}")

  # A notification — no id — is never answered, whatever it is.
  def handle(%{"method" => _method} = message, _manifest) when not is_map_key(message, "id"),
    do: :noreply

  def handle(%{"method" => method, "id" => id}, _manifest),
    do: error(id, -32_601, "method not found: #{method}")

  # A response to something this server never asks, or a batch, which the
  # protocol stopped allowing in 2025-06-18.
  def handle(list, _manifest) when is_list(list),
    do: error(nil, -32_600, "batches are not supported")

  def handle(_other, _manifest), do: :noreply

  defp content(text, error?) do
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => error?}
  end

  defp reply(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  # The knowledge-base sentence only when the manifest serves the tool it
  # names: an instruction to call a tool that `tools/list` does not have is a
  # failed call the client was told to make.
  defp instructions(manifest) do
    kb =
      case manifest do
        {:ok, %{"tools" => tools}} when is_list(tools) ->
          if Enum.any?(tools, &(is_map(&1) and &1["task"] == "kb")),
            do:
              " harness_kb_query asks the project's knowledge base — its terms, concepts, " <>
                "requirements and decisions, with their sources — in Russian or English.",
            else: ""

        _ ->
          ""
      end

    "#{Noetic.Harness.Project.name() || "This repository"}'s development harness, " <>
      "read-only. Before non-trivial work call " <>
      "harness_route with a one-line title, then harness_context; harness_memory " <>
      "says what earlier work learned." <> kb <> " Nothing here records, dispatches or writes."
  end

  defp version do
    case Application.spec(:noetic_harness, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  # ---- the loop --------------------------------------------------------------

  @doc """
  Serve MCP on stdin/stdout until stdin closes. `noetic-harness mcp` calls this.
  """
  @spec serve() :: :ok
  def serve do
    quiet_stdout!()
    _ = Application.load(:noetic_harness)
    Mix.start()
    Mix.shell(Noetic.Harness.MCP.Shell)
    :io.setopts(:standard_io, binary: true, encoding: :unicode)
    loop(manifest())
  end

  @doc """
  Point the default logger handler at stderr.

  `update_handler_config/3` cannot change a `logger_std_h`'s `type` — it
  returns `{:error, {:illegal_config_change, ...}}`, which the first version
  ignored, so a `Logger.error` still reached stdout. The handler is removed
  and added again instead, and a failure says so on stderr.
  """
  @spec quiet_stdout!() :: :ok
  def quiet_stdout! do
    config =
      case :logger.get_handler_config(:default) do
        {:ok, config} -> Map.drop(config, [:id, :module, :config])
        {:error, _} -> %{}
      end

    _ = :logger.remove_handler(:default)

    case :logger.add_handler(
           :default,
           :logger_std_h,
           Map.put(config, :config, %{type: :standard_error})
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(
          :stderr,
          "noetic-harness mcp: could not move the logger to stderr: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp loop(manifest) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        case String.trim(line) do
          "" -> :ok
          text -> text |> respond(manifest) |> write()
        end

        loop(manifest)
    end
  end

  @doc false
  def respond(text, manifest) do
    case JSON.decode(text) do
      {:ok, message} -> handle(message, manifest)
      {:error, _} -> error(nil, -32_700, "not JSON")
    end
  rescue
    # One malformed request must not end the session: it is answered, and the
    # next line is read.
    exception ->
      IO.puts(:stderr, Exception.format(:error, exception, __STACKTRACE__))
      error(nil, -32_603, "the request could not be handled: #{Exception.message(exception)}")
  end

  defp write(:noreply), do: :ok
  defp write(message), do: IO.write(:stdio, [JSON.encode!(message), "\n"])
end
