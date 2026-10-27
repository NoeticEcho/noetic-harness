defmodule Noetic.Harness.Glob do
  @moduledoc """
  A path glob matched against a string, not against the disk.

  `**` crosses directory separators, `*` does not, and everything else is
  literal. These are `Noetic.Harness.Fence`'s semantics, repeated here rather
  than shared because the fence's matcher is private to the module that decides
  what a dispatched run may not touch, and a profile check has no business
  changing it. `Noetic.Harness.Profiles` classifies a path by the fence and by
  its own globs in one pass, so the two must never read one glob two ways; the
  test that holds them together is in `profiles_test.exs`.

  `Path.wildcard/1` is not usable for this: it answers what exists on disk,
  and the question is about a path `git ls-files` names or a scope names,
  which may not exist yet.
  """

  @doc "A compiled glob."
  @spec compile(String.t()) :: Regex.t()
  def compile(glob) do
    pattern =
      glob
      |> String.split("**")
      |> Enum.map_join(".*", fn segment ->
        segment
        |> String.split("*")
        |> Enum.map_join("[^/]*", &Regex.escape/1)
      end)

    Regex.compile!("^" <> pattern <> "$")
  end

  @doc "Whether `path` matches `glob`, a string or a compiled glob."
  @spec match?(String.t() | Regex.t(), String.t()) :: boolean()
  def match?(%Regex{} = regex, path), do: Regex.match?(regex, path)
  def match?(glob, path) when is_binary(glob), do: Regex.match?(compile(glob), path)

  @doc "Whether any of `globs` matches `path`."
  @spec any?([String.t() | Regex.t()], String.t()) :: boolean()
  def any?(globs, path), do: Enum.any?(globs, &__MODULE__.match?(&1, path))
end
