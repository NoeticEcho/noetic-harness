defmodule Mix.Tasks.Harness.Agents do
  @moduledoc """
  The competency registry.

      noetic-harness agents                          every role, one line each
      noetic-harness agents --domain backend         one domain
      noetic-harness agents --capability typedb.schema   who supplies it
      noetic-harness agents --nucleus                the roles adapters are generated for
      noetic-harness agents --explain <id>           why this role has what it has

  `--explain` is the important one. A role's capabilities are *derived* from its
  domain and from the name rules in `.agents/registry/role_rules.json`, and this
  prints which rules fired. A wrong capability assignment is then a line in that
  file rather than a mystery.
  """
  @shortdoc "List and explain registered agent roles"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]
  alias Noetic.Harness.Registry

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [domain: :string, capability: :string, nucleus: :boolean, explain: :string]
      )

    registry = Registry.load!()
    shell = Mix.shell()

    cond do
      id = opts[:explain] ->
        explain(shell, registry, id)

      capability = opts[:capability] ->
        list(shell, Registry.supplying(registry, [capability], :any), registry)

      domain = opts[:domain] ->
        list(shell, Registry.in_domain(registry, domain), registry)

      opts[:nucleus] ->
        list(shell, Registry.nucleus(registry), registry)

      true ->
        list(shell, registry.agents, registry)
    end
  end

  defp list(shell, [], _registry), do: shell.info("(nothing matched)")

  defp list(shell, agents, _registry) do
    Enum.each(agents, fn agent ->
      marks =
        [
          if(agent["nucleus"], do: "*"),
          if(agent["status"] == "dormant", do: "dormant"),
          if("high_risk" in (agent["tags"] || []), do: "!")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("")

      shell.info(
        "#{String.pad_trailing(agent["id"], 44)} #{String.pad_trailing(agent["archetype"], 13)} " <>
          "#{agent["max_trust"]} #{String.pad_trailing(marks, 8)} #{agent["name"]}"
      )
    end)

    shell.info("")
    shell.info("#{length(agents)} roles.  * nucleus   ! high risk")
  end

  defp explain(shell, registry, id) do
    case Registry.fetch(registry, id) do
      :error ->
        Mix.raise("no role #{id}. `noetic-harness agents` lists them.")

      {:ok, agent} ->
        domain = Map.get(registry.domains, agent["domain"], %{})

        shell.info("#{agent["name"]}  (#{agent["id"]}, upstream #{agent["legacy_id"]})")
        shell.info("")
        shell.info("domain      #{agent["domain"]} — #{domain["summary"]}")
        shell.info("archetype   #{agent["archetype"]} (from the upstream mandate sentence)")

        shell.info(
          "max trust   #{agent["max_trust"]}  (domain ceiling #{domain["trust_ceiling"]})"
        )

        shell.info(
          "status      #{agent["status"]}#{if agent["nucleus"], do: ", nucleus", else: ""}"
        )

        shell.info("")
        shell.info("rules that fired on the role name:")

        case get_in(agent, ["derived_from", "rules"]) do
          [] -> shell.info("  (none — this role has its domain's defaults only)")
          rules -> Enum.each(rules, &shell.info("  /#{&1}/"))
        end

        if agent["overridden"] do
          shell.info("")
          shell.info("  plus .agents/registry/overrides/#{agent["id"]}.json")
        end

        section(shell, "capabilities", agent["capabilities"], fn capability ->
          "#{String.pad_trailing(capability, 30)} #{get_in(registry.capabilities, [capability, "doc"])}"
        end)

        section(shell, "skills", agent["skills"], & &1)
        section(shell, "tools", agent["tools"], & &1)
        section(shell, "gates", agent["gates"], & &1)

        case Registry.overlay(agent["id"]) do
          {:ok, _} -> shell.info("\noperational overlay: .agents/roles/#{agent["id"]}.md")
          :error -> shell.info("\nno operational overlay; the archetype's loop is its method")
        end
    end
  end

  defp section(shell, title, items, formatter) do
    shell.info("")
    shell.info("#{title}:")

    case items do
      [] -> shell.info("  (none)")
      list -> Enum.each(list, &shell.info("  #{formatter.(&1)}"))
    end
  end
end
