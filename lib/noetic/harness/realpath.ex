defmodule Noetic.Harness.Realpath do
  @moduledoc """
  A path with every symlink in it resolved, as `realpath(3)` gives it.

  Git records a worktree by its physical path, and `Path.expand/1` resolves
  `.`, `..` and `~` lexically and never reads a link. So wherever the
  harness compares a path it was given with one git wrote, the two spell the
  same directory differently as soon as anything above it is a symlink. On
  macOS that is every temporary directory — `/var` is a link to
  `/private/var` — and it made every run's worktree unreadable to the host
  (forty failures on the first macOS CI). On Linux it is any
  repository reached through a linked directory.

  Elixir has no `realpath`, and shelling out to `pwd -P` (what
  `Noetic.Harness.Tree` does for a directory it has just made) needs the
  directory to exist and to be enterable. This walks the components with
  `File.lstat/1` and `File.read_link/1` instead, and resolves `..` *after*
  the link before it, which is the difference from `Path.expand/1`: `a/l/..`
  is the parent of wherever `l` points, not `a`.

  Links are followed at most 40 times in one resolution, Linux's
  `MAXSYMLINKS`, so a cycle is an error rather than a loop. A component that
  does not exist is an error too: there is no physical spelling of a path
  that is not there, and a caller comparing paths must not be handed a guess.
  """

  @max_links 40

  @doc """
  The physical, absolute spelling of `path`, relative paths taken against
  the current directory.
  """
  @spec resolve(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(path) do
    walk("/", Path.split(Path.absname(path)) |> tl(), 0, path)
  end

  defp walk(done, [], _links, _path), do: {:ok, done}
  defp walk(done, ["." | rest], links, path), do: walk(done, rest, links, path)
  defp walk(done, [".." | rest], links, path), do: walk(Path.dirname(done), rest, links, path)

  defp walk(done, [name | rest], links, path) do
    next = Path.join(done, name)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} when links >= @max_links ->
        {:error, "more than #{@max_links} symbolic links in #{path}"}

      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(next) do
          {:ok, target} ->
            {from, parts} =
              case Path.split(target) do
                ["/" | parts] -> {"/", parts}
                parts -> {done, parts}
              end

            walk(from, parts ++ rest, links + 1, path)

          {:error, reason} ->
            {:error, "could not read the link #{next}: #{:file.format_error(reason)}"}
        end

      {:ok, %File.Stat{type: :directory}} ->
        walk(next, rest, links, path)

      {:ok, _} when rest == [] ->
        {:ok, next}

      {:ok, _} ->
        {:error, "#{next} is not a directory, in #{path}"}

      {:error, reason} ->
        {:error, "could not resolve #{path}: #{next}: #{:file.format_error(reason)}"}
    end
  end
end
