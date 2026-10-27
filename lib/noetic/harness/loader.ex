defmodule Noetic.Harness.Loader do
  @moduledoc """
  Loading JSON definitions, with the file name in every error.

  Elixir's built-in `JSON` reports a decode error without saying which file it
  came from. When the harness reads fifty definition files, that is the
  difference between a one-line fix and a bisection, so every read here returns
  `{:error, reason}` with the path in it.

  It is named `Loader` rather than `JSON` on purpose: a module called
  `Noetic.Harness.JSON` shadows nothing, but every reader has to stop and work
  out whether `JSON.decode/1` inside it means this module or the built-in one.

  `load!/1` raises, and is for the mix tasks and the tests, where a missing
  definition file is a programming error rather than a condition.

  ## Reads are raw

  `File.read/2` with `[:raw]`, so a read is made by the calling process rather
  than sent to OTP's one file server, `file_server_2`. Idle the two
  are the same; under load a file-server call waits ~25-60 ms behind everyone
  else's. Almost every definition the harness reads comes through
  here, so this is most of its I/O: a resident server's `user_prompt` answer
  went from 145 file-server calls to 3, every validator check together from
  4,673 to 2,944, and composing every role from 815 to 543. `Path.wildcard/1`
  in `load_dir/1` still goes through the server; `:file` has no raw listing.
  """

  @type result :: {:ok, term()} | {:error, String.t()}

  @doc "Read and decode one file. Returns `{:error, message}` naming the path."
  @spec load(Path.t()) :: result()
  def load(path) do
    with {:ok, raw} <- read(path) do
      case JSON.decode(raw) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, reason} -> {:error, "#{relative(path)}: invalid JSON (#{inspect(reason)})"}
      end
    end
  end

  @doc """
  Like `load/1`, but memoised for the lifetime of the calling process.

  Composing 270 prompts re-reads the same five definition files 270 times, which
  turned a validation run into minutes of stat calls. The cache is keyed by
  absolute path and lives in the process dictionary, which is deliberately the
  narrowest scope that fixes it: definition files do not change during a mix
  task or a test, a fixture tree gets a fresh path and therefore a fresh entry,
  and files the harness *writes* during a run — memory records, evolution
  candidates, generated adapters — go through `load/1` and are never cached.
  """
  @spec cached_load(Path.t()) :: result()
  def cached_load(path) do
    key = {__MODULE__, :cache, path}

    case Process.get(key) do
      nil ->
        result = load(path)
        Process.put(key, result)
        result

      cached ->
        cached
    end
  end

  @doc "Read and decode, raising with the path on failure."
  @spec load!(Path.t()) :: term()
  def load!(path) do
    case load(path) do
      {:ok, decoded} -> decoded
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Every `*.json` in a directory, decoded, sorted by file name.

  Returns `{:ok, [{path, decoded}]}` or the first error. A definition directory
  with one broken file is broken; reporting the others as if nothing happened
  would be the silent fallback the constitution forbids.
  """
  @spec load_dir(Path.t()) :: {:ok, [{Path.t(), term()}]} | {:error, String.t()}
  def load_dir(dir) do
    dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case load(path) do
        {:ok, decoded} -> {:cont, {:ok, [{path, decoded} | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc "Encode with a trailing newline, so a generated file is a well-formed text file."
  @spec encode!(term()) :: String.t()
  def encode!(term), do: JSON.encode!(term) <> "\n"

  @doc """
  Encode indented.

  `JSON.encode!/1` produces one line, which is unreadable in a diff — and these
  files are read in diffs more often than by machines.
  """
  @spec pretty!(term()) :: String.t()
  def pretty!(term), do: pretty(term, 0) <> "\n"

  defp pretty(term, indent) when is_map(term) and map_size(term) > 0 do
    pad = String.duplicate("  ", indent + 1)

    body =
      term
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map_join(",\n", fn {k, v} ->
        pad <> JSON.encode!(to_string(k)) <> ": " <> pretty(v, indent + 1)
      end)

    "{\n" <> body <> "\n" <> String.duplicate("  ", indent) <> "}"
  end

  defp pretty(term, indent) when is_list(term) and term != [] do
    pad = String.duplicate("  ", indent + 1)
    body = Enum.map_join(term, ",\n", fn v -> pad <> pretty(v, indent + 1) end)
    "[\n" <> body <> "\n" <> String.duplicate("  ", indent) <> "]"
  end

  defp pretty(term, _indent), do: JSON.encode!(term)

  defp read(path) do
    case File.read(path, [:raw]) do
      {:ok, raw} -> {:ok, raw}
      {:error, :enoent} -> {:error, "#{relative(path)}: not found"}
      {:error, reason} -> {:error, "#{relative(path)}: #{:file.format_error(reason)}"}
    end
  end

  defp relative(path) do
    root = Noetic.Harness.root()
    if String.starts_with?(path, root), do: Path.relative_to(path, root), else: path
  end
end
