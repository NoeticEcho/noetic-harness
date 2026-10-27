defmodule Noetic.Harness.Checkout do
  @moduledoc """
  The checkout the engine's tests run in, found from this file rather than
  counted in `../`.

  The engine's tests ask it one question: did the engine open, or print,
  anything of the checkout it came from? In this umbrella the checkout is five
  directories above a test file; in the standalone project `harness cut`
  writes, it is three. A count that is right in one is wrong in the other: in
  the standalone tree five levels up was the temporary directory, and every
  fixture under it read as the checkout's own. So the checkout is the nearest
  directory above `test/` that holds a `mix.lock`: the umbrella's root here,
  the project's root there.
  """

  @doc "The checkout's root: the nearest directory above the tests with a `mix.lock`."
  @spec root() :: Path.t()
  def root do
    "../.."
    |> Path.expand(__DIR__)
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take_while(&(&1 != "/"))
    |> Enum.find(&File.regular?(Path.join(&1, "mix.lock")))
    |> Kernel.||(raise "no mix.lock above #{__DIR__}: this is not a checkout of the engine")
  end
end
