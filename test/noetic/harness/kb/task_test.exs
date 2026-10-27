defmodule Noetic.Harness.KB.TaskTest do
  @moduledoc """
  `noetic-harness kb`: what a person at a shell sees.
  """

  # Not async: `Mix.shell/1` is VM-global, and these swap it for
  # `Mix.Shell.Process` to read what the task printed; an async test swapping
  # it back mid-run would send this test's lines to somebody else's mailbox.
  use ExUnit.Case, async: false

  alias Noetic.Harness.KB

  @group %{
    "group" => "G4_lighthouse",
    "documents" => [
      %{
        "id" => "doc:keeper-log",
        "path" => "/srv/checkout/_refdoc/keeper_log.md",
        "title" => "Журнал смотрителя",
        "summary" => "Что помнит робот-смотритель."
      }
    ],
    "concepts" => [
      %{
        "id" => "concept:keeper-memory-shelves",
        "name" => "Три полки памяти робота",
        "aliases" => ["memory shelves"],
        "definition" => "Три полки памяти с разными замками.",
        "sources" => ["doc:keeper-log"]
      }
    ]
  }

  setup do
    root = Noetic.Harness.TestTmp.path("kb-task") |> Noetic.Harness.Fixture.write_project()
    path = Path.join([root, "docs/kb/extraction/G4_lighthouse.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(@group))
    File.mkdir_p!(Path.join(root, "_refdoc"))
    File.write!(Path.join(root, "_refdoc/keeper_log.md"), "x")

    # `setup` runs in the test's own process, so the root is the test's.
    Noetic.Harness.put_root(root)
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    # `on_exit` runs in another process, which does not have the root: the
    # index this left in `:persistent_term` is erased by its key.
    on_exit(fn ->
      Mix.shell(previous_shell)
      :persistent_term.erase({KB, Path.expand(root)})
      File.rm_rf!(root)
    end)

    :ok
  end

  defp output do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, :info, [line]} -> line
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
    |> Enum.join("\n")
  end

  test "a glossary term's hit prints its link into glossary.md, and a record without one prints none" do
    root = Noetic.Harness.root()

    File.write!(
      Path.join(root, "docs/kb/glossary.json"),
      JSON.encode!(%{
        "terms" => [
          %{
            "id" => "term:spectators",
            "en" => "spectators",
            "ru" => "зрители",
            "aliases" => ["audience"],
            "status" => "decided",
            "domain" => "product",
            "definition" => "Those who watch an avatar's world without acting in it."
          }
        ]
      })
    )

    Mix.Tasks.Harness.Kb.run(["зрители"])
    text = output()

    assert text =~ "1. term:spectators — spectators · зрители (decided)"
    assert text =~ "   → docs/kb/glossary.md#term-spectators"

    Mix.Tasks.Harness.Kb.run(["памятью", "роботов", "--kind", "concept"])
    refute output() =~ "→ docs/kb/glossary.md"
  end

  test "prints the backend, the index and each hit with its source" do
    Mix.Tasks.Harness.Kb.run(["памятью", "роботов", "--limit", "2"])
    text = output()

    assert text =~ "answered by files"
    assert text =~ ~r/index [0-9a-f]{12} · 2 records from 1 file\(s\) · built in \d+ ms/
    assert text =~ "postgres:"
    assert text =~ "qdrant:"
    assert text =~ "1. concept:keeper-memory-shelves"
    assert text =~ "← _refdoc/keeper_log.md"
  end

  test "--query is the same as the positional words, and --json is JSON" do
    Mix.Tasks.Harness.Kb.run(["--query", "памятью роботов", "--json"])
    decoded = JSON.decode!(output())

    assert decoded["backend"] == "files"
    assert hd(decoded["hits"])["id"] == "concept:keeper-memory-shelves"
    assert decoded["index"]["from"] in ~w(built memory disk)
  end

  test "an empty query is a refusal, not a crash" do
    assert_raise Mix.Error, ~r/a query is needed/, fn -> Mix.Tasks.Harness.Kb.run([]) end
  end
end
