defmodule Noetic.Harness.BareRepositoryTest do
  @moduledoc """
  The harness on a repository that is not this one (the start of
  An earlier change): a git repository with a minimal `.agents/` — five roles'
  worth of registry, one workflow, one lane — and every integration off
  (`Noetic.Harness.Integrations`). No `bd`, no knowledge base, no knowledge store, no
  Jido adapter, no coordinator protocol, no app layout.

  `route`, `context`, `gates --plan`, `run --start/--step/--status` and
  `conduct` answer there, from the tasks a person runs, and what needs an
  integration says that it is off rather than failing.

  The tasks run in this process with the root moved (`put_root/1`), as
  `RunTaskTest` runs them, so what is asserted is the task's own output and
  exit, not a shell's.
  """

  # async: false: `Mix.shell/1` is VM-global, and the Jido test sets the
  # `:dispatch_adapter_id` application key, which is VM-global too.
  use ExUnit.Case, async: false

  alias Noetic.Harness.{FileTrace, Fixture, Integrations}

  # A layout named unlike this repository's, so that a path the engine
  # guessed rather than read would show.
  @layout %{
    "apps" => "pkgs",
    "lib" => "src",
    "test" => "spec",
    "test_suffix" => "_spec.exs",
    "test_command" => ["true"],
    "build" => "out"
  }

  @workflow %{
    "id" => "WF-001",
    "name" => "Fix a defect",
    "family" => "bug",
    "intent" => "Change the code so the defect is gone.",
    "trigger" => %{"kinds" => ["bug"], "keywords" => ["bug", "broken", "fix"], "risk" => "low"},
    "artifacts" => %{"in" => [], "out" => ["CodePatch"]},
    "default_lane" => "fast",
    "steps" => [
      %{
        "id" => "implement",
        "name" => "Change the code",
        "capabilities" => ["elixir.implementation"],
        "inputs" => [],
        "outputs" => ["patch"],
        "trust" => "T2"
      }
    ],
    "escalations" => [],
    "completion" => ["the defect is gone"]
  }

  # The router's vocabulary, as small as it can be: one signal, the weights
  # and the fallback. A repository's own signals are its data, like its
  # workflows; this is a start for an earlier change's starter pack, not this repository's.
  @signals %{
    "version" => 1,
    "weights" => %{"path" => 3, "text" => 2, "kind" => 1, "family" => 5},
    "confidence" => %{"high" => 6, "medium" => 2},
    "signals" => [
      %{
        "id" => "defect",
        "text" => "bug|broken|defect|fix",
        "capabilities" => ["elixir.implementation"]
      }
    ],
    "kind_signals" => %{"bug" => ["elixir.implementation"]},
    "fallback" => %{"capabilities" => ["elixir.implementation"], "workflow" => "WF-001"}
  }

  defp git(args, dir), do: {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  setup do
    root = Noetic.Harness.TestTmp.path("bare-repository")

    files =
      Fixture.minimal()
      |> Map.put("workflows/WF-001-fix.json", @workflow)
      |> Map.put("registry/signals.json", @signals)
      |> Map.put("registry/project.json", %{"version" => 1, "layout" => @layout})

    for {path, content} <- files do
      full = Path.join([root, ".agents", path])
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, if(is_binary(content), do: content, else: JSON.encode!(content)))
    end

    source = Path.join([root, "pkgs", "parser", "src", "parser.ex"])
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "defmodule Parser do\nend\n")

    git(["init", "--quiet", "-b", "main"], root)
    git(["config", "user.email", "t@t"], root)
    git(["config", "user.name", "t"], root)
    git(["add", "-A"], root)
    git(["commit", "-qm", "a repository that is not the harness's own"], root)

    # A fix with its test, for `environments --derive`.
    File.write!(source, "defmodule Parser do\n  # fixed\nend\n")
    spec = Path.join([root, "pkgs", "parser", "spec", "parser_spec.exs"])
    File.mkdir_p!(Path.dirname(spec))
    File.write!(spec, "# the parser's spec\n")
    git(["add", "-A"], root)
    git(["commit", "-qm", "fix the parser, with its spec"], root)
    {fix, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)

    # The checkout this test file is in, found from the file rather than from
    # the harness root, which a caller may have pointed elsewhere.
    real = Noetic.Harness.Checkout.root()
    previous = Noetic.Harness.root_override()
    Noetic.Harness.put_root(root)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
      File.rm_rf!(root)
    end)

    {:ok, root: root, fix: String.trim(fix), real: real}
  end

  # A task's lines, and how it ended: `:ok`, or the exit it took.
  defp task(module, args) do
    ended =
      try do
        module.run(args)
        :ok
      rescue
        error in Mix.Error -> {:raise, error.message}
      catch
        :exit, reason -> {:exit, reason}
      end

    {ended, lines()}
  end

  defp lines(acc \\ []) do
    receive do
      {:mix_shell, kind, [line]} when kind in [:info, :error] -> lines([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  test "every integration is off, and each one says so" do
    for name <- Integrations.names() do
      refute Integrations.enabled?(name), name
      assert Integrations.off(name) == "#{name} is off in .agents/registry/project.json"
    end
  end

  test "route answers" do
    {ended, out} =
      task(Mix.Tasks.Harness.Route, ["--title", "fix the broken parser", "--explain"])

    assert ended == :ok, out
    assert out =~ "WF-001"
  end

  test "context answers, and says what is not configured" do
    {ended, out} =
      task(Mix.Tasks.Harness.Context, [
        "--title",
        "fix the broken parser",
        "--paths",
        "pkgs/parser/src/parser.ex",
        "--render"
      ])

    assert ended == :ok, out
    assert out =~ "pkgs/parser/src/parser.ex"
  end

  test "gates --plan answers" do
    {ended, out} = task(Mix.Tasks.Harness.Gates, ["--lane", "fast", "--plan"])
    assert ended == :ok, out
    assert out =~ "compile"
  end

  test "a run starts, takes a step, reports its status, and conduct says what is next",
       %{root: root} do
    {ended, out} =
      task(Mix.Tasks.Harness.Run, ["--start", "WF-001", "--title", "fix the broken parser"])

    assert ended == :ok, out
    assert [_, id] = Regex.run(~r/opened (\S+)/, out)
    assert File.exists?(Path.join([root, ".agents", "runs", id <> ".json"]))

    # A run started under `mix test` is ephemeral, and `Run.current/0` skips
    # those, so the run is named, as a second session's would be.
    {ended, out} = task(Mix.Tasks.Harness.Conduct, ["--run", id])
    assert ended == :ok, out
    assert out =~ "implement"

    {ended, out} =
      task(Mix.Tasks.Harness.Run, [
        "--run",
        id,
        "--step",
        "implement",
        "--outcome",
        "done",
        "--evidence",
        "lib/parser.ex changed; the defect no longer reproduces"
      ])

    assert ended == :ok, out

    {ended, out} = task(Mix.Tasks.Harness.Run, ["--run", id, "--status"])
    assert ended == :ok, out
    assert out =~ "implement"
  end

  # What this repository says about itself that a bare one must never be
  # told: its name, and every path its project.json names.
  defp origin_words(real) do
    # A checkout with no `.agents/` of its own, such as the standalone tree
    # `harness cut` writes, has only its path to tell.
    project =
      case Noetic.Harness.Loader.load(Path.join([real, ".agents", "registry", "project.json"])) do
        {:ok, project} -> project
        {:error, _} -> %{}
      end

    strings =
      project
      |> Map.drop(["$schema", "version", "doc", "layout", "integrations"])
      |> leaves()
      |> Enum.filter(&(&1 =~ "/" or &1 =~ ~r/^[A-Z][A-Za-z]+$/ or String.starts_with?(&1, "_")))
      |> Enum.reject(&(&1 =~ " "))

    Enum.uniq([real | strings])
  end

  defp leaves(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&leaves/1)
  defp leaves(list) when is_list(list), do: Enum.flat_map(list, &leaves/1)
  defp leaves(string) when is_binary(string), do: [string]
  defp leaves(_), do: []

  test "the engine, traced: nothing it opens or prints is this repository's",
       %{root: root, fix: fix, real: real} do
    {outputs, opened} =
      FileTrace.paths(fn ->
        route = task(Mix.Tasks.Harness.Route, ["--title", "fix the broken parser", "--explain"])

        context =
          task(Mix.Tasks.Harness.Context, [
            "--title",
            "fix the broken parser",
            "--paths",
            "pkgs/parser/src/parser.ex",
            "--render"
          ])

        plan = task(Mix.Tasks.Harness.Gates, ["--lane", "fast", "--plan"])

        {:ok, start} =
          with {:ok, out} <-
                 ok(
                   task(Mix.Tasks.Harness.Run, ["--start", "WF-001", "--title", "fix the parser"])
                 ),
               do: {:ok, out}

        [_, id] = Regex.run(~r/opened (\S+)/, start)
        conduct = task(Mix.Tasks.Harness.Conduct, ["--run", id])

        step =
          task(Mix.Tasks.Harness.Run, [
            "--run",
            id,
            "--step",
            "implement",
            "--outcome",
            "done",
            "--evidence",
            "pkgs/parser/src/parser.ex changed; the spec passes"
          ])

        status = task(Mix.Tasks.Harness.Run, ["--run", id, "--status"])
        finish = task(Mix.Tasks.Harness.Run, ["--run", id, "--finish"])
        derive = task(Mix.Tasks.Harness.Environments, ["--derive", fix, "--id", "env-parser"])

        %{
          route: route,
          context: context,
          plan: plan,
          conduct: conduct,
          step: step,
          status: status,
          finish: finish,
          derive: derive,
          start: {:ok, start}
        }
      end)

    for {name, {ended, out}} <- outputs do
      assert ended == :ok, "#{name} did not answer:\n#{out}"
    end

    # It did its work, here: the run closed on the lane, and the environment
    # is this repository's parser, under its own layout.
    assert elem(outputs.finish, 1) =~ "passed"
    {:ok, env} = Noetic.Harness.Environments.fetch("env-parser")
    assert env["verifier"]["app"] == "parser"
    assert env["verifier"]["files"] == ["spec/parser_spec.exs"]

    # No file the engine asked about is this repository's. The claim is
    # about the checkout the engine came from, `real`, which is also where
    # `mix test` runs: a relative path the engine opened would expand into
    # it and be caught. What it asked about outside the bare repository is
    # the machine's — `git` and `sh` looked up on PATH, `/proc/self/ns/pid`
    # for a run's owner, the temporary directory — and none of it is here.
    ours = Enum.filter(opened, &(&1 == real or String.starts_with?(&1, real <> "/")))
    assert ours == [], "the bare repository's engine opened:\n" <> Enum.join(ours, "\n")

    # And it did read the bare repository's own definitions, so the list is
    # not empty for want of tracing.
    assert Enum.any?(opened, &String.starts_with?(&1, Path.join(root, ".agents/")))
    assert Path.join([root, ".agents", "registry", "signals.json"]) in opened

    # And nothing it said names this repository or its files.
    printed = outputs |> Map.values() |> Enum.map_join("\n", &elem(&1, 1))

    for word <- origin_words(real) do
      refute printed =~ word, "the bare repository was told #{inspect(word)}"
    end
  end

  defp ok({:ok = ended, out}), do: {ended, out}
  defp ok({ended, out}), do: flunk("#{inspect(ended)}\n#{out}")

  describe "what needs an integration says it is off, and ends cleanly" do
    test "route --bead: beads" do
      {ended, out} =
        task(Mix.Tasks.Harness.Route, ["--title", "fix the parser", "--bead", "x-1"])

      # `Mix.raise/1`: a message and exit status 1, no stack trace.
      assert {:raise, message} = ended, out
      assert message =~ "beads is off in .agents/registry/project.json"
    end

    test "assign: workers" do
      {ended, out} = task(Mix.Tasks.Harness.Assign, ["--epic", "x-1", "--profile", "harness"])
      assert ended == :ok, out
      assert out =~ "workers is off in .agents/registry/project.json"
    end

    test "profiles: workers" do
      {ended, out} = task(Mix.Tasks.Harness.Profiles, [])
      assert ended == :ok, out
      assert out =~ "workers is off in .agents/registry/project.json"
    end

    test "the work graph and the stores: beads" do
      assert Noetic.Harness.Beads.ready(3) == :off
      assert Noetic.Harness.Beads.work_item("x-1") == :off

      {:ok, context} = Noetic.Harness.Attach.context("session_start", %{}, [])
      assert context =~ "beads is off in .agents/registry/project.json"
    end

    test "the jido adapter: jido" do
      previous = Application.get_env(:noetic_harness, :dispatch_adapter_id)
      Application.put_env(:noetic_harness, :dispatch_adapter_id, "jido")

      try do
        assert {:unavailable, "jido is off in .agents/registry/project.json"} =
                 Noetic.Harness.Adapter.resolve("T2")
      after
        if previous,
          do: Application.put_env(:noetic_harness, :dispatch_adapter_id, previous),
          else: Application.delete_env(:noetic_harness, :dispatch_adapter_id)
      end
    end
  end
end
