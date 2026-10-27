defmodule Noetic.Harness.ContextTaskTest do
  @moduledoc """
  `noetic-harness context`'s three flags from earlier changes, as a
  person at a shell meets them: `--format brief-terms`, `--check-brief` and
  `--kb cached`.
  """

  # async: false: `Mix.shell/1` is VM-global, and these swap it for
  # `Mix.Shell.Process` to read what the task printed.
  use ExUnit.Case, async: false

  alias Noetic.Harness.{Fixture, KB}
  alias Noetic.Harness.KB.Glossary

  @glossary %{
    "terms" => [
      %{
        "id" => "term:brief",
        "en" => "brief",
        "ru" => "бриф",
        "status" => "decided",
        "definition" => "A brief reads EPIC <id>: branch …"
      }
    ]
  }

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
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

  defp with_tree(fun) do
    Fixture.with_tree(Fixture.minimal(), fn root ->
      Fixture.write_project(root)
      File.mkdir_p!(Path.join(root, "docs/kb/extraction"))
      File.write!(Path.join(root, "docs/kb/glossary.json"), JSON.encode!(@glossary))

      File.write!(
        Path.join(root, "docs/kb/extraction/G1_core.json"),
        JSON.encode!(%{
          "group" => "G1_core",
          "concepts" => [%{"id" => "concept:brief-shape", "name" => "brief shape"}]
        })
      )

      try do
        fun.(root)
      after
        KB.forget()
        Glossary.forget(root)
      end
    end)
  end

  test "--format brief-terms prints the section for a brief's first line" do
    with_tree(fn _ ->
      Mix.Tasks.Harness.Context.run([
        "--format",
        "brief-terms",
        "--title",
        "EPIC bd-1: branch claude/bd-1-x, every brief gets terms"
      ])

      text = output()
      assert text =~ "## Terms"
      assert text =~ "- `term:brief` — **brief** · бриф (decided)"
    end)
  end

  test "--check-brief passes a brief whose section names only glossary terms, and fails others" do
    with_tree(fn root ->
      File.write!(
        Path.join(root, "good.md"),
        "EPIC bd-1: x\n\n## Terms\n\n- `term:brief` — brief\n"
      )

      File.write!(Path.join(root, "bad.md"), "EPIC bd-1: x\n\n## Terms\n\n- `term:nope` — no\n")

      Mix.Tasks.Harness.Context.run(["--check-brief", "good.md"])
      assert output() =~ "good.md: the `## Terms` section names only glossary terms"

      assert_raise Mix.Error, ~r/1 problem/, fn ->
        Mix.Tasks.Harness.Context.run(["--check-brief", "bad.md"])
      end

      assert output() =~ "`term:nope` is not in docs/kb/glossary.json"
    end)
  end

  test "--kb cached never builds the index, and the bundle says what it left out" do
    with_tree(fn root ->
      Mix.Tasks.Harness.Context.run([
        "--title",
        "brief shape",
        "--capability",
        "elixir.implementation",
        "--kb",
        "cached"
      ])

      text = output()
      assert text =~ "kb (no cached index"
      refute File.exists?(KB.cache_dir(root))

      # The default builds it, and the next cached call has it.
      Mix.Tasks.Harness.Context.run([
        "--title",
        "brief shape",
        "--capability",
        "elixir.implementation"
      ])

      _ = output()
      KB.forget()

      Mix.Tasks.Harness.Context.run([
        "--title",
        "brief shape",
        "--capability",
        "elixir.implementation",
        "--kb",
        "cached"
      ])

      text = output()
      assert text =~ ~r/^\s+kb\s+[1-9]/m
      refute text =~ "kb (no cached index"
    end)
  end

  test "a --kb or --format that is not one of the words is refused" do
    assert_raise Mix.Error, ~r/--kb takes cached or build/, fn ->
      Mix.Tasks.Harness.Context.run([
        "--title",
        "x",
        "--capability",
        "elixir.otp",
        "--kb",
        "maybe"
      ])
    end

    assert_raise Mix.Error, ~r/--format takes brief-terms/, fn ->
      Mix.Tasks.Harness.Context.run(["--format", "json", "--title", "x"])
    end
  end
end
