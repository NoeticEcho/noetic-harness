defmodule Noetic.Harness.Identity.Signature do
  @moduledoc """
  Signing a ledger record through `aw`, and checking the signature without it.

  ## What is signed

  Not the record. `aw id sign` signs the canonical JSON of the payload it is
  given plus a `timestamp` it adds (`awid.SignArbitraryPayload`), and the
  canonical form is Go's `encoding/json` — keys sorted, no HTML escaping, and
  Go's own rules for `\\b`, `U+2028` and invalid UTF-8. Reproducing those for
  arbitrary evidence text would be a second implementation of somebody else's
  canonicaliser, which is how two sides come to disagree about one byte. So the
  payload is **six ASCII fields** — `harness`, `kind`, `run`, `seq`, `prev` and
  `sha256` — whose canonical form is the same in any language:

  - `sha256` is the digest of the record *including its actor*, less the
    fields signing adds to it (`@signature_fields`). The first version dropped
    the whole actor, and review changed a signed actor's name and custody
    without breaking the signature.
  - `seq` is the record's position in its run and `prev` the digest of the one
    before it (`"none"` for the first). The first version bound only the run
    and kind, and review reordered, duplicated and deleted signed steps with
    every one still verifying. Deleting the *last* record is still invisible —
    a chain proves what is in it, not that nothing followed.

  ## What is checked, and against what

  A signature proves its signer held the key named by its `did:key`. Anyone can
  make a key, so `trusted?/1` — the key listed in `.agents/policies/identity.json`,
  a fenced policy — is half of attestation and the signature is the other half.
  The check is `:crypto.verify/5` on Ed25519: offline, no `aw`, no registry.
  Whether that `did:key` is still the current key of its `did:aw` is a registry
  question (`aw id verify`), and is not asked: a gate that must not be
  skippable cannot depend on the network.

  The harness never signs by itself. It has no key and reads none; `aw` does
  both.
  """

  @multicodec_ed25519 <<0xED, 0x01>>
  @signature_fields ~w(attestation did_key signature signed_at custody unsigned_because)
  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  @doc """
  The payload `aw` signs for a record. `:error` when the run id is not the
  plain slug every `Run` id is — the reason the payload can stay ASCII.
  """
  @spec payload(String.t(), String.t(), map(), %{seq: non_neg_integer(), prev: String.t() | nil}) ::
          {:ok, map()} | :error
  def payload(kind, run_id, record, %{seq: seq, prev: prev}) do
    if kind =~ ~r/\A[a-z_]{1,32}\z/ and is_binary(run_id) and
         run_id =~ ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,199}\z/ and is_integer(seq) and seq >= 0 and
         (is_nil(prev) or prev =~ ~r/\A[0-9a-f]{64}\z/) do
      {:ok,
       %{
         "harness" => "acme",
         "kind" => kind,
         "run" => run_id,
         "seq" => Integer.to_string(seq),
         "prev" => prev || "none",
         "sha256" => digest(record)
       }}
    else
      :error
    end
  rescue
    _ -> :error
  end

  @doc """
  The digest of a record, less what signing adds to its actor, as it reads
  back from disk.

  Round-tripped through JSON first, so a record digested when it is written
  and one digested when it is read are the same term; then encoded with every
  map's keys sorted, which `JSON.encode!/1` does not promise past 32 keys.
  """
  @spec digest(map()) :: String.t()
  def digest(record) do
    record
    |> unsigned()
    |> JSON.encode!()
    |> JSON.decode!()
    |> encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "A record as it was before signing: the actor without the fields `sign` adds."
  @spec unsigned(map()) :: map()
  def unsigned(%{"actor" => actor} = record) when is_map(actor),
    do: %{record | "actor" => Map.drop(actor, @signature_fields)}

  def unsigned(record), do: record

  @doc """
  Whether a JSON document gives some object the same key twice.

  Review: Elixir's `JSON.decode/1` keeps the first of two `"outcome"` keys and
  `jq`, Python and Node keep the last, so one file could be a signed `failed`
  to the harness and a `done` to everything else. A run file with a repeated
  key has no attested records at all.
  """
  @spec duplicate_keys?(binary()) :: boolean()
  def duplicate_keys?(json) when is_binary(json) do
    finish = fn pairs, acc ->
      keys = Enum.map(pairs, &elem(&1, 0))
      if length(keys) != length(Enum.uniq(keys)), do: throw(:duplicate_key)
      {Map.new(pairs), acc}
    end

    try do
      :json.decode(json, :ok, %{object_finish: finish})
      false
    catch
      :duplicate_key -> true
    end
  rescue
    _ -> true
  end

  defp encode(map) when is_map(map) do
    pairs =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [JSON.encode!(key), ":", encode(value)] end)

    ["{", Enum.intersperse(pairs, ","), "}"]
  end

  defp encode(list) when is_list(list),
    do: ["[", list |> Enum.map(&encode/1) |> Enum.intersperse(","), "]"]

  defp encode(value), do: JSON.encode!(value)

  @doc """
  The canonical JSON `aw` signed: the payload and its timestamp, keys sorted,
  compact. Only for the ASCII payload `payload/3` builds, and it refuses
  anything else rather than guess at Go's escaping.
  """
  @spec canonical(map(), String.t()) :: {:ok, String.t()} | :error
  def canonical(payload, timestamp) do
    fields = Map.put(payload, "timestamp", timestamp)

    if Enum.all?(fields, fn {k, v} -> plain?(k) and plain?(v) end) do
      body =
        fields
        |> Enum.sort()
        |> Enum.map_join(",", fn {k, v} -> ~s("#{k}":"#{v}") end)

      {:ok, "{" <> body <> "}"}
    else
      :error
    end
  end

  defp plain?(value), do: is_binary(value) and value =~ ~r/\A[\x20-\x21\x23-\x5b\x5d-\x7e]*\z/

  @doc """
  Whether `signature` is `did_key`'s Ed25519 signature over the payload and
  timestamp. Checks the signature only — whose key it is, is `trusted?/1`.
  """
  @spec valid?(map(), String.t(), String.t(), String.t()) :: boolean()
  def valid?(payload, timestamp, signature, did_key) do
    with true <- is_binary(signature) and is_binary(timestamp),
         {:ok, canonical} <- canonical(payload, timestamp),
         {:ok, public} <- public_key(did_key),
         {:ok, sig} <- Base.decode64(signature, padding: false),
         64 <- byte_size(sig) do
      :crypto.verify(:eddsa, :none, canonical, sig, [public, :ed25519])
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "The Ed25519 public key a `did:key` names, or `:error`."
  @spec public_key(term()) :: {:ok, binary()} | :error
  def public_key("did:key:z" <> encoded) do
    case decode58(encoded) do
      {:ok, <<@multicodec_ed25519, key::binary-size(32)>>} -> {:ok, key}
      _ -> :error
    end
  end

  def public_key(_), do: :error

  @doc "Whether `did_key` is listed in `.agents/policies/identity.json`."
  @spec trusted?(term()) :: boolean()
  def trusted?(did_key), do: trusted_entry(did_key) != nil

  @doc "The policy's entry for `did_key` — its custody, address and why — or `nil`."
  @spec trusted_entry(term()) :: map() | nil
  def trusted_entry(did_key) when is_binary(did_key) do
    path = Path.join(Noetic.Harness.agents_path("policies"), "identity.json")

    case Noetic.Harness.Loader.cached_load(path) do
      {:ok, %{"trusted" => list}} when is_list(list) ->
        Enum.find(list, &match?(%{"did_key" => ^did_key}, &1))

      _ ->
        nil
    end
  end

  def trusted_entry(_), do: nil

  @doc """
  Sign `payload` with `aw id sign`, run in `dir` so that `aw` finds the
  workspace identity there. `{:ok, %{"did_key", "signature", "timestamp"}}`
  or `{:error, why}`.

  Bounded by `timeout(1)`: `aw` is a network-capable binary and a ledger write
  must not wait on it. `AW_NO_UPDATE_CHECK` because a signature is not the
  moment for `aw` to go and look for a new version of itself.
  """
  @spec sign(map(), Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def sign(payload, dir, opts \\ []) do
    aw = Keyword.get(opts, :aw) || System.find_executable("aw")
    timeout = System.find_executable("timeout")

    cond do
      is_nil(aw) ->
        {:error, "aw is not installed"}

      is_nil(timeout) ->
        {:error, "timeout(1) is not installed, and aw is not run unbounded"}

      true ->
        # `-k 2`: a SIGTERM `aw` ignores becomes a SIGKILL two seconds later.
        args = ["-k", "2", "10", aw, "id", "sign", "--json", "--payload", JSON.encode!(payload)]

        case System.cmd(timeout, args, cd: dir, env: [{"AW_NO_UPDATE_CHECK", "1"}]) do
          {output, 0} ->
            parse(output)

          {_, 124} ->
            {:error, "aw id sign did not answer in 10 s"}

          {output, status} ->
            {:error, "aw id sign exited #{status}: #{String.slice(output, 0, 200)}"}
        end
    end
  rescue
    error -> {:error, "aw id sign could not be run: #{Exception.message(error)}"}
  end

  # The whole output first — `--json` may be indented across lines — then each
  # line from the last, in case something printed before it.
  defp parse(output) do
    [String.trim(output) | output |> String.split("\n", trim: true) |> Enum.reverse()]
    |> Enum.find_value({:error, "aw id sign printed no signature"}, fn line ->
      case JSON.decode(line) do
        {:ok, %{"did_key" => "did:key:" <> _, "signature" => sig, "timestamp" => ts} = found}
        when is_binary(sig) and is_binary(ts) ->
          {:ok, Map.take(found, ["did_key", "signature", "timestamp"])}

        _ ->
          nil
      end
    end)
  end

  @doc false
  def decode58(text) when is_binary(text) and text != "" do
    chars = String.to_charlist(text)

    if Enum.all?(chars, &(&1 in @alphabet)) do
      zeros = chars |> Enum.take_while(&(&1 == ?1)) |> length()

      number =
        Enum.reduce(chars, 0, fn char, acc ->
          acc * 58 + Enum.find_index(@alphabet, &(&1 == char))
        end)

      body = if number == 0, do: <<>>, else: :binary.encode_unsigned(number)
      {:ok, :binary.copy(<<0>>, zeros) <> body}
    else
      :error
    end
  end

  def decode58(_), do: :error

  @doc false
  def encode58(bytes) when is_binary(bytes) do
    zeros = bytes |> :binary.bin_to_list() |> Enum.take_while(&(&1 == 0)) |> length()
    number = :binary.decode_unsigned(bytes)
    String.duplicate("1", zeros) <> digits58(number, [])
  end

  defp digits58(0, acc), do: List.to_string(acc)
  defp digits58(n, acc), do: digits58(div(n, 58), [Enum.at(@alphabet, rem(n, 58)) | acc])

  @doc false
  def did_key(public) when byte_size(public) == 32,
    do: "did:key:z" <> encode58(@multicodec_ed25519 <> public)
end
