defmodule Noetic.Harness.Owner do
  @moduledoc """
  Which VM wrote a piece of test litter, and whether that VM is gone.

  The brooms, `Run.prune_ephemeral/0` and `Artifact.prune_test/0`, run from
  `ExUnit.after_suite/1` against the real repository. Several test VMs can be
  writing there at once: agents verifying in parallel in one worktree, or a
  person running one file while a lane runs.

  Before an earlier change, a suite that finished deleted every open ephemeral run it
  found, including the runs of a suite still running beside it. That suite
  then failed mid-test with `no run run-...`. It was seen on 2026-09-23, in
  `dispatcher_test` at :213, :409, :460 and :593, while three agents
  verified an earlier change in one checkout. CI runs one suite at a time and never
  saw it.

  So litter records its writer under `"owner_vm"`: the operating-system pid,
  and on Linux the pid namespace that pid belongs to. A broom takes litter
  only in three cases:
  - the litter is its own;
  - the VM that wrote it no longer exists;
  - it carries no owner at all, because it was written before this change.
    Such litter is swept, as it always was.

  The namespace is there because a pid means nothing outside it. A suite run
  in a container, or under `bwrap --unshare-pid`, can share this checkout and
  record a pid that out here names a different process or none. Litter from
  another namespace is kept, since this VM cannot see whether its writer is
  running.
  """

  @typedoc "What litter records about the VM that wrote it."
  @type t :: %{String.t() => String.t() | nil}

  @doc "This VM, as litter records it."
  @spec current() :: t()
  def current, do: %{"os_pid" => System.pid(), "pid_ns" => pid_namespace()}

  @doc """
  Whether this VM may sweep litter with this owner.

  True when the litter has no owner, when this VM owns it, or when the VM
  that owns it is no longer running.

  A pid that an unrelated process has since reused keeps its litter until
  that process exits. The result is a leftover file, never the deletion of one
  that was still in use. When the answer cannot be had, the litter stays: a
  broom that deletes when it cannot tell is not a broom, which is also the
  rule `Artifact.tracked?/1` follows.
  """
  @spec sweepable?(term()) :: boolean()
  def sweepable?(nil), do: true

  def sweepable?(%{"os_pid" => os_pid} = owner) when is_binary(os_pid) do
    owner == current() or (owner["pid_ns"] == pid_namespace() and not alive?(os_pid))
  end

  def sweepable?(_unknown), do: false

  defp pid_namespace do
    case File.read_link("/proc/self/ns/pid") do
      {:ok, namespace} -> namespace
      {:error, _} -> nil
    end
  end

  defp alive?(os_pid) do
    cond do
      not Regex.match?(~r/\A[0-9]+\z/, os_pid) -> true
      File.dir?("/proc/self") -> File.dir?("/proc/" <> os_pid)
      true -> match?({_, 0}, System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true))
    end
  rescue
    _ -> true
  end
end
