defmodule Noetic.Harness.StarterPackTest do
  @moduledoc """
  The starter pack and `harness init`.

  Three claims, each a test that fails when it stops being true:

  - **The pack names nothing of this repository**: not its name, its products,
    its stack, a person, a home directory, a key or an address. The Elixir
    add-on may name its stack and nothing else.
  - **`init` writes the pack and never loses anything**: it refuses an existing
    `.agents/` without `--force` and says what `--force` would replace, and with
    it leaves every other file alone.
  - **A repository initialised from the pack works**: `validate` finds no
    error, `route`, `context` and `gates --plan` answer, and a run starts,
    takes its steps and finishes on the `fast` lane. The engine is traced while
    it does, as `BareRepositoryTest` traces it (`Noetic.Harness.FileTrace`),
    and nothing it opens or prints is this checkout's.
  """

  # async: false: `Mix.shell/1` is VM-global, and the traced test sets a
  # global `:erlang.trace_pattern/3`.
  use ExUnit.Case, async: false

  alias Noetic.Harness.{FileTrace, Starter}

  @real Noetic.Harness.Checkout.root()

  # What the pack must not say. The stack words are the development
  # repository's; the add-on is
  # allowed its own (`@stack`), and nothing else. `noetic-harness`,
  # `Noetic.Harness` and the `NOETIC_*` variables are the engine's own names.
  # Spelled with one letter as a character class, which matches only that
  # letter, so that the public tree's own scan does not find its list here.
  @products ~w(e[c]hobaby n[o]eticecho n[o]etictask i[s]kin c[o]ntrol-room a[t]las n[s]l nex tidewave jido wrangler)
  @stack ~w(elixir erlang beam otp mix hex ecto phoenix liveview ash typedb typeql qdrant babylon blender)
  @engine_names ~r/noetic-harness|Noetic\.Harness|NOETIC_[A-Z_]+/

  defp files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  defp findings(path, words) do
    text = path |> File.read!() |> String.replace(@engine_names, "")

    word_hits =
      for word <- words,
          Regex.match?(Regex.compile!("(?<![a-z0-9_-])" <> word <> "(?![a-z0-9_])", "i"), text),
          do: String.replace(word, ["[", "]"], "")

    pattern_hits =
      for {label, pattern} <- [
            {"a product name", ~r/n[o]etic/i},
            {"a home directory", ~r{/h[o]me/|/U[s]ers/}},
            {"a did:key", ~r/did:key:z[1-9A-HJ-NP-Za-km-z]{8,}/},
            {"an e-mail address", ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}/},
            {"a bead id", ~r/\beb-[a-z0-9]{2,}/},
            {"an ADR number", ~r/\bADR-\d{3}\b/},
            {"Cyrillic text", ~r/\p{Cyrillic}/u}
          ],
          Regex.match?(pattern, text),
          do: label

    for hit <- word_hits ++ pattern_hits, do: "#{Path.relative_to(path, @real)}: #{hit}"
  end

  describe "what the pack says" do
    test "no file of the pack names this repository, its stack, a person or a machine" do
      pack = files(Starter.source())
      assert length(pack) > 50, "the pack is not where Starter.source/0 says"

      found = Enum.flat_map(pack, &findings(&1, @products ++ @stack))
      assert found == [], Enum.join(found, "\n")
    end

    test "the Elixir add-on names its stack and nothing of this repository" do
      addon = Path.join(Path.dirname(Path.dirname(Starter.source())), "starter-addons")
      found = addon |> files() |> Enum.flat_map(&findings(&1, @products))
      assert found == [], Enum.join(found, "\n")
    end

    test "the scan finds what it is looking for" do
      # The discriminating half: the same scan over text that has each thing.
      dir = Noetic.Harness.TestTmp.dir!("starter-scan")
      on_exit(fn -> File.rm_rf(dir) end)

      for {name, text} <- [
            {"a", "Built for " <> "Ec" <> "ho" <> "Baby."},
            {"b", "Run mix test."},
            {"c", "See /ho" <> "me/someone/x."},
            {"d", "trusted: did:key:" <> "z6MkMadeUpForTheTest"},
            {"e", "mail me@example.com"},
            {"f", "per " <> "e" <> "b-5cr.7"},
            {"g", "A" <> "DR-026 says"}
          ] do
        File.write!(Path.join(dir, name), text)
      end

      found = dir |> files() |> Enum.flat_map(&findings(&1, @products ++ @stack))
      assert length(found) == 7, Enum.join(found, "\n")

      File.write!(Path.join(dir, "h"), "the noetic-harness MCP server, Noetic.Harness.Run")
      assert findings(Path.join(dir, "h"), @products ++ @stack) == []
    end

    test "there is no identity, no worker protocol and no vendored skill without its licence" do
      source = Starter.source()

      assert {:ok, %{"trusted" => []}} =
               Noetic.Harness.Loader.load(Path.join([source, "policies", "identity.json"]))

      for absent <- [
            "workflows/WF-021-epic-in-a-branch.json",
            "schemas/handoff.schema.json",
            "schemas/coordination.schema.json",
            "schemas/profiles.schema.json",
            "registry/profiles.json",
            "skills/typeql",
            "skills/beads"
          ] do
        refute File.exists?(Path.join(source, absent)), "#{absent} is in the starter pack"
      end

      # The one skill adapted from another project carries that project's licence.
      provenance = File.read!(Path.join([source, "skills", "simplify", "PROVENANCE.md"]))
      assert provenance =~ "Copyright (c) 2025 Mario Zechner"
      assert provenance =~ "Permission is hereby granted"
    end

    # `noetic-harness` is the CLI's own name (`Noetic.Harness.CLI`) and the file
    # the release installs. A gate on `harness` is `unavailable` in every
    # repository a user initialises, and the lane it is on is never green.
    test "the gate and the tool that run the harness name the command a user installs" do
      source = Starter.source()
      {:ok, gates} = Noetic.Harness.Loader.load(Path.join([source, "policies", "gates.json"]))
      {:ok, tools} = Noetic.Harness.Loader.load(Path.join([source, "policies", "tools.json"]))

      assert %{"command" => "noetic-harness validate", "requires" => ["harness"]} =
               Enum.find(gates["gates"], &(&1["id"] == "harness.validate"))

      assert %{"probe" => "command -v noetic-harness"} =
               Enum.find(tools["tools"], &(&1["id"] == "harness"))
    end

    # `Noetic.Harness.Run` signs a run's steps and its stop, and nothing else is
    # signed: a policy promising more is a claim a reader would act on.
    test "identity.json claims only the signatures something makes" do
      {:ok, %{"doc" => doc}} =
        Noetic.Harness.Loader.load(Path.join([Starter.source(), "policies", "identity.json"]))

      assert doc =~ "a run's step and stop records"
      refute doc =~ ~r/evolution|candidate|stage/i
    end

    # The harness's refusals cite `.agents/policies/evolution.md` by path and
    # quote it, in a build with the engine and in one without.
    test "evolution.md is in the pack and says what the messages citing it quote" do
      policy =
        [Starter.source(), "policies", "evolution.md"]
        |> Path.join()
        |> File.read!()
        |> String.replace(~r/\s+/, " ")

      assert policy =~ "## A cluster shape must name the change it implies"
      assert policy =~ "a tolerance moved after a result is in arrives looking like a result"
      assert policy =~ "may *propose* a change to them. It may never land one"
    end
  end

  describe "init" do
    setup do
      root = Noetic.Harness.TestTmp.dir!("starter-init")
      on_exit(fn -> File.rm_rf(root) end)
      {:ok, root: root}
    end

    test "writes the pack, named for the repository", %{root: root} do
      assert {:ok, %{written: written, replaced: []}} = Starter.install(root)
      assert "registry/agents.json" in written

      {:ok, project} =
        Noetic.Harness.Loader.load(Path.join([root, ".agents", "registry", "project.json"]))

      assert project["name"] == Path.basename(root)
    end

    test "refuses an existing .agents/, writes nothing, and names what --force would replace",
         %{root: root} do
      mine = Path.join([root, ".agents", "constitution.md"])
      File.mkdir_p!(Path.dirname(mine))
      File.write!(mine, "my own\n")

      assert {:error, {:exists, ["constitution.md"]}} = Starter.install(root)
      assert File.read!(mine) == "my own\n"
      refute File.exists?(Path.join([root, ".agents", "registry"]))
    end

    test "with --force, replaces the pack's files and nothing else", %{root: root} do
      run = Path.join([root, ".agents", "runs", "run-mine.json"])
      File.mkdir_p!(Path.dirname(run))
      File.write!(run, "{}\n")
      File.write!(Path.join([root, ".agents", "constitution.md"]), "my own\n")

      assert {:ok, %{replaced: ["constitution.md"]}} = Starter.install(root, force: true)
      assert File.read!(run) == "{}\n"
      refute File.read!(Path.join([root, ".agents", "constitution.md"])) == "my own\n"
    end

    test "an add-on that does not exist is an error that lists the ones that do", %{root: root} do
      assert {:error, message} = Starter.install(root, with: ["cobol"])
      assert message =~ "cobol"
      assert message =~ "elixir"
      refute File.exists?(Path.join(root, ".agents"))
    end

    test "the Elixir add-on merges by id and brings executable commands", %{root: root} do
      {:ok, _} = Starter.install(root, with: ["elixir"])
      agents = Path.join(root, ".agents")

      {:ok, %{"agents" => roles}} =
        Noetic.Harness.Loader.load(Path.join([agents, "registry", "agents.json"]))

      ids = Enum.map(roles, & &1["id"])
      assert "elixir.otp_designer" in ids
      assert "engineering.implementer" in ids, "the add-on replaced the pack's roles"

      {:ok, %{"nucleus" => %{"ids" => nucleus}}} =
        Noetic.Harness.Loader.load(Path.join([agents, "registry", "role_rules.json"]))

      assert Enum.sort(nucleus) == Enum.sort(ids)

      for command <- ~w(format build test) do
        %File.Stat{mode: mode} = File.stat!(Path.join([agents, "bin", command]))
        assert Bitwise.band(mode, 0o111) != 0, "bin/#{command} is not executable"
      end
    end

    test "merge: objects by key, id lists by id, other lists by value" do
      base = %{
        "a" => [%{"id" => "x", "v" => 1}, %{"id" => "y", "v" => 1}],
        "b" => ["p", "q"],
        "c" => %{"d" => 1, "e" => 1},
        "f" => 1
      }

      fragment = %{
        "a" => [%{"id" => "y", "v" => 2}, %{"id" => "z", "v" => 2}],
        "b" => ["q", "r"],
        "c" => %{"e" => 2},
        "f" => 2
      }

      assert Starter.merge(base, fragment) == %{
               "a" => [
                 %{"id" => "x", "v" => 1},
                 %{"id" => "y", "v" => 2},
                 %{"id" => "z", "v" => 2}
               ],
               "b" => ["p", "q", "r"],
               "c" => %{"d" => 1, "e" => 2},
               "f" => 2
             }
    end

    test "the task prints the next four commands, sync first", %{root: root} do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Tasks.Harness.Init.run(["--path", root])
      out = collect([])

      [_, next] = String.split(out, "Next:\n", parts: 2)
      assert [first | _] = String.split(next, "\n")
      assert String.ends_with?(first, " noetic-harness sync"), first
      assert out =~ "route --title"
      assert out =~ "gates --lane fast --plan"
      assert out =~ "run --start WF-002"
      assert out =~ "GEMINI.md"
    end

    # `init` cannot run sync itself: sync writes a person's GEMINI.md whole
    # (`Mix.Tasks.Harness.Init`). So what it promises is that the first
    # command it prints is the one that leaves `validate` with no adapter
    # warning.
    test "validate after init warns about every adapter, and after sync about none",
         %{root: root} do
      {:ok, _} = Starter.install(root)
      previous = Noetic.Harness.root_override()
      Noetic.Harness.put_root(root)

      on_exit(fn ->
        if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
      end)

      adapter_warnings = fn ->
        {:ok, findings} = Noetic.Harness.Validation.run()
        for {:warning, text} <- findings, text =~ "generated adapter", do: text
      end

      assert length(adapter_warnings.()) > 50

      {:ok, _} = Noetic.Harness.Adapters.sync(Noetic.Harness.Registry.load!())
      assert adapter_warnings.() == []
    end
  end

  describe "a repository initialised from the pack" do
    setup do
      root = Noetic.Harness.TestTmp.dir!("starter-repo")
      git(["init", "-q", "-b", "main"], root)
      git(["config", "user.email", "t@t"], root)
      git(["config", "user.name", "t"], root)
      git(["config", "commit.gpgsign", "false"], root)
      File.write!(Path.join(root, "README.md"), "# A project\n\nIt does one thing.\n")

      {:ok, _} = Starter.install(root)

      # What a project does first: say how it formats and tests. Trivial here,
      # so the lane's outcome is the engine's and not a toolchain's.
      for command <- ~w(format test) do
        path = Path.join([root, ".agents", "bin", command])
        File.write!(path, "#!/bin/sh\nexit 0\n")
        File.chmod!(path, 0o755)
      end

      git(["add", "-A"], root)
      git(["commit", "-qm", "the starter pack"], root)

      previous = Noetic.Harness.root_override()
      Noetic.Harness.put_root(root)
      Mix.shell(Mix.Shell.Process)

      on_exit(fn ->
        Mix.shell(Mix.Shell.IO)
        if previous, do: Noetic.Harness.put_root(previous), else: Noetic.Harness.delete_root()
        File.rm_rf!(root)
      end)

      {:ok, root: root}
    end

    test "validates, routes, plans and runs, traced: nothing it opens or prints is this checkout's",
         %{root: root} do
      {outputs, opened} =
        FileTrace.paths(fn ->
          validate = task(Mix.Tasks.Harness.Validate, [])

          route =
            task(Mix.Tasks.Harness.Route, ["--title", "the README is out of date", "--explain"])

          context =
            task(Mix.Tasks.Harness.Context, [
              "--title",
              "the README is out of date",
              "--paths",
              "README.md",
              "--render"
            ])

          plan = task(Mix.Tasks.Harness.Gates, ["--lane", "fast", "--plan"])

          {:ok, start} =
            ok(task(Mix.Tasks.Harness.Run, ["--start", "WF-019", "--title", "fix the README"]))

          [_, id] = Regex.run(~r/opened (\S+)/, start)

          File.write!(Path.join(root, "README.md"), "# A project\n\nIt does two things.\n")
          git(["add", "README.md"], root)
          git(["commit", "-qm", "the README says what it does"], root)

          steps =
            for {step, evidence} <- [
                  {"find", "README.md said one thing; the code does two"},
                  {"fix", "README.md now says two things"},
                  {"check", "read README.md against the code: it matches"}
                ] do
              task(Mix.Tasks.Harness.Run, [
                "--run",
                id,
                "--step",
                step,
                "--outcome",
                "done",
                "--evidence",
                evidence
              ])
            end

          finish = task(Mix.Tasks.Harness.Run, ["--run", id, "--finish"])

          %{
            validate: validate,
            route: route,
            context: context,
            plan: plan,
            start: {:ok, start},
            finish: finish
          }
          |> Map.merge(steps |> Enum.with_index() |> Map.new(fn {s, i} -> {:"step_#{i}", s} end))
        end)

      for {name, {ended, out}} <- outputs do
        assert ended == :ok, "#{name} did not answer:\n#{out}"
      end

      refute elem(outputs.validate, 1) =~ "error ", elem(outputs.validate, 1)
      assert elem(outputs.route, 1) =~ "WF-019"
      assert elem(outputs.finish, 1) =~ "lane fast: passed"

      ours = Enum.filter(opened, &(&1 == @real or String.starts_with?(&1, @real <> "/")))
      assert ours == [], "the initialised repository's engine opened:\n" <> Enum.join(ours, "\n")
      assert Path.join([root, ".agents", "registry", "signals.json"]) in opened

      printed = outputs |> Map.values() |> Enum.map_join("\n", &elem(&1, 1))
      refute printed =~ @real
      refute printed =~ ~r/e[c]hobaby/i
    end
  end

  defp git(args, dir), do: {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

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

    {ended, collect([])}
  end

  defp ok({:ok = ended, out}), do: {ended, out}
  defp ok({ended, out}), do: flunk("#{inspect(ended)}\n#{out}")

  defp collect(acc) do
    receive do
      {:mix_shell, _kind, [line]} -> collect([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
