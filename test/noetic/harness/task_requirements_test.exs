defmodule Noetic.Harness.TaskRequirementsTest do
  @moduledoc """
  Every harness task compiles before it runs.

  Mix runs a project task against the beams already built unless the task
  declares a requirement. Thirteen of these did not, so `noetic-harness sync`
  wrote the previous version's output twice in one session, and `validate`
  and `sync --check` could pass against code that was not the code on disk.
  """

  # async: false: one test sets NOETIC_HARNESS_CALLER_DIR and swaps Mix.shell,
  # both process-global.
  use ExUnit.Case, async: false

  test "every Mix.Tasks.Harness.* requires compile or app.config" do
    {:ok, modules} = :application.get_key(:noetic_harness, :modules)

    tasks =
      Enum.filter(modules, fn module ->
        name = Atom.to_string(module)

        name == "Elixir.Mix.Tasks.Harness" or
          String.starts_with?(name, "Elixir.Mix.Tasks.Harness.")
      end)

    assert length(tasks) > 20

    for task <- tasks do
      requirements = Mix.Task.requirements(task)

      assert Enum.any?(requirements, &(&1 in ["compile", "app.config", "app.start"])),
             "#{inspect(task)} declares no compile requirement, so it runs stale beams"
    end
  end

  describe "running from apps/noetic_harness does not move a relative path" do
    @tag this_repository: true
    test "noetic-harness exports the caller's directory before it changes its own" do
      script = File.read!(Path.join(Noetic.Harness.root(), "noetic-harness"))
      [before_cd, _] = String.split(script, ~s|cd "$root/apps/noetic_harness"|, parts: 2)
      assert before_cd =~ ~s|export NOETIC_HARNESS_CALLER_DIR="$PWD"|
      assert before_cd =~ ~s|NOETIC_HARNESS_ROOT="$PWD/$NOETIC_HARNESS_ROOT"|
    end

    @tag this_repository: true
    test "--json compiles to stderr first, so the answer is the only thing on stdout" do
      # After any edit, `noetic-harness telemetry --json` began with
      # "Compiling 1 file (.ex)" and a JSON parser failed on line one.
      script = File.read!(Path.join(Noetic.Harness.root(), "noetic-harness"))
      [_, after_cd] = String.split(script, ~s|cd "$root/apps/noetic_harness"|, parts: 2)
      [before_exec, _] = String.split(after_cd, "exec mix", parts: 2)
      assert before_exec =~ "--json | --hook-json)"
      assert before_exec =~ "mix compile >&2"
    end

    test "usage --transcript reads a relative path against the caller's directory" do
      # Found by the independent verification of an earlier change: after the change,
      # a relative --transcript was read against apps/noetic_harness.
      caller = Path.join(System.tmp_dir!(), "harness-caller-#{System.os_time(:nanosecond)}")
      File.mkdir_p!(Path.join(caller, "t"))

      line = %{
        "type" => "assistant",
        "message" => %{"model" => "m", "usage" => %{"input_tokens" => 7, "output_tokens" => 3}}
      }

      File.write!(Path.join([caller, "t", "session.jsonl"]), JSON.encode!(line) <> "\n")

      previous_dir = System.get_env("NOETIC_HARNESS_CALLER_DIR")
      previous_shell = Mix.shell()
      System.put_env("NOETIC_HARNESS_CALLER_DIR", caller)
      Mix.shell(Mix.Shell.Process)

      on_exit(fn ->
        Mix.shell(previous_shell)

        if previous_dir,
          do: System.put_env("NOETIC_HARNESS_CALLER_DIR", previous_dir),
          else: System.delete_env("NOETIC_HARNESS_CALLER_DIR")

        File.rm_rf!(caller)
      end)

      Mix.Tasks.Harness.Usage.run(["--transcript", "t/session.jsonl", "--json"])
      assert_received {:mix_shell, :info, [json]}
      assert JSON.decode!(json)["tokens"]["input_tokens"] == 7
    end
  end
end
