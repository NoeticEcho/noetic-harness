defmodule Noetic.Harness.PathLiteralsTest do
  @moduledoc """
  The engine names no file of the project it serves.

  Every string literal in `apps/noetic_harness/lib/**` that names a
  repository path is listed, and each has a reason to be in code or it
  fails this test. The project's paths are `.agents/registry/project.json`'s,
  read through `Noetic.Harness.Project`.

  What is read is the code, not its prose. The literals come from
  `Code.string_to_quoted/2`, with `@moduledoc`, `@doc`, `@typedoc` and
  `@shortdoc` skipped: a moduledoc citing a design decision is a citation,
  and a literal passed to `File.read/1` is a dependency. A grep over the text
  could not tell the two apart. It would also have been green while a path
  was built by interpolation. A literal's fragments on either side of the
  interpolation are strings of their own, so they are read here too.

  ## What may stay in code, and why

  - **The engine's own command**, `noetic-harness` and `noetic-harness mcp`, in
    the hints it prints. They name the harness, not the project. A packaged
    engine renames its launcher once (§6 epic 7).
  - **The clients' files**: `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.claude/`,
    `.cursor/`, `.codex/`, `.gemini/`. These are where Claude Code, Codex,
    Gemini and Cursor read their instructions, and the adapters write them
    in any repository the engine serves.
  - **`bd`'s layout**, `.beads/` and `.beads/redirect`, in `beads.ex`, the
    optional integration (§2.2), and in `environments.ex`, where a commit's
    `.beads/` changes are inert to a test.
  - **`project.json`'s own vocabulary**, `"apps"` and `"docs"`, in
    `project.ex` and `context.ex`: a key of its `layout` and a kind of its
    context sources, not a path.
  - **The cut's two trees**, in `cut.ex`: the engine's own
    `lib/`, `priv/` and `test/` that it reads, and the `mix.exs`, `README.md`,
    `.github/workflows/ci.yml` and the rest that it writes; and in
    `cut/citations.ex`, the development repository's ADR
    directory it removes from that tree and the name it gives it in test
    data; and in `cut/command.ex`, the development repository's command it
    renames; and in `cut/full_pack.ex`, `cut/terms.ex` and the cut's task,
    the full pack's directory and the context keys it maps; and
    in `cut/live_tests.ex`, the tree's test directory. They are
    the engine's paths, not those of a project it serves.

  Nothing else, since an earlier change: the last three project paths are read from
  the layout now (`context.ex`'s `lib/` → `test/`, `brief.ex`'s apps
  directory), and `resident.ex` finds its beams from its own module rather
  than guessing `_build/dev`. `@pending` is empty.
  - **Fenced**: nothing, since an earlier change. The `apps/<app>` layout and
    `mix test` in `environments.ex`, `scoring.ex` and `tree.ex` were listed
    here one by one while the evaluator fence kept them. They are the
    project's `layout` now, moved with the person's quoted approval. The
    list stays: a literal a fenced file cannot yet lose is listed here
    exactly, and a stale entry fails this test so the list cannot outlive
    what it lists.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)

  # A token that names a path in a repository: a top directory with its `/`,
  # a hidden or underscored directory with or without one, or a well-known
  # file. `docs` alone is a word; `docs/` is a path.
  @token ~r{(?<![\w.-])(?:\./)?(?:(?:docs|apps|design|bin|scripts|config|deps|priv|lib|test|canon)/[^\s"'`),;\]]*|(?:_refdoc|_dev_noetic_harness|_build|\.beads|\.claude|\.github|\.cursor|\.codex|\.gemini)(?:/[^\s"'`),;\]]*)?|(?:CLAUDE|AGENTS|GEMINI|CHANGELOG|README)\.md|mix\.(?:exs|lock)|\.tool-versions|\.mcp\.json|docker-compose[\w.-]*)}

  @docs [:moduledoc, :doc, :typedoc, :shortdoc]

  # {rule, where it may appear (nil: anywhere), why}
  @allowed [
    {~r{^(?:CLAUDE|AGENTS|GEMINI)\.md$}, nil, "a client's instructions file"},
    {~r{^/?\.(?:claude|cursor|codex|gemini)(?:/.*)?$}, nil, "a client's directory"},
    {~r{^\.beads(?:/redirect)?/?$}, ["noetic/harness/beads.ex", "noetic/harness/environments.ex"],
     "bd's layout"},
    {~r{^(?:apps|docs)$}, ["noetic/harness/project.ex", "noetic/harness/context.ex"],
     "a key or a source kind of project.json, not a path"},
    {~r{.},
     [
       "noetic/harness/cut.ex",
       "noetic/harness/cut/citations.ex",
       "noetic/harness/cut/command.ex",
       "noetic/harness/cut/terms.ex",
       "noetic/harness/cut/full_pack.ex",
       "noetic/harness/cut/live_tests.ex",
       "mix/tasks/harness.cut.ex"
     ], "the engine's own source tree and the public tree the cut writes, not a project's"}
  ]

  # Behind the evaluator fence, and an earlier change's shared_change_requests[]:
  # {file, token, how many}. Exact, so the list shrinks when they move.
  @fenced []

  # Outside the fence, and outside the epic that found them: {file, token,
  # how many, where it goes}. Exact, as `@fenced` is.
  @pending []

  defp literals do
    for file <- Path.wildcard(Path.join(@lib, "**/*.ex")), into: [] do
      relative = Path.relative_to(file, @lib)

      {:ok, ast} =
        Code.string_to_quoted(File.read!(file),
          literal_encoder: &{:ok, {:__block__, &2, [&1]}},
          file: file
        )

      {_, found} =
        Macro.prewalk(ast, [], fn
          {:@, _, [{name, _, _}]}, acc when name in @docs ->
            {:skipped, acc}

          {:__block__, meta, [text]} = node, acc when is_binary(text) ->
            {node, [{meta[:line], text} | acc]}

          {:<<>>, meta, parts} = node, acc ->
            {node, for(part <- parts, is_binary(part), do: {meta[:line], part}) ++ acc}

          node, acc ->
            {node, acc}
        end)

      {relative, Enum.reverse(found)}
    end
  end

  # A literal that is a top directory's bare name is a path too:
  # `Path.join(root, "apps")` and `["apps", app | _]` named the umbrella's
  # layout without a `/` for `@token` to see (an earlier change found both).
  @bare ~w(apps docs design config scripts bin _refdoc)

  defp tokens do
    for {file, found} <- literals(),
        {line, text} <- found,
        token <- bare(text) ++ for([token] <- Regex.scan(@token, text), do: token),
        do: {file, line, String.replace(token, ~r/[.:]+$/, "")}
  end

  defp bare(text), do: if(text in @bare, do: [text], else: [])

  defp allowed?({file, _line, token}) do
    Enum.any?(@allowed, fn {rule, where, _why} ->
      Regex.match?(rule, token) and (is_nil(where) or file in where)
    end)
  end

  defp fenced_counts(found) do
    found
    |> Enum.reject(&allowed?/1)
    |> Enum.frequencies_by(fn {file, _line, token} -> {file, token} end)
  end

  test "the scan sees what it is meant to: a path in code, not in a moduledoc" do
    found = tokens()

    # `Context`'s moduledoc cites documents; none of that is a literal here.
    refute Enum.any?(found, fn {file, _, token} ->
             file == "noetic/harness/context.ex" and String.starts_with?(token, "docs/decisions/")
           end)

    # And a literal the engine really prints is found, with its line.
    assert Enum.any?(found, fn {file, line, token} ->
             file == "mix/tasks/harness.skills.ex" and token == ".claude/skills" and
               is_integer(line)
           end)
  end

  test "no literal names a path of the project's: those are .agents/registry/project.json's" do
    counts = fenced_counts(tokens())

    fenced =
      Map.new(@fenced, fn {file, token, n} -> {{file, token}, n} end)
      |> Map.merge(Map.new(@pending, fn {file, token, n, _why} -> {{file, token}, n} end))

    unexplained =
      for {{file, token}, n} <- Enum.sort(counts), not Map.has_key?(fenced, {file, token}) do
        "#{file}: #{inspect(token)} (#{n}x)"
      end

    assert unexplained == [],
           "a path literal the engine should read from .agents/registry/project.json, " <>
             "or a new reason for it to be code (this test's moduledoc):\n  " <>
             Enum.join(unexplained, "\n  ")
  end

  test "the fenced list is exact: an entry that moved is removed from it" do
    counts = fenced_counts(tokens())

    stale =
      for {file, token, n} <-
            @fenced ++ Enum.map(@pending, fn {file, token, n, _why} -> {file, token, n} end),
          Map.get(counts, {file, token}, 0) != n do
        "#{file}: #{inspect(token)} is listed #{n}x and found #{Map.get(counts, {file, token}, 0)}x"
      end

    assert stale == [], Enum.join(stale, "\n")
  end

  @tag this_repository: true
  test "every file the fenced list names is behind the fence" do
    {:ok, entries} = Noetic.Harness.Fence.entries()
    globs = Enum.map(entries, & &1["glob"])

    for {file, _token, _n} <- @fenced do
      path = "apps/noetic_harness/lib/" <> file
      assert path in globs, "#{path} is not fenced, so its literals are this epic's to move"
    end
  end

  test "a new path literal fails this test" do
    # The rule, applied to a literal that is not in the code: it would be
    # reported, whatever file it was in.
    for token <- ["docs/decisions/DR-001-x.md", "_refdoc", "scripts/ci-local.sh", "apps/acme/lib"] do
      [[found]] = Regex.scan(@token, "read #{token} now")
      refute allowed?({"noetic/harness/context.ex", 1, found}), token
    end

    # and the engine's own conventions are not.
    for token <- ["CLAUDE.md", ".claude/agents"] do
      [[found]] = Regex.scan(@token, "`#{token}`")
      assert allowed?({"noetic/harness/context.ex", 1, found}), token
    end
  end
end
