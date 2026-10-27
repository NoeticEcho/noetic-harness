defmodule Noetic.Harness.TestTmpTest do
  @moduledoc """
  `Noetic.Harness.TestTmp`, and the pattern it replaced.
  """
  use ExUnit.Case, async: true

  alias Noetic.Harness.TestTmp

  test "a name carries this VM's OS pid, so no live VM can share it" do
    assert Path.basename(TestTmp.path("x")) =~ ~r/\Ax-#{System.pid()}-\d+\z/
    assert TestTmp.path("x", ".jsonl") =~ ~r/\.jsonl\z/
    refute TestTmp.path("x") == TestTmp.path("x")
  end

  test "dir!/1 refuses a directory that exists rather than sharing it" do
    dir = TestTmp.dir!("test-tmp")
    on_exit(fn -> File.rm_rf(dir) end)

    assert File.dir?(dir)
    assert_raise File.Error, fn -> File.mkdir!(dir) end
  end

  test "no harness test names a tmp fixture by the counter alone" do
    # The pattern that made two concurrent suites share a directory: the
    # counter restarts in every VM. A path under the system tmp directory
    # built from it must also carry the pid, and TestTmp is how.
    pattern = ~r/tmp_dir!\(\),\s*"[^"]*#\{System\.unique_integer\(\[:positive\]\)\}/

    offenders =
      for path <- Path.wildcard(Path.expand("../..", __DIR__) <> "/**/*.{ex,exs}"),
          path != __ENV__.file,
          source = File.read!(path),
          [match | _] <- Regex.scan(pattern, source),
          not String.contains?(match, "System.pid()"),
          do: Path.relative_to(path, Path.expand("../../..", __DIR__))

    assert offenders == [], "use Noetic.Harness.TestTmp: #{Enum.join(offenders, ", ")}"
  end
end
