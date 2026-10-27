defmodule Noetic.Harness.Fixture do
  @moduledoc """
  A throwaway `.agents/` tree, for the tests that need to see the harness read
  something broken.

  The rest of the suite runs against the repository's real definitions on
  purpose: a validator tested only against fixtures proves that the validator
  works, not that the repository is valid, and the second is the claim anybody
  cares about.

  The override is **per process**, not per VM: `Noetic.Harness.put_root/1`
  writes the process dictionary and `root/0` walks `$callers`, so a test using
  this can be `async: true`. It was `System.put_env/2` until an earlier change, and
  the cost of that is on the record — a test that forgot `async: false` made
  three of five full suite runs fail, under a message naming a module it had
  never heard of.

  A test that starts a **subprocess** still has to pass `NOETIC_HARNESS_ROOT`
  through `System.cmd/3`'s `:env`, because a child process cannot read this
  one's dictionary. That is already per-subprocess and was never the problem.
  """

  @doc """
  Run `fun` with the harness root pointing at a temporary tree built from
  `files` — a map of `.agents`-relative path to content (a string, or a term
  which is encoded as JSON).
  """
  def with_tree(files, fun) do
    root = Noetic.Harness.TestTmp.path("harness-fixture")

    Enum.each(files, fn {path, content} ->
      full = Path.join([root, ".agents", path])
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, encode(content))
    end)

    previous = Noetic.Harness.put_root(root)

    try do
      fun.(root)
    after
      if previous,
        do: Noetic.Harness.put_root(previous),
        else: Noetic.Harness.delete_root()

      File.rm_rf!(root)
    end
  end

  @doc """
  Write `.agents/registry/project.json` under `root`. The engine
  reads the knowledge base's paths from it, so a fixture root with a
  `docs/kb/` of its own has to say where they are, as a repository does. The
  default is this repository's `kb` section: the fixtures were written
  against that layout.
  """
  def write_project(root, project \\ project()) do
    path = Path.join([root, ".agents", "registry", "project.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encode(project))
    root
  end

  @doc """
  A project file with this repository's knowledge-base paths, app layout
  and integrations, and nothing else.
  """
  def project do
    %{
      "version" => 1,
      "integrations" => %{
        "beads" => true,
        "knowledge_base" => true,
        "jido" => true,
        "workers" => true
      },
      "layout" => %{
        "apps" => "apps",
        "lib" => "lib",
        "test" => "test",
        "test_suffix" => "_test.exs",
        "test_command" => ["mix", "test"],
        "build" => "_build"
      },
      "kb" => %{
        "root" => "docs/kb",
        "extraction" => "docs/kb/extraction",
        "glossary" => "docs/kb/glossary.json",
        "glossary_parts" => "docs/kb/glossary",
        "glossary_markdown" => "docs/kb/glossary.md",
        "reading_maps" => "docs/kb/reading-maps",
        "readme" => "docs/kb/README.md",
        "guide" => "docs/guides/knowledge-base.md",
        "corpus" => "_refdoc",
        "source_roots" => ["_refdoc", "docs", "apps", "canon", "design"]
      }
    }
  end

  @doc "A minimal but internally consistent tree, which individual tests then break."
  def minimal do
    %{
      "constitution.md" => "# Constitution\n\nBe careful.\n",
      "registry/domains.json" => %{
        "version" => 1,
        "domains" => [
          %{
            "id" => "backend",
            "slug" => "backend",
            "upstream" => "Backend",
            "summary" => "The BEAM side.",
            "owns" => ["apps/"],
            "capabilities" => ["elixir.implementation"],
            "skills" => [],
            "context" => ["target_module"],
            "trust_ceiling" => "T2"
          }
        ]
      },
      "registry/capabilities.json" => %{
        "version" => 1,
        "capabilities" => [
          %{
            "id" => "elixir.implementation",
            "doc" => "Write Elixir.",
            "skills" => [],
            "tools" => ["read"],
            "gates" => ["compile"],
            "evidence" => ["the commands you ran"],
            "context" => ["target_module"]
          }
        ]
      },
      "registry/archetypes.json" => %{
        "version" => 1,
        "archetypes" => [
          %{
            "id" => "owner",
            "name" => "Subsystem owner",
            "upstream_mandate" => "Own it.",
            "stance" => "You are accountable.",
            "loop" => ["READ", "PATCH", "TEST"],
            "loop_notes" => %{},
            "evidence_required" => ["output"],
            "prohibited" => ["guessing"],
            "completion" => "gates green",
            "default_trust" => "T2",
            "terminal_states" => ["DONE", "FAILED", "BLOCKED", "UNCERTAIN", "NEEDS_REVIEW"]
          }
        ]
      },
      "registry/role_rules.json" => %{
        "version" => 1,
        "rules" => [%{"match" => "engineer"}],
        "nucleus" => %{"ids" => ["backend.engineer"]}
      },
      "registry/agents.json" => %{
        "version" => 1,
        "provenance" => %{"sources" => []},
        "agents" => [
          %{
            "id" => "backend.engineer",
            "legacy_id" => "A001",
            "name" => "Engineer",
            "domain" => "backend",
            "archetype" => "owner",
            "capabilities" => ["elixir.implementation"],
            "skills" => [],
            "tools" => ["read"],
            "gates" => ["compile"],
            "max_trust" => "T2",
            "tags" => [],
            "status" => "active",
            "nucleus" => true,
            "derived_from" => %{"rules" => [], "domain" => "backend", "mandate" => "owner"}
          }
        ]
      },
      "policies/trust_levels.json" => %{
        "version" => 1,
        "levels" =>
          Enum.map(~w(T0 T1 T2 T3 T4 T5), fn id ->
            %{
              "id" => id,
              "name" => String.downcase(id),
              "summary" => "level #{id}",
              "may" => ["something"]
            }
          end),
        "escalation" => %{"never_self_granted" => true, "never_delegated_sideways" => true}
      },
      "policies/tools.json" => %{
        "version" => 1,
        "tools" => [
          %{"id" => "read", "kind" => "builtin", "min_trust" => "T0", "present" => true},
          %{"id" => "deploy", "kind" => "cli", "min_trust" => "T4", "present" => true}
        ],
        "rules" => ["least privilege"]
      },
      "policies/gates.json" => %{
        "version" => 1,
        "lanes" => [%{"id" => "fast", "gates" => ["compile"]}],
        "gates" => [
          %{
            "id" => "compile",
            "name" => "compile",
            "kind" => "command",
            "command" => "true",
            "requires" => [],
            "severity" => "blocking"
          }
        ]
      }
    }
  end

  @doc "Copy the pack's prompt templates into a fixture tree, so prompts can be composed there."
  def with_templates(files) do
    templates =
      Path.wildcard(Path.join([real_agents(), "templates", "prompt", "*"]))
      |> Map.new(fn path ->
        {Path.join(["templates", "prompt", Path.basename(path)]), File.read!(path)}
      end)

    Map.merge(files, templates)
  end

  # The pack's, not this checkout's: the engine's tests run on the pack, and a
  # standalone checkout of the engine has no `.agents/` of its own.
  defp real_agents, do: Noetic.Harness.Pack.source()

  defp encode(content) when is_binary(content), do: content
  defp encode(content), do: JSON.encode!(content)
end
