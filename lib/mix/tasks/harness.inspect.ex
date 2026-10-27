defmodule Mix.Tasks.Harness.Inspect do
  @moduledoc """
  What the harness is, and what of it is actually wired up here.

      noetic-harness inspect             counts and wiring
      noetic-harness inspect --tools     probe every tool and report reality against the policy

  The tool probe is the part worth running. `.agents/policies/tools.json`
  records what each tool is *expected* to be; the probe says what it *is*. A
  tool recorded present that is absent is the setup for a gate that silently
  does not run, which is the failure the whole reporting design exists to
  prevent.
  """
  @shortdoc "Inspect the harness: counts, wiring and tool availability"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]
  alias Noetic.Harness.{Adapters, Gates, Policy, Registry, Skills, Workflow}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [tools: :boolean])

    registry = Registry.load!()
    shell = Mix.shell()

    shell.info("root: #{Noetic.Harness.root()}")
    shell.info("")
    shell.info("definitions")

    shell.info(
      "  roles          #{length(registry.agents)} in #{map_size(registry.domains)} domains"
    )

    shell.info(
      "  nucleus        #{length(Registry.nucleus(registry))} (client adapters are generated for these)"
    )

    shell.info("  capabilities   #{map_size(registry.capabilities)}")
    shell.info("  archetypes     #{map_size(registry.archetypes)}")
    shell.info("  skills         #{length(Skills.list())}")

    case Workflow.list() do
      {:ok, workflows} ->
        steps = workflows |> Enum.flat_map(& &1["steps"]) |> length()
        shell.info("  workflows      #{length(workflows)} (#{steps} steps)")

      {:error, message} ->
        shell.error("  workflows      #{message}")
    end

    case Workflow.pipelines() do
      {:ok, pipelines} -> shell.info("  pipelines      #{length(pipelines)}")
      {:error, message} -> shell.error("  pipelines      #{message}")
    end

    case Gates.lanes() do
      {:ok, lanes} -> shell.info("  gate lanes     #{Enum.join(lanes, ", ")}")
      {:error, message} -> shell.error("  gate lanes     #{message}")
    end

    shell.info("")
    shell.info("generated adapters")

    case Adapters.drift(registry) do
      [] -> shell.info("  in sync with the canonical definitions")
      drifted -> Enum.each(drifted, &shell.info("  STALE  #{&1}"))
    end

    if opts[:tools], do: probe_tools(shell)
  end

  defp probe_tools(shell) do
    {:ok, doc} = Policy.tools()
    shell.info("")
    shell.info("tools (recorded → probed)")

    Enum.each(doc["tools"], fn tool ->
      actual = Policy.probe(tool)
      recorded = if tool["present"], do: :present, else: :absent

      flag =
        cond do
          actual == :unprobeable -> "?"
          actual == recorded -> " "
          true -> "!"
        end

      shell.info(
        "  #{flag} #{String.pad_trailing(tool["id"], 18)} " <>
          "#{String.pad_trailing(to_string(recorded), 10)} → #{actual}"
      )
    end)

    shell.info("")
    shell.info("  ! marks a disagreement between the policy and this machine.")

    shell.info(
      "  ? marks a tool with no shell probe — an MCP server, typically. Unknown, not present."
    )
  end
end
