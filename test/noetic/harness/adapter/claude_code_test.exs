defmodule Noetic.Harness.Adapter.ClaudeCodeTest do
  @moduledoc """
  `claude -p`, exercised against a fake `claude` on `PATH`.

  The fake is a shell script that writes its arguments and its stdin to files
  and prints whatever JSON the test chose. Everything between
  `ClaudeCode.call/2` and the process boundary is therefore the real thing —
  the argument construction, the temp file, the `sh` redirect, the exit status
  and the JSON parsing — and none of it costs anything.

  Mocking the module instead would have tested the mock.

  One test is tagged `:live` and calls a real model, because a suite made
  entirely of fakes can agree with itself about an interface that does not
  exist. `test/test_helper.exs` excludes `:live` everywhere — not only where
  `claude` is missing, since a suite run is not consent to spend — and
  `mix test --include live` runs it.

  For its first two days this said "excluded by default" and nothing excluded
  it. On a workstation it quietly called a model on every suite
  run; on CI, which has no `claude`, it crashed, and that crash is how
  `call/2`'s missing-executable defect was found.
  """

  # `async: false` (an earlier change — a seventh file with no written reason, which
  # the bead did not list because it is in a subdirectory). `setup` puts the
  # fake `claude` on `PATH` with `System.put_env/2`, and `PATH` is a VM-global:
  # every concurrently running test would inherit the fake, and when `on_exit`
  # restores the real `PATH` they would lose it mid-call.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Noetic.Harness.Adapter.ClaudeCode

  @success ~s({"type":"result","subtype":"success","is_error":false,"result":"done",) <>
             ~s("total_cost_usd":0.0123,"num_turns":3,"session_id":"abc",) <>
             ~s("usage":{"input_tokens":10,"output_tokens":4},"permission_denials":[]})

  setup %{tmp_dir: tmp} do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)

    files = %{
      args: Path.join(tmp, "args"),
      stdin: Path.join(tmp, "stdin"),
      response: Path.join(tmp, "response"),
      status: Path.join(tmp, "status"),
      fake: Path.join(bin, "claude")
    }

    File.write!(files.response, @success)
    File.write!(files.status, "0")

    File.write!(files.fake, """
    #!/bin/sh
    printf '%s\\n' "$*" > "#{files.args}"
    cat > "#{files.stdin}"
    printf '%s' "$(cat "#{files.response}")"
    exit "$(cat "#{files.status}")"
    """)

    File.chmod!(files.fake, 0o755)

    original = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> original)
    on_exit(fn -> System.put_env("PATH", original) end)

    work = Path.join(tmp, "work")
    File.mkdir_p!(work)

    {:ok, Map.put(files, :work, work) |> Map.to_list()}
  end

  defp fake!(path, script) do
    File.write!(path, script)
    File.chmod!(path, 0o755)
  end

  describe "what it runs" do
    test "print mode and JSON output, always", %{work: work, args: args} do
      assert {:ok, _} = ClaudeCode.call("hello", cwd: work, model: "haiku")

      recorded = File.read!(args)
      assert recorded =~ "-p"
      assert recorded =~ "--output-format json"
    end

    test "the model comes from the caller and is never invented", %{work: work, args: args} do
      {:ok, _} = ClaudeCode.call("hello", cwd: work, model: "opus")
      assert File.read!(args) =~ "--model opus"

      {:ok, _} = ClaudeCode.call("hello", cwd: work)
      refute File.read!(args) =~ "--model"
    end

    test "restricted is passed when asked and omitted otherwise", %{work: work, args: args} do
      # T0 and T1 read and draft, so the policy gives them no command execution
      # at all. This module does not make that judgement, only carries it.
      {:ok, _} = ClaudeCode.call("hello", cwd: work, restricted: true)
      assert File.read!(args) =~ "--restricted"

      {:ok, _} = ClaudeCode.call("hello", cwd: work, restricted: false)
      refute File.read!(args) =~ "--restricted"
    end

    test "the prompt goes on stdin, whole, however long", %{work: work, stdin: stdin} do
      # 44 KB was the first real one. An argv that long is one ARG_MAX away
      # from a failure that reads like the model refusing.
      prompt = String.duplicate("a line of a composed prompt\n", 2_000)

      assert {:ok, _} = ClaudeCode.call(prompt, cwd: work)
      assert File.read!(stdin) == prompt
    end

    test "it runs in the worktree it was given", %{work: work, fake: fake} do
      fake!(fake, """
      #!/bin/sh
      cat > /dev/null
      printf '{"is_error":false,"result":"%s"}' "$(pwd)"
      """)

      assert {:ok, result} = ClaudeCode.call("x", cwd: work)
      assert Path.expand(result.output) == Path.expand(work)
    end

    test "a path that would break naive quoting does not become a command", %{
      tmp_dir: tmp,
      fake: fake
    } do
      # The temp file holding the prompt is interpolated into nothing: `sh -c`
      # gets a fixed script and positional arguments. A built-up string here is
      # how a path becomes a command.
      hostile = Path.join(tmp, "work; touch #{Path.join(tmp, "PWNED")}")
      File.mkdir_p!(hostile)

      fake!(fake, "#!/bin/sh\ncat > /dev/null\nprintf '{\"is_error\":false,\"result\":\"ok\"}'\n")

      assert {:ok, %{output: "ok"}} = ClaudeCode.call("x", cwd: hostile)
      refute File.exists?(Path.join(tmp, "PWNED"))
    end
  end

  describe "what it refuses" do
    test "no working directory at all" do
      # An adapter that defaults to the current directory is an adapter that
      # writes into the parent's tree, which is what the worktree exists to
      # stop.
      assert {:error, why} = ClaudeCode.call("x", model: "haiku")
      assert is_binary(why)
    end

    test "a working directory that is not there", %{tmp_dir: tmp} do
      assert {:error, why} = ClaudeCode.call("x", cwd: Path.join(tmp, "nope"))
      assert why =~ "does not exist"
    end

    test "a non-zero exit carries what it said", %{work: work, status: status, response: response} do
      File.write!(status, "2")
      File.write!(response, "Invalid API key · Please run /login")

      assert {:error, why} = ClaudeCode.call("x", cwd: work)
      assert why =~ "exited 2"
      assert why =~ "/login"
    end

    test "output that is not JSON says so and shows the start", %{work: work, response: response} do
      # The realistic case is a login prompt or a stack trace, and the first
      # lines are what says which.
      File.write!(response, "Welcome to Claude Code!\nPlease authenticate.")

      assert {:error, why} = ClaudeCode.call("x", cwd: work)
      assert why =~ "did not return JSON"
      assert why =~ "Welcome to Claude Code"
    end

    test "is_error is an error, not a successful empty result", %{
      work: work,
      response: response
    } do
      File.write!(
        response,
        ~s({"is_error":true,"subtype":"error_max_turns","result":"ran out of turns"})
      )

      assert {:error, why} = ClaudeCode.call("x", cwd: work)
      assert why =~ "error_max_turns"
      assert why =~ "ran out of turns"
    end

    test "a hang is killed rather than waited on", %{work: work, fake: fake} do
      fake!(fake, "#!/bin/sh\nsleep 30\n")

      assert {:error, why} = ClaudeCode.call("x", cwd: work, timeout_ms: 300)
      assert why =~ "did not finish"
    end

    test "no `claude` on PATH is an error for the caller, not an exit that kills it", %{
      tmp_dir: tmp,
      work: work
    } do
      # Every GitHub run since v0.5.0 had no `claude`, and the
      # `nil` from `System.find_executable/1` went into `System.cmd/3` inside a
      # linked task: `ArgumentError`, and the caller died with `EXIT` instead
      # of getting a value. The dispatcher is that caller, and a killed process
      # records nothing.
      #
      # The `PATH` is set here rather than taken from the machine, so this runs
      # the same on a workstation with Claude Code installed as on CI without
      # it. It holds `sh` and nothing else: the one thing missing is `claude`,
      # which is the question, and not the shell the adapter redirects through.
      only_sh = Path.join(tmp, "only-sh")
      File.mkdir_p!(only_sh)
      File.ln_s!(System.find_executable("sh"), Path.join(only_sh, "sh"))
      System.put_env("PATH", only_sh)

      assert {:error, why} = ClaudeCode.call("x", cwd: work, model: "haiku")
      assert why =~ "`claude` is not on PATH"

      # One sentence, in one place: what `call/2` says is what `available?/0`
      # would have said had it been asked at the same moment.
      assert {:unavailable, ^why} = ClaudeCode.available?()
    end
  end

  describe "what it reports" do
    test "the text, the cost, the turns and the denials", %{work: work} do
      assert {:ok, result} = ClaudeCode.call("x", cwd: work)

      assert result.output == "done"
      assert result.cost_usd == 0.0123
      assert result.turns == 3
      assert result.denials == []
      assert result.adapter == "claude_code"
    end

    test "tools it asked for and did not get", %{work: work, response: response} do
      # A run that spent its turns being told no did not do the work, and that
      # is a different failure from one that tried and was wrong.
      File.write!(
        response,
        ~s({"is_error":false,"result":"blocked","permission_denials":[{"tool_name":"Bash"}]})
      )

      assert {:ok, result} = ClaudeCode.call("x", cwd: work)
      assert [%{"tool_name" => "Bash"}] = result.denials
    end
  end

  # Outside the repository, not ExUnit's `tmp_dir`, which is under
  # `apps/noetic_harness/tmp/`. Probed on Claude Code 2.1.251 with the API
  # pointed at a closed port, so nothing was spent (bd-424): a session
  # started there loads the repository's skills and, by Claude Code's
  # documented walk up the tree, its CLAUDE.md, which is a large, paid-for
  # system prompt in a test that says "in its own directory". The project's
  # hooks did *not* load there: settings are read from the launch directory
  # only. A control run from the repository root ran `bd prime` and both
  # `noetic-harness hook` events, SessionEnd included. That is one version's
  # rule, and a test that must not write into the ledger should not depend
  # on it.
  defp outside_the_repository! do
    dir = Noetic.Harness.TestTmp.dir!("claude-live")
    on_exit(fn -> File.rm_rf(dir) end)

    repository = Noetic.Harness.Checkout.root()

    refute String.starts_with?(Path.expand(dir) <> "/", repository <> "/"),
           "the live test's directory #{dir} is inside the repository #{repository}"

    dir
  end

  describe "against a real model" do
    test "the directory the live test would use is outside the repository" do
      # The live test never runs unasked, so this is the only place its
      # directory is checked on every suite run: a TMPDIR that points inside
      # the checkout would put it back where bd-424 found it.
      assert File.dir?(outside_the_repository!())
    end

    @tag :live
    @tag timeout: 300_000
    test "it answers, in its own directory, and says what it cost", %{tmp_dir: tmp} do
      # `mix test --include live` runs this and spends money. Asked for on a
      # machine with no `claude`, it fails on the assertion below with the
      # adapter's own sentence, not with an `EXIT`.
      work = outside_the_repository!()

      System.put_env(
        "PATH",
        System.get_env("PATH")
        |> String.split(":")
        |> Enum.reject(&(&1 == Path.join(tmp, "bin")))
        |> Enum.join(":")
      )

      assert {:ok, result} =
               ClaudeCode.call("Reply with exactly the word: isolated",
                 cwd: work,
                 model: "haiku",
                 restricted: true
               )

      assert result.output =~ "isolated"
      assert result.cost_usd > 0
    end
  end
end
