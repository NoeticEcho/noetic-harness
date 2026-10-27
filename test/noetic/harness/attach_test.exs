defmodule Noetic.Harness.AttachTest do
  @moduledoc """
  What a hook injects, and — more importantly — what it does when it cannot.

  The interesting property here is not that the route is good. It is that no
  input produces an exception, a non-zero exit or anything on stdout that is
  not JSON, because all three of those damage the session the hook was supposed
  to help.
  """

  # `async: true` since an earlier change. It was sync because the fixture root was
  # `NOETIC_HARNESS_ROOT`, a VM-global, so a fixture tree here was visible to
  # every other test in the VM. `Noetic.Harness.put_root/1` scopes it to this
  # process and the `Task`s it spawns, so the isolation is per test.
  use ExUnit.Case, async: true

  alias Noetic.Harness.Attach

  # On the pack (`Noetic.Harness.Pack`): what a hook injects is the engine's
  # answer, whichever registry it reads.
  setup {Noetic.Harness.Pack, :root}

  describe "the envelope" do
    test "every event produces JSON Claude Code can read, naming its own event" do
      for {event, name} <- [
            {"session_start", "SessionStart"},
            {"user_prompt", "UserPromptSubmit"},
            {"pre_tool", "PreToolUse"}
          ] do
        json = Attach.hook_json(event, payload_for(event))

        assert {:ok, %{"hookSpecificOutput" => output}} = JSON.decode(json)
        assert output["hookEventName"] == name
        assert is_binary(output["additionalContext"])
      end
    end

    test "an event nobody defined is answered, not raised on" do
      assert {:ok, text} = Attach.context("wat", %{})
      assert text =~ "unknown hook event"
    end

    test "`:skip` is an empty string, not an empty envelope" do
      # Claude Code treats no output as "inject nothing". An envelope with an
      # empty context would inject a header and nothing under it, which reads
      # as the harness having an opinion and declining to say it.
      assert Attach.hook_json("user_prompt", %{"prompt" => ""}) == ""
    end
  end

  describe "it cannot break the session" do
    # The work graph comes from `:ready`, the seam the resident
    # server hands its list through, and not from `bd`. `session_start` ignores
    # its payload, so four payloads were four `bd ready` calls, each bounded at
    # `Beads.timeout/0`: with a `bd` stand-in that sleeps, as one waiting on a
    # Dolt lock another session holds does, this test took 40.1 s idle, and
    # under load its ~500 file-server calls add ~18 s more. It timed out at 60 s
    # on the workstation. What `bd` says is `session_start`'s own test, above.
    test "a payload of the wrong shape entirely is survived" do
      no_work_graph = fn -> {:live, :error} end

      for payload <- [%{}, %{"prompt" => nil}, %{"tool_input" => "not a map"}, %{"prompt" => 42}] do
        for event <- Attach.events() do
          assert Attach.hook_json(event, payload, ready: no_work_graph) |> valid_json_or_empty?()
        end
      end
    end

    test "an exception below becomes injected text rather than a raise" do
      # `Run.current/0` reads `.agents/runs/`. Point the whole harness at a
      # path that is a *file*, so every read below raises, and assert the hook
      # still answers. This is the property the whole module exists for: a
      # broken `.agents/` must not take the session with it.
      tmp = Noetic.Harness.TestTmp.path("attach-not-a-dir")
      File.write!(tmp, "")
      previous = Noetic.Harness.root_override()
      Noetic.Harness.put_root(tmp)

      try do
        assert {:ok, text} = Attach.context("session_start", %{})
        assert is_binary(text)
        assert text =~ "[harness]"
      after
        if previous,
          do: Noetic.Harness.put_root(previous),
          else: Noetic.Harness.delete_root()

        File.rm(tmp)
      end
    end
  end

  describe "user_prompt" do
    test "a prompt the router can place gets the workflow, the lane and the gates" do
      assert {:ok, text} =
               Attach.context("user_prompt", %{
                 "prompt" => "the product channel crashes mid-ritual when two onlookers join"
               })

      assert text =~ "WF-003"
      assert text =~ "lane "
      assert text =~ "gates that will have to pass:"
    end

    test "a prompt the router cannot place injects nothing at all" do
      # Not a hedged route, not an apology: nothing. A low-confidence route
      # presented in the session's own context is read as authority.
      assert Attach.context("user_prompt", %{"prompt" => "ok thanks"}) == :skip
    end

    test "the block says where it came from" do
      assert {:ok, text} = Attach.context("user_prompt", %{"prompt" => "cut the v0.3.0 release"})
      assert String.starts_with?(text, "[harness]")
    end
  end

  describe "pre_tool" do
    test "an edit gets the lane its path belongs to, and is explicitly advisory" do
      assert {:ok, text} =
               Attach.context("pre_tool", %{
                 "tool_name" => "Edit",
                 "tool_input" => %{"file_path" => "apps/acme_web/assets/js/app.ts"}
               })

      assert text =~ "lane "
      assert text =~ "Advisory"
    end

    test "a tool that does not write is not commented on" do
      assert Attach.context("pre_tool", %{
               "tool_name" => "Read",
               "tool_input" => %{"file_path" => "apps/acme_web/assets/js/app.ts"}
             }) == :skip
    end

    test "nothing here can deny a tool call" do
      # The envelope carries `additionalContext` and no `permissionDecision`.
      # A blocking hook built on a router with known routing defects — three
      # found and fixed while the overlays were built, two more while this was
      # — blocks real work.
      json =
        Attach.hook_json("pre_tool", %{
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => "apps/acme_web/assets/js/app.ts"}
        })

      assert {:ok, %{"hookSpecificOutput" => output}} = JSON.decode(json)
      refute Map.has_key?(output, "permissionDecision")
    end
  end

  describe "session_start" do
    test "it says what the ledger, the work graph and the services are doing" do
      assert {:ok, text} = Attach.context("session_start", %{})

      assert text =~ "run"
      assert text =~ "noetic-harness route"
    end
  end

  defp payload_for("user_prompt"), do: %{"prompt" => "cut the v0.3.0 release"}

  defp payload_for("pre_tool"),
    do: %{
      "tool_name" => "Edit",
      "tool_input" => %{"file_path" => "apps/acme_web/assets/js/app.ts"}
    }

  defp payload_for(_), do: %{}

  defp valid_json_or_empty?(""), do: true
  defp valid_json_or_empty?(json), do: match?({:ok, %{}}, JSON.decode(json))
end
