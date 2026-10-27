defmodule Noetic.Harness.TestTmp do
  @moduledoc """
  Names for temporary fixtures that no other VM can be using.

  `System.unique_integer/1` is unique within a VM and restarts low in every
  one, so `"x-#{System.unique_integer([:positive])}"` under the system's tmp
  directory named the same directory in two suites running at once — the
  coordinator's ci-local beside another session's lane — and the second
  suite's setup, writes and `rm_rf` landed in the first one's fixture. That
  is an earlier change, found by instrumenting `CloudSetupTest`: in sixteen concurrent
  runs, eight directories served two VMs.

  The VM's OS pid is in every name: no two live VMs share one, and within a
  VM the counter keeps two names apart.
  """

  @doc "A path under the system tmp directory, `<prefix>-<os pid>-<n><suffix>`. Creates nothing."
  @spec path(String.t(), String.t()) :: Path.t()
  def path(prefix, suffix \\ "") do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}#{suffix}"
    )
  end

  @doc """
  `path/1`, made. `File.mkdir!/1` rather than `mkdir_p!`, so a directory that
  exists anyway is an error rather than a fixture shared with whoever made it.
  """
  @spec dir!(String.t()) :: Path.t()
  def dir!(prefix) do
    dir = path(prefix)
    File.mkdir!(dir)
    dir
  end
end
