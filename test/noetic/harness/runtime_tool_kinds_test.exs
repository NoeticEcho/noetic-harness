defmodule Noetic.Harness.RuntimeToolKindsTest do
  @moduledoc """
  A runtime tool's kind comes from a closed list (item D).

  `"plane": "runtime"` is a label the definition gives itself. Before this,
  `{"id": "git.write", "kind": "cli", "plane": "runtime"}` passed the `planes`
  check, and a runtime role holding it passed with it, because the check
  asked only whether the tool said it was runtime. A tool of kind `cli`,
  `service`, `mcp` or `builtin` runs or reaches something on the machine that
  calls it, whatever it says, so a runtime tool is `function` (a product
  function, called by name) or `data` (a read of the product's data), and
  nothing else.

  `validation.ex` is behind the evaluator fence, so this lands only with the
  person's approval.
  """

  # async: true: each test builds a root of its own and points only its own
  # process at it (`Noetic.Harness.put_root/1`, which a `Task` it starts
  # inherits); the loaders' caches are per process too. Nothing is shared.
  use ExUnit.Case, async: true

  import Noetic.Harness.RuntimePack, only: [root!: 2, edit!: 3, update_role: 3]

  alias Noetic.Harness.{Export, Validation}

  defp errors do
    {:ok, findings} = Validation.run(Export.definition_checks())
    for {:error, message} <- findings, do: message
  end

  # A tool labelled runtime, of `kind`, held by the rule clerk.
  defp labelled!(tag, kind) do
    root!("tool-kind-" <> tag, fn agents ->
      edit!(agents, "policies/tools.json", fn doc ->
        Map.update!(doc, "tools", fn tools ->
          tools ++
            [
              %{
                "id" => "git.write",
                "plane" => "runtime",
                "kind" => kind,
                "min_trust" => "T1",
                "present" => true,
                "doc" => "Commit to a branch."
              }
            ]
        end)
      end)

      edit!(agents, "registry/agents.json", fn doc ->
        update_role(
          doc,
          "editorial.rule_clerk",
          &Map.update!(&1, "tools", fn t -> t ++ ["git.write"] end)
        )
      end)
    end)
  end

  test "a runtime label does not make a cli tool a runtime one" do
    labelled!("cli", "cli")

    assert errors() == [
             "tool git.write: a runtime tool is of kind function or data, which run nothing on " <>
               "a machine, not cli"
           ]

    assert {:error, [_]} = Export.build()
  end

  for kind <- ~w(builtin service mcp) do
    test "nor a #{kind} tool" do
      labelled!(unquote(kind), unquote(kind))

      assert errors() == [
               "tool git.write: a runtime tool is of kind function or data, which run nothing on " <>
                 "a machine, not #{unquote(kind)}"
             ]
    end
  end

  for kind <- ~w(function data) do
    test "a #{kind} tool is one" do
      labelled!(unquote(kind), unquote(kind))
      assert errors() == []
    end
  end
end
