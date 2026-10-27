defmodule Mix.Tasks.Harness.Context do
  @moduledoc """
  What context would be assembled for a task, before anything is spent on it.

      noetic-harness context --title "the onlooker's cloak clips through the path"
      noetic-harness context --paths lib/my_app/parser.ex
      noetic-harness context --capability typedb.schema --capability semantic.modeling
      noetic-harness context --render     print it as the agent would receive it
      noetic-harness context --projection what a decision model would be shown: the
                                       version, the hash, what was left out and how
                                       it was cut — never the state itself
      noetic-harness context --kb cached  never build the knowledge-base index: use it only
                                       when it is in memory or on disk
      noetic-harness context --format brief-terms --title "EPIC bd-1: branch …, scope …"
                                       the `## Terms` section of a coordinator's brief
                                       (`Noetic.Harness.Brief`)
      noetic-harness context --check-brief .agents/coordination/coord-….json
                                       what is wrong with a brief's `## Terms` section;
                                       exits non-zero when anything is

  Without `--render` this prints the *shape*: which sources were selected, how
  many items each contributed, and which requested sources could not be
  resolved. That last list is the useful one — it says what an agent would be
  working without.

  `--kb cached` is for a caller that must not wait for a build: the MCP
  server's `harness_context` among them. Every bundle carries knowledge-base
  hits, and on a machine with no cached index the default builds
  one first, ~7 s. With `--kb cached` such a bundle has no hits and says so
  under *Not attached*. `--kb build` is the default, spelled out.

  `--format brief-terms` and `--check-brief` read no capabilities and route
  nothing: they are about the words a brief uses, and `Noetic.Harness.Brief`
  has the why. `--check-brief` reads the file it is given, so it is not on the
  MCP allow-list.
  """
  @shortdoc "Show the context bundle a task would receive"

  use Mix.Task

  # Without a requirement, mix runs this task against whatever

  # beams the last compile left, and answers for code that is not on disk.

  @requirements ["compile"]
  alias Noetic.Harness.{Context, Router}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          title: :string,
          body: :string,
          paths: :string,
          capability: :keep,
          render: :boolean,
          projection: :boolean,
          limit: :integer,
          kb: :string,
          format: :string,
          check_brief: :string
        ]
      )

    cond do
      path = opts[:check_brief] -> check_brief(path)
      opts[:format] == "brief-terms" -> brief_terms(opts)
      opts[:format] -> Mix.raise("--format takes brief-terms, not #{inspect(opts[:format])}")
      true -> bundle(opts)
    end
  end

  defp kb_mode(nil), do: :build
  defp kb_mode("build"), do: :build
  defp kb_mode("cached"), do: :cached
  defp kb_mode(other), do: Mix.raise("--kb takes cached or build, not #{inspect(other)}")

  defp brief_terms(opts) do
    paths = if opts[:paths], do: String.replace(opts[:paths], ",", " ")
    text = Enum.join([opts[:title], opts[:body], paths] |> Enum.reject(&is_nil/1), " ")
    if String.trim(text) == "", do: Mix.raise("--format brief-terms needs --title")

    case Noetic.Harness.Brief.terms(text) do
      {:ok, terms, truncated} ->
        Mix.shell().info(Noetic.Harness.Brief.render(terms, truncated))

      {:error, :absent} ->
        Mix.raise(
          case Noetic.Harness.KB.Glossary.path() do
            nil ->
              ".agents/registry/project.json names no kb.glossary, so there are no terms to name"

            path ->
              "there is no #{path}, so there are no terms to name"
          end
        )

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp check_brief(path) do
    with {:ok, brief} <- Noetic.Harness.Brief.read(path) do
      case Noetic.Harness.Brief.check(brief) do
        [] ->
          Mix.shell().info("#{path}: the `## Terms` section names only glossary terms")

        findings ->
          Enum.each(findings, &Mix.shell().info("#{path}: #{&1}"))
          Mix.raise("#{path}: #{length(findings)} problem(s) with its `## Terms` section")
      end
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp bundle(opts) do
    shell = Mix.shell()
    paths = split(opts[:paths])
    work = %{title: opts[:title], body: opts[:body], paths: paths}

    capabilities =
      case Keyword.get_values(opts, :capability) do
        [] ->
          case Router.route(work) do
            {:ok, route} ->
              shell.info(
                "(capabilities inferred by the router: #{Enum.join(route.capabilities, ", ")})\n"
              )

              route.capabilities

            {:error, message} ->
              Mix.raise(message)
          end

        given ->
          given
      end

    projection? = opts[:projection] == true

    case Context.build(work,
           capabilities: capabilities,
           paths: paths,
           limit: opts[:limit] || 8,
           kb: kb_mode(opts[:kb])
         ) do
      {:error, message} ->
        Mix.raise(message)

      {:ok, bundle} when projection? ->
        p = Noetic.Harness.Projection.from_bundle(work, bundle, opts[:limit] || 8)
        shell.info("projection  #{p["projection_version"]}")
        shell.info("hash        #{p["hash"]}")

        shell.info(
          "included    #{Enum.map_join(p["included"], ", ", &"#{&1["key"]} (#{&1["items"]})")}"
        )

        shell.info("truncation  #{p["truncation"]}")
        shell.info("excluded")
        Enum.each(p["excluded"], &shell.info("  #{&1["what"]} — #{&1["why"]}"))

      {:ok, bundle} ->
        if opts[:render] do
          shell.info(Context.render(bundle))
        else
          shell.info("sections")

          Enum.each(bundle.sections, fn section ->
            more = if section.truncated, do: "+", else: " "

            shell.info(
              "  #{String.pad_trailing(section.key, 22)} #{String.pad_leading(to_string(length(section.items)), 3)}#{more}  #{section.why}"
            )
          end)

          shell.info("")
          shell.info("skills  #{bundle.skills |> Enum.map(& &1.name) |> Enum.join(", ")}")
          shell.info("memory  #{length(bundle.memory)} record(s)")

          case bundle.unresolved do
            [] ->
              shell.info("")
              shell.info("every context source these capabilities asked for was resolved")

            keys ->
              shell.info("")
              shell.info("NOT RESOLVED — an agent would work without these:")
              Enum.each(keys, &shell.info("  #{&1}"))
          end
        end
    end
  end

  defp split(nil), do: []
  defp split(value), do: String.split(value, [",", " "], trim: true)
end
