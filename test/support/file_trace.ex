defmodule Noetic.Harness.FileTrace do
  @moduledoc """
  Every path the code under test asks the file system about, taken from the
  BEAM's own call tracing rather than from what the code prints.

  ## Why tracing `:file`, and not a wrapper

  Every file access in Elixir ends in the `:file` module, in the process that
  asks: `File.read/1` is `:file.read_file/1`, `File.exists?/1` and
  `File.stat/2` are `:file.read_file_info/2`, `File.ls/1` is
  `:file.list_dir/1`, `File.write/2` is `:file.write_file/3`, and
  `Path.wildcard/1` walks with `:filelib`, which calls `:file.list_dir/1` and
  `:file.read_file_info/1`. So a call trace on `:file` sees each of them.
  A wrapper module would see only the calls someone remembered to route
  through it, and the engine has none. A grep of the output would see only
  what the engine chose to print.

  The trace is set on the calling process with `:set_on_spawn`, so a `Task`
  the engine starts is traced too. Other processes are not, which keeps
  concurrent tests out of the list.

  ## What it does not see

  - A file a subprocess opens: `git`, `bd`, a gate's shell command. They
    run outside the BEAM. The paths the engine gives them are in their
    arguments and working directory, which the caller can check separately.
  - Code loading, which goes through `:erl_prim_loader`, not `:file`: the
    engine's own beams are not "opened" here.

  `:erlang.trace_pattern/3` is global, so a test using this must not run
  beside another that does. The caller is `async: false`.
  """

  # A path argument: a binary, or a printable charlist. Anything else — an io
  # device, a mode list, a record — is not a path.
  defp path?(arg) when is_binary(arg), do: String.valid?(arg) and arg != ""
  defp path?(arg) when is_list(arg), do: arg != [] and :io_lib.printable_unicode_list(arg)
  defp path?(_), do: false

  # Where a path is in a `:file` call: the first argument, and the second too
  # for the calls that take two. `write_file/2`'s second is the data, which
  # is not a path however much it looks like one.
  @two_paths [:rename, :copy, :make_link, :make_symlink]

  defp path_args(function, [first, second | _]) when function in @two_paths, do: [first, second]
  defp path_args(_function, [first | _]), do: [first]
  defp path_args(_function, []), do: []

  @doc """
  Run `fun` and return `{result, paths}`: its result, and every path passed
  to a `:file` function while it ran, expanded against the working directory
  the way the file server would resolve it, sorted and unique. A relative
  path the engine opened is therefore a path under the working directory,
  and shows as one.
  """
  @spec paths((-> result)) :: {result, [String.t()]} when result: term()
  def paths(fun) do
    me = self()
    tracer = spawn(fn -> collect([]) end)
    cwd = File.cwd!()

    :erlang.trace_pattern({:file, :_, :_}, true, [:global])
    :erlang.trace(me, true, [:call, :set_on_spawn, {:tracer, tracer}])

    result =
      try do
        fun.()
      after
        :erlang.trace(me, false, [:call, :set_on_spawn])
        :erlang.trace_pattern({:file, :_, :_}, false, [:global])
        ref = :erlang.trace_delivered(:all)

        receive do
          {:trace_delivered, :all, ^ref} -> :ok
        after
          5_000 -> :ok
        end
      end

    send(tracer, {:done, me})

    paths =
      receive do
        {:paths, found} -> found
      after
        5_000 -> raise "the file tracer did not answer"
      end

    {result,
     paths
     |> Enum.map(&to_string/1)
     |> Enum.map(&Path.expand(&1, cwd))
     |> Enum.uniq()
     |> Enum.sort()}
  end

  defp collect(acc) do
    receive do
      {:trace, _pid, :call, {:file, function, args}} ->
        collect(Enum.filter(path_args(function, args), &path?/1) ++ acc)

      {:done, from} ->
        send(from, {:paths, acc})

      _other ->
        collect(acc)
    end
  end
end
