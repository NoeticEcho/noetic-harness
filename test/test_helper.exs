# The harness depends on no service, so there is nothing here to start.
#
# Some of its tests depend on the machine, or on the repository the harness
# was developed in, and a test that silently does not run is worse than one
# that is missing. So each such tag is excluded here, and the reason printed.
#
#   :this_repository — a test about the development repository's own
#     `.agents/`, which this repository does not have.
#   :git_history — derives an environment from a commit of the development
#     repository's history, which this repository does not have.
#   :asdf — asserts which toolchain the development repository's scripts pin.
#   :aw — signs with the installed `aw` and the workspace identity above the
#     repository. Needs both.
#   :live — calls a real model and spends money. Never run by default;
#     `mix test --include live` runs it.

aw? =
  System.find_executable("aw") != nil and
    "../.."
    |> Path.expand(__DIR__)
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take_while(&(&1 != "/"))
    |> Enum.any?(&File.dir?(Path.join(&1, ".aw")))

reasons = [
  this_repository:
    "about the development repository's own .agents/, which this repository does not have",
  git_history:
    "derives from commits of the development repository, which this repository does not have",
  asdf: "about the development repository's toolchain scripts",
  live: "it calls a real model and spends money; `mix test --include live` runs it"
]

reasons =
  if aw?,
    do: reasons,
    else: reasons ++ [aw: "no aw on PATH, or no .aw workspace identity above the repository"]

for {tag, why} <- reasons, do: IO.puts("excluding :#{tag} — #{why}")

# The instant the suite began, for the one test that reads live machine
# state: the hook latency log, as it stood before the suite could touch it.
Application.put_env(:noetic_harness, :suite_started_at, DateTime.utc_now())

ExUnit.start(exclude: Keyword.keys(reasons))

# A test that writes a run and then crashes can leave it in the registry it
# pointed at. The broom removes only open ephemeral runs, and artifacts whose
# `created_by` is "test", and says what it removed.
ExUnit.after_suite(fn _results ->
  case Noetic.Harness.Run.prune_ephemeral() ++ Noetic.Harness.Artifact.prune_test() do
    [] ->
      :ok

    ids ->
      IO.puts(
        "\nthe suite left #{length(ids)} file(s) in the registry; removed: " <>
          Enum.join(ids, ", ")
      )
  end
end)
