defmodule Noetic.Harness.Pack do
  @moduledoc """
  The engine's test registry: `test/support/pack/.agents/`, a frozen set of
  definitions the engine's own tests run on.

  ## Why the engine's tests do not read this repository's `.agents/`

  They did, and on purpose: a conductor test went through "the real WF-002"
  because what was worth knowing was whether the conductor agreed with the
  workflow this repository has. Two things were wrong with that. A change to
  this repository's registry — a lane renamed, a step added — failed engine tests
  that were about neither. And the engine could not be told from the project
  it serves: there was no test of the engine without this repository's definitions,
  so no test could back the claim a release would make.

  The pack is those definitions as they stood when the tests moved (2026-09-30): the workflows, the policies, the registry, the
  signals, the prompt templates, the schemas and the decision questions.
  Nothing reads it but the tests. It does not follow the live registry: when
  this repository's changes, the engine's tests do not.

  **Its words are not this repository's**. The pack is in the
  public tree `harness cut` writes, so the development repository's own
  vocabulary was mapped out of it, by one map applied to every file at once.
  Its product's name, where it is not the engine's, became `acme` (its
  skills, its applications' paths, the upstream's labels); its language
  became `gsl`; its knowledge store became `catalog`; and its name for an AI
  persona became `avatar`. None of the four was a word the pack or the tests
  already used, so no two meanings share one. The engine's names,
  `Noetic.Harness`, `noetic_harness`, `noetic-harness` and `NOETIC_*`, were
  kept. The tests that name the pack's words were changed to match, and the
  suite passing on it is what shows the map kept each test's meaning.

  **Nor is what the development repository builds**. Six of
  its domains describe the product rather than how it is developed, and the
  rule for the public tree is that what is not talked about does not go out.
  So they were cut from the pack, as they are from the full pack:
  - their roles, and the roles of other domains named for them;
  - their capabilities, and every reference to one;
  - their workflows, signals, kind signals, role rules and skills;
  - the lane only they used, and the gates only that lane ran;
  - the failure class that routed to them.

  A role of another domain that held one of their capabilities lost it, and
  a workflow step that asked for one now asks `governance.planning`. The tests
  that used one of them as an example now use one that is still here, for the
  same point.

  Four things in it are its own and were never this repository's:

  - `registry/project.json`, naming a project called `Pack`: context
    sources, and no integration or layout;
  - `policies/identity.json`'s one trusted key, generated for the pack with
    its private half thrown away. The freeze had copied the
    workspace's real key, its address and a path under the person's home;
    `FixtureHygieneTest` keeps any of that from coming back;
  - `skills/`, two one-paragraph skills, so a bundle has skills to attach;
  - `tree/`, the files those context sources find (a schema, a client, a
    migration, a changelog), linked into the top of each root. A file that
    would be `.ex` is `.exs`, because `test/support/` is compiled.

  What stays on the live registry are the tests that are about it — its
  validation, its generated files, its profiles, its labelled routes — and
  each says so in its moduledoc.

  ## A root per test

  `root/1` is a `setup` callback. It makes a root of the test's own whose
  `.agents/` links the pack's definitions and has fresh, writable `runs/`,
  `artifacts/`, `telemetry/`, `handoff/`, `memory/records/` and
  `evolution/`. So a test that writes a run writes it there, not into this
  repository, and two tests never see each other's runs. `git: true` makes
  the root a git repository with one commit, for the tests whose subject
  needs a head, and copies the definitions rather than linking them: its
  worktrees are where agents write.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @source Path.expand("pack/.agents", __DIR__)
  @tree Path.expand("pack/tree", __DIR__)
  @linked ~w(constitution.md registry policies workflows templates schemas skills decisions)
  @writable ~w(runs artifacts telemetry handoff memory/records evolution/environments evolution/candidates coordination)

  @doc "The `.agents/` entries `populate/2` links rather than makes."
  @spec linked() :: [String.t()]
  def linked, do: @linked

  @doc "Where the pack's definitions are."
  @spec source() :: Path.t()
  def source, do: @source

  @doc """
  `setup {Noetic.Harness.Pack, :root}`: a root of this test's own, on the
  pack, made the harness root for this process. Returns `root:`.

  A test tagged `this_repository: true` (usually a `@describetag`) is left on
  this repository's `.agents/`: it is a test *about* this repository's registry, in
  a module whose other tests are the engine's. The tag is the place that says
  so.
  """
  def root(context \\ %{})
  def root(%{this_repository: true}), do: :ok

  def root(context),
    do:
      {:ok,
       root:
         make(
           git: Map.get(context, :pack_git, false),
           integrations: Map.get(context, :pack_integrations, []),
           project: Map.get(context, :pack_project, %{})
         )}

  @doc "`setup {Noetic.Harness.Pack, :git_root}`: the same, as a git repository with one commit."
  def git_root(_context \\ %{}), do: {:ok, root: make(git: true)}

  @doc """
  Make a pack root and point this process at it. Undone at exit.

  `integrations: ["beads"]` switches those on in the root's `project.json`
  (`@tag pack_integrations: [...]` from `root/1`), and `project: %{...}`
  merges keys into it (`@tag pack_project: %{...}`). The registry is then a
  copy, not a link, so the change is written into the root and never into
  the pack.
  """
  @spec make(keyword()) :: Path.t()
  def make(opts \\ []) do
    root = Noetic.Harness.TestTmp.path("pack")

    changes =
      case Keyword.get(opts, :integrations, []) do
        [] ->
          Keyword.get(opts, :project, %{})

        names ->
          Map.put(Keyword.get(opts, :project, %{}), "integrations", Map.new(names, &{&1, true}))
      end

    # A git root holds copies: a worktree of it is where a test lets an agent
    # write, and a write through a link would land in the pack.
    copy? = Keyword.get(opts, :git, false)

    if changes == %{} do
      populate(root, copy: copy?)
    else
      populate(root, except: ["registry"], copy: copy?)
      copy(root, "registry")
      project = Path.join([root, ".agents", "registry", "project.json"])
      {:ok, doc} = Noetic.Harness.Loader.load(project)
      File.write!(project, Noetic.Harness.Loader.pretty!(Map.merge(doc, changes)))
    end

    if Keyword.get(opts, :git, false), do: git_init(root)

    # `put_root/1` is per process, and a test's process ends with the test,
    # so the override needs no undoing; the directory does.
    Noetic.Harness.put_root(root)
    on_exit(fn -> File.rm_rf(root) end)

    root
  end

  @doc """
  Give `root` a `.agents/` on the pack without pointing anything at it: the
  definitions linked, the writable directories made. `:except` leaves out
  linked entries a test replaces with a copy of its own (`copy/2`), and
  `tree: false` the pack's project tree. `copy: true` copies what it would
  link, for a root whose files a test or an agent may write.

  Never copy a linked entry of a root to change it: the copy would be the
  link, and the change would land in the pack. `copy/2` copies from the
  pack's source.
  """
  @spec populate(Path.t(), keyword()) :: Path.t()
  def populate(root, opts \\ []) do
    agents = Path.join(root, ".agents")
    File.mkdir_p!(agents)
    except = Keyword.get(opts, :except, [])

    link = if Keyword.get(opts, :copy, false), do: &File.cp_r!/2, else: &File.ln_s!/2

    for entry <- @linked, entry not in except do
      link.(Path.join(@source, entry), Path.join(agents, entry))
    end

    for dir <- @writable, do: File.mkdir_p!(Path.join(agents, dir))

    # The project the pack's `project.json` describes: a schema, a client, a
    # migration, a changelog, for its context sources to find. `tree: false`
    # leaves it out, for a test that counts the files in its root.
    tree = if Keyword.get(opts, :tree, true), do: File.ls!(@tree), else: []

    for entry <- tree, not File.exists?(Path.join(root, entry)) do
      link.(Path.join(@tree, entry), Path.join(root, entry))
    end

    root
  end

  @doc "Copy one of the pack's entries (`\"policies\"`) into `root`'s `.agents/`, as files a test may edit."
  @spec copy(Path.t(), String.t()) :: Path.t()
  def copy(root, entry) do
    target = Path.join([root, ".agents", entry])
    File.cp_r!(Path.join(@source, entry), target)
    target
  end

  defp git_init(root) do
    for args <- [
          ["init", "--quiet", "-b", "main"],
          ["config", "user.email", "t@t"],
          ["config", "user.name", "t"],
          ["config", "commit.gpgsign", "false"],
          ["add", "-A"],
          ["commit", "--quiet", "-m", "a pack root"]
        ] do
      {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    end
  end
end
