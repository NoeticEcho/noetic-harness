defmodule Noetic.Harness.Projection do
  @moduledoc """
  What a decision model is shown about a piece of work, and a record of what
  it was not shown (the addendum's Gaps 5, 7).

  Built **on** `Noetic.Harness.Context` rather than beside it. Context already
  decides what is relevant to a title and a set of paths, how many items a
  section keeps and how much of each file it quotes; a projection is that
  decision made recordable. Any improvement to context improves the projection,
  and the list of what was left out comes from the thing that left it out.

  A projection records:

    * `projection_version` — which rules produced it. Change the rules, change
      this, and no decision made under the old rules compares with a new one;
    * `included` — each section and the items it kept;
    * `excluded` — what was left out and why: sections that could not be
      resolved, items past a section's limit, and what a projection never
      carries at all (file bodies past their excerpt, the bundle's timestamp).
      Never empty, because something is always left out, and saying so is
      the point — Gap 5's rule is *do not silently truncate*;
    * `truncation` — the method, in words;
    * `hash` — sha256 over the canonical `state`, which is the only thing that
      identifies the state in a committed record (an earlier change: the state itself
      never goes in the ledger).

  **Nothing is remembered between calls (Gap 7).** Temporal context — what
  earlier work learned — is materialised into `state` from project memory, the
  way `Context` already does. A provider is a judgment mechanism, not an
  identity store.
  """

  alias Noetic.Harness.{Canonical, Context}

  @version "harness-context-1"

  @doc "The version of the projection rules in this module."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Project a context bundle (`Context.build/2`) for `work`."
  @spec from_bundle(map(), map(), pos_integer()) :: map()
  def from_bundle(work, bundle, limit) do
    state = %{
      "title" => work[:title],
      "body" => work[:body],
      "paths" => work[:paths] || [],
      "sections" =>
        Enum.map(bundle.sections, fn section ->
          %{
            "key" => section.key,
            "items" => Enum.map(section.items, &%{"path" => &1.path, "excerpt" => &1.excerpt})
          }
        end),
      "memory" => Enum.map(bundle.memory, &%{"id" => &1["id"], "title" => &1["title"]})
    }

    %{
      "projection_version" => @version,
      "source" => "noetic-harness context",
      "included" =>
        Enum.map(bundle.sections, fn s -> %{"key" => s.key, "items" => length(s.items)} end),
      "excluded" => excluded(bundle, limit),
      "truncation" =>
        "each section keeps its first #{limit} items by rank; each item is quoted as its " <>
          "first twelve non-blank lines, at most the excerpt byte cap; memory keeps its " <>
          "#{limit} most relevant records",
      "state" => state,
      "hash" => Canonical.hash(state)
    }
  end

  @doc "Build the context and project it."
  @spec build(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(work, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)

    # Without capabilities a context bundle is repository trivia, so ask the
    # router for them the way `noetic-harness context` does.
    capabilities =
      Keyword.get_lazy(opts, :capabilities, fn ->
        case Noetic.Harness.Router.route(work) do
          {:ok, route} -> route.capabilities
          {:error, _} -> []
        end
      end)

    case Context.build(work, Keyword.merge(opts, limit: limit, capabilities: capabilities)) do
      {:ok, bundle} -> {:ok, from_bundle(work, bundle, limit)}
      {:error, _} = error -> error
    end
  end

  defp excluded(bundle, limit) do
    unresolved =
      for key <- List.wrap(bundle.unresolved),
          do: %{"what" => "section #{key}", "why" => "could not be resolved"}

    truncated =
      for section <- bundle.sections,
          section.truncated,
          do: %{"what" => "items of #{section.key} past #{limit}", "why" => "section limit"}

    unresolved ++
      truncated ++
      [
        %{
          "what" => "file bodies past their excerpt",
          "why" => "the excerpt is the unit a projection quotes"
        },
        %{
          "what" => "generated_at",
          "why" => "a timestamp would make the same state hash differently"
        }
      ]
  end
end
