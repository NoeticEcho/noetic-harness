defmodule Noetic.Harness.KB.LoadMarkerTest do
  @moduledoc """
  What `noetic-harness kb` says about a knowledge store that `bin/worker-session-start` is
  still loading, has loaded, or failed to load. The marker is the
  one the hook writes; these tests write it by hand, in each of its states,
  into a directory of their own.
  """
  # async: true. Every marker is a file under a temporary directory, passed by
  # path; nothing reads the repository's own, and the note's project is the
  # pack's.
  use ExUnit.Case, async: true

  alias Noetic.Harness.KB.{LoadMarker, Backends}

  # The note names the kb root and is written only with `knowledge_base` on, and both
  # come from `project.json`: the pack's here, with the two set, where it used
  # to be this repository's (`Noetic.Harness.Pack`). Module-wide,
  # because the doctests read it too.
  @moduletag pack_integrations: ["knowledge_base"]
  @moduletag pack_project: %{"kb" => %{"root" => "docs/kb"}}
  setup {Noetic.Harness.Pack, :root}

  doctest LoadMarker

  defp marker!(contents) do
    dir = Noetic.Harness.TestTmp.dir!("load-marker")
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "worker-session-start.kb.json")
    File.write!(path, contents)
    path
  end

  # A pid that /proc does not have: one past the kernel's ceiling.
  defp dead_pid do
    case File.read("/proc/sys/kernel/pid_max") do
      {:ok, max} -> String.to_integer(String.trim(max)) + 1
      _ -> 4_194_305
    end
  end

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp loading(pid) do
    ~s|{"state":"loading","step":"waiting for Postgres at localhost:5432","started_at":"2026-09-25T13:40:00Z","tree":"#{String.duplicate("a", 40)}","pid":#{pid}}|
  end

  describe "status/1" do
    test "no marker is :absent, which is the workstation, and says nothing" do
      assert LoadMarker.status("/nonexistent/worker-session-start.kb.json") == %{state: :absent}
      assert LoadMarker.describe(%{state: :absent}) == nil
    end

    test "a load whose job is alive is :loading, with its step and since when" do
      path = marker!(loading(String.to_integer(System.pid())))

      assert %{state: :loading, step: "waiting for Postgres at localhost:5432"} =
               load = LoadMarker.status(path)

      assert load.since == "2026-09-25T13:40:00Z"
    end

    test "a load whose job is gone is :stopped, and says where to look" do
      if File.dir?("/proc/self") do
        load = LoadMarker.status(marker!(loading(dead_pid())))

        assert load.state == :stopped
        assert LoadMarker.describe(load) =~ "stopped without saying why"
        assert LoadMarker.describe(load) =~ ".agents/telemetry/worker-session-start.log"
      end
    end

    test "a failed load carries its reason" do
      path =
        marker!(~s|{"state":"failed","reason":"mix kb.load exited 1","started_at":"x"}|)

      assert %{state: :failed, reason: "mix kb.load exited 1"} = LoadMarker.status(path)
    end

    test "a finished load counts the knowledge store's records, not TypeDB's sourcings" do
      path =
        marker!(
          ~s|{"state":"loaded","finished_at":"2026-09-25T13:42:00Z","counts":{"concepts":3,"quotes":4,"sourcings":90}}|
        )

      assert %{state: :loaded, records: 7, finished_at: "2026-09-25T13:42:00Z"} =
               LoadMarker.status(path)
    end

    test "a marker that is not one is :unreadable, not a crash" do
      for contents <- ["", "{", "[]", ~s|{"state":"on fire"}|] do
        assert LoadMarker.status(marker!(contents)) == %{state: :unreadable}, contents
      end
    end
  end

  describe "the knowledge store's note" do
    test "a knowledge store that answers while the load runs is not reported as simply up" do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)

      try do
        [store, qdrant] =
          Backends.probe(
            postgres: {"127.0.0.1", port},
            qdrant: {"127.0.0.1", closed_port()},
            marker: marker!(loading(String.to_integer(System.pid())))
          )

        assert %{up: true, load: :loading} = store
        assert store.note =~ "answers at 127.0.0.1:#{port}, but docs/kb is still loading into it"
        assert store.note =~ "waiting for Postgres"
        assert store.note =~ "files answered"
        refute Map.has_key?(qdrant, :load)
      after
        :gen_tcp.close(socket)
      end
    end

    test "a loaded knowledge store says when and how much, and a failed one why" do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)

      try do
        loaded = marker!(~s|{"state":"loaded","finished_at":"T","counts":{"concepts":5}}|)
        [store, _] = Backends.probe(postgres: {"127.0.0.1", port}, marker: loaded)
        assert store.note =~ "docs/kb was loaded into it at T (5 records)"
        assert store.note =~ "does not query it yet"

        failed = marker!(~s|{"state":"failed","reason":"Postgres did not answer"}|)
        [store, _] = Backends.probe(postgres: {"127.0.0.1", closed_port()}, marker: failed)
        assert store.note =~ "is not reachable at"
        assert store.note =~ "the load of docs/kb into it failed: Postgres did not answer"
      after
        :gen_tcp.close(socket)
      end
    end

    test "without a marker the notes are what they were" do
      [store, _] =
        Backends.probe(postgres: {"127.0.0.1", closed_port()}, marker: "/nonexistent/marker.json")

      assert store.note ==
               "Postgres (the knowledge store) is not reachable at 127.0.0.1:#{store.address |> String.split(":") |> List.last()}; files answered"

      refute Map.has_key?(store, :load)
    end
  end
end
