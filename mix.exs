defmodule Noetic.Harness.MixProject do
  use Mix.Project

  @version "0.6.0"
  @source_url "https://github.com/NoeticEcho/noetic-harness"

  def project do
    [
      app: :noetic_harness,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases(),
      name: "noetic-harness",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  # The harness is a library its mix tasks read: nothing is started at boot in
  # development or test. Only a production build names an application
  # callback, `Noetic.Harness.CLI`, because the executable needs something to
  # run, and even that runs a command only when Burrito started the VM.
  #
  # `:inets` and `:ssl` are declared because the HTTP adapter calls them, and
  # a declaration is what puts an OTP application's ebin on the code path.
  def application do
    [extra_applications: [:logger, :eex, :inets, :ssl]] ++ entry(Mix.env())
  end

  defp entry(:prod), do: [mod: {Noetic.Harness.CLI, []}]
  defp entry(_), do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Two dependencies, both absent at run time.
  #
  # - `boundary` checks at compile time that the engine's modules depend on
  #   each other only as `Noetic.Harness` declares. It is MIT, and nothing of
  #   it is in a build.
  # - `burrito` wraps a release into one executable per platform, and is
  #   fetched for `MIX_ENV=prod` only. It is MIT. Building with it needs Zig.
  #
  # Nothing else: JSON is Elixir's built-in `JSON`, and the engine calls no
  # service, so it needs no client library.
  defp deps do
    [
      {:boundary, "~> 0.10", runtime: false},
      {:burrito, "~> 1.6", only: :prod, runtime: false}
    ]
  end

  # One executable for Linux on x86-64 and one for macOS on Apple silicon,
  # built with `MIX_ENV=prod mix release` into `burrito_out/`.
  # `BURRITO_TARGET=linux_x86_64` builds one of them. The executable runs
  # `Noetic.Harness.CLI`, which dispatches to the same mix tasks.
  #
  # `:mix` is in the release, loaded and not started: the tasks print through
  # `Mix.shell/0`, and the CLI starts `:mix` before it runs one.
  defp releases do
    [
      noetic_harness: [
        applications: [mix: :load],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end
end
