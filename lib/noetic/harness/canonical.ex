defmodule Noetic.Harness.Canonical do
  @moduledoc """
  JSON with its object keys sorted at every depth, and a sha256 over it.

  Two things hash content here and both need the same answer for the same
  content: a decision question's fingerprint and a projection's
  content hash. Re-saving a file with its keys reordered must not
  make it a different question, and projecting the same state twice must not
  make it a different state. Hand-rolled because the order has to be a
  property of this module, not of whichever JSON library the runtime has.
  """

  @doc "The canonical encoding."
  @spec encode(term()) :: String.t()
  def encode(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map_join(",", fn {k, v} -> encode(to_string(k)) <> ":" <> encode(v) end)

    "{" <> inner <> "}"
  end

  def encode(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &encode/1) <> "]"
  def encode(nil), do: "null"
  def encode(value), do: value |> :json.encode() |> IO.iodata_to_binary()

  @doc "sha256 of the canonical encoding, lowercase hex."
  @spec hash(term()) :: String.t()
  def hash(term), do: :crypto.hash(:sha256, encode(term)) |> Base.encode16(case: :lower)
end
