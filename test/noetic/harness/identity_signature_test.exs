defmodule Noetic.Harness.IdentitySignatureTest do
  @moduledoc """
  A signed ledger record, and every way it stops being attested.

  The `aw` here is a fake written in Python with OpenSSL doing the Ed25519 —
  deliberately *not* Elixir. Its canonical JSON is `json.dumps(sort_keys=True,
  separators=(",", ":"))`, the form the awid verifier uses, so a signature it
  makes and `Signature.valid?/4` accepts is two independent canonicalisers
  agreeing. The real `aw` is checked the same way by the `:aw` test once an
  identity exists.
  """

  # async: false: `:sign_records` and `:aw` are application-global.
  use ExUnit.Case, async: false

  alias Noetic.Harness.Identity
  alias Noetic.Harness.Identity.Signature

  # Where a test record goes: first in its run.
  @at %{seq: 0, prev: nil}

  @fake_aw """
  #!/usr/bin/env python3
  import base64, datetime, json, subprocess, sys, tempfile
  KEY = "__KEY__"
  ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  def b58(data):
      n = int.from_bytes(data, "big"); out = ""
      while n: n, r = divmod(n, 58); out = ALPHABET[r] + out
      return "1" * (len(data) - len(data.lstrip(b"\\0"))) + out
  args = sys.argv[1:]
  if args[:2] != ["id", "sign"]: sys.exit(2)
  if "__FAIL__" == "yes": print("current identity has no local signing key", file=sys.stderr); sys.exit(1)
  payload = json.loads(args[args.index("--payload") + 1])
  ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
  payload["timestamp"] = ts
  canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
  # OpenSSL's one-shot Ed25519 cannot read stdin: it needs the length first.
  with tempfile.NamedTemporaryFile() as f:
      f.write(canonical); f.flush()
      sig = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", KEY, "-rawin", "-in", f.name], capture_output=True, check=True).stdout
  pub = subprocess.run(["openssl", "pkey", "-in", KEY, "-pubout", "-outform", "DER"], capture_output=True, check=True).stdout[-32:]
  print(json.dumps({"did_key": "did:key:z" + b58(b"\\xed\\x01" + pub), "signature": base64.b64encode(sig).decode().rstrip("="), "timestamp": ts}, indent=2))
  """

  setup do
    root = Path.join(System.tmp_dir!(), "harness-signature-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(Path.join(root, ".aw"))
    File.mkdir_p!(Path.join([root, ".agents", "policies"]))

    key = Path.join(root, "fake.pem")
    {_, 0} = System.cmd("openssl", ["genpkey", "-algorithm", "ed25519", "-out", key])

    previous_root = Noetic.Harness.root_override()
    Noetic.Harness.put_root(root)
    previous = for k <- [:sign_records, :aw], do: {k, Application.get_env(:noetic_harness, k)}

    on_exit(fn ->
      if previous_root,
        do: Noetic.Harness.put_root(previous_root),
        else: Noetic.Harness.delete_root()

      for {k, v} <- previous,
          do:
            if(is_nil(v),
              do: Application.delete_env(:noetic_harness, k),
              else: Application.put_env(:noetic_harness, k, v)
            )

      File.rm_rf!(root)
    end)

    aw = fake_aw(root, key, fail: false)
    Application.put_env(:noetic_harness, :sign_records, true)
    Application.put_env(:noetic_harness, :aw, aw)

    {:ok, root: root, key: key, did_key: did_key_of(key)}
  end

  defp fake_aw(root, key, fail: fail) do
    path = Path.join(root, if(fail, do: "aw-failing", else: "aw"))

    File.write!(
      path,
      @fake_aw
      |> String.replace("__KEY__", key)
      |> String.replace("__FAIL__", if(fail, do: "yes", else: "no"))
    )

    File.chmod!(path, 0o755)
    path
  end

  defp did_key_of(key) do
    {der, 0} = System.cmd("openssl", ["pkey", "-in", key, "-pubout", "-outform", "DER"])
    Signature.did_key(binary_part(der, byte_size(der) - 32, 32))
  end

  defp trust!(root, did_keys) do
    trusted = for k <- did_keys, do: %{"did_key" => k, "custody" => "local", "why" => "test"}

    File.write!(
      Path.join([root, ".agents", "policies", "identity.json"]),
      JSON.encode!(%{"version" => 1, "trusted" => trusted})
    )
  end

  defp record do
    %{
      "step" => "patch",
      "outcome" => "done",
      "evidence" => ["mix test — 3 pass", "a line with \"quotes\", <tags> & ünïcode"],
      "actor" => Identity.actor(by: "claude-test"),
      "at" => "2026-09-23T10:00:00Z"
    }
  end

  describe "a record signed by a trusted key" do
    test "is attested, and says what custody its key is in", %{root: root, did_key: did_key} do
      trust!(root, [did_key])
      signed = Identity.sign(record(), "run_step", "run-2026-09-23-x", @at)

      assert signed["actor"]["attestation"] == "signed", inspect(signed["actor"])
      assert signed["actor"]["did_key"] == did_key
      assert signed["actor"]["custody"] == "local"
      assert Identity.attested?(signed, "run_step", "run-2026-09-23-x", @at)

      # And as it reads back from disk.
      assert signed
             |> JSON.encode!()
             |> JSON.decode!()
             |> Identity.attested?("run_step", "run-2026-09-23-x", @at)
    end
  end

  describe "and every way it stops being attested" do
    setup %{root: root, did_key: did_key} do
      trust!(root, [did_key])
      {:ok, signed: Identity.sign(record(), "run_step", "run-2026-09-23-x", @at)}
    end

    test "an edited record", %{signed: signed} do
      edited = Map.update!(signed, "evidence", &["forged" | &1])
      refute Identity.attested?(edited, "run_step", "run-2026-09-23-x", @at)
    end

    test "the same record claimed for another run or kind", %{signed: signed} do
      refute Identity.attested?(signed, "run_step", "run-2026-09-23-y", @at)
      refute Identity.attested?(signed, "run_stop", "run-2026-09-23-x", @at)
    end

    test "a signature moved onto another record", %{signed: signed} do
      other = Map.put(record(), "step", "review") |> Map.put("actor", signed["actor"])
      refute Identity.attested?(other, "run_step", "run-2026-09-23-x", @at)
    end

    test "a key the policy does not list", %{root: root, signed: signed} do
      trust!(root, [])
      refute Identity.attested?(signed, "run_step", "run-2026-09-23-x", @at)
    end

    test "a hand-written signed, and an actor on its own", %{signed: signed} do
      forged = put_in(record(), ["actor"], Map.put(record()["actor"], "attestation", "signed"))
      refute Identity.attested?(forged, "run_step", "run-2026-09-23-x", @at)
      refute Identity.attested?(signed["actor"])
    end

    test "a changed timestamp or signature", %{signed: signed} do
      refute Identity.attested?(
               put_in(signed, ["actor", "signed_at"], "2026-09-23T00:00:00Z"),
               "run_step",
               "run-2026-09-23-x",
               @at
             )

      [c | rest] = String.graphemes(signed["actor"]["signature"])
      flipped = Enum.join([if(c == "A", do: "B", else: "A") | rest])

      refute Identity.attested?(
               put_in(signed, ["actor", "signature"], flipped),
               "run_step",
               "run-2026-09-23-x",
               @at
             )
    end
  end

  describe "what review of the first version broke" do
    setup %{root: root, did_key: did_key} do
      trust!(root, [did_key])
      :ok
    end

    test "an edited actor: its name, or a custody the policy does not record" do
      signed = Identity.sign(record(), "run_step", "run-r", @at)
      assert Identity.attested?(signed, "run_step", "run-r", @at)

      refute Identity.attested?(
               put_in(signed, ["actor", "name"], "somebody-else"),
               "run_step",
               "run-r",
               @at
             )

      refute Identity.attested?(
               put_in(signed, ["actor", "custody"], "self"),
               "run_step",
               "run-r",
               @at
             )
    end

    test "a record moved, duplicated or with its predecessor deleted" do
      first = Identity.sign(Map.put(record(), "outcome", "failed"), "run_step", "run-r", @at)
      second_at = %{seq: 1, prev: Signature.digest(first)}
      second = Identity.sign(record(), "run_step", "run-r", second_at)

      assert Identity.attested?(first, "run_step", "run-r", @at)
      assert Identity.attested?(second, "run_step", "run-r", second_at)

      # Deleted predecessor: the second is now first.
      refute Identity.attested?(second, "run_step", "run-r", @at)
      # Duplicated: the same record again at position 2, after itself.
      refute Identity.attested?(second, "run_step", "run-r", %{
               seq: 2,
               prev: Signature.digest(second)
             })

      # Reordered: the first after the second.
      refute Identity.attested?(first, "run_step", "run-r", %{
               seq: 1,
               prev: Signature.digest(second)
             })
    end

    test "a file that gives a key twice has nothing attested" do
      assert Signature.duplicate_keys?(~s({"steps":[{"outcome":"failed","outcome":"done"}]}))
      refute Signature.duplicate_keys?(~s({"steps":[{"outcome":"failed"},{"outcome":"done"}]}))
      assert Signature.duplicate_keys?("not json")
    end

    test "aw returning a signature that does not verify is not signed", %{root: root} do
      bogus = Path.join(root, "aw-bogus")

      File.write!(bogus, """
      #!/bin/sh
      printf '{"did_key":"did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK","signature":"AA","timestamp":"2026-09-23T00:00:00Z"}'
      """)

      File.chmod!(bogus, 0o755)
      Application.put_env(:noetic_harness, :aw, bogus)
      actor = Identity.sign(record(), "run_step", "run-r", @at)["actor"]
      assert actor["attestation"] == "self-asserted"
      assert actor["unsigned_because"] =~ "does not verify"
    end

    test "signing never raises: a truthy setting, or a record that is not JSON" do
      Application.put_env(:noetic_harness, :sign_records, "yes")
      assert %{"actor" => %{}} = Identity.sign(record(), "run_step", "run-r", @at)

      actor = Identity.sign(Map.put(record(), "pid", self()), "run_step", "run-r", @at)["actor"]
      assert actor["attestation"] == "self-asserted"
      assert actor["unsigned_because"] =~ "cannot be signed"
    end
  end

  describe "when it is not signed, it says why" do
    test "signing off", %{root: root, did_key: did_key} do
      trust!(root, [did_key])
      Application.put_env(:noetic_harness, :sign_records, false)
      actor = Identity.sign(record(), "run_step", "run-x", @at)["actor"]
      assert actor["attestation"] == "self-asserted"
      assert actor["unsigned_because"] == "signing is off"
    end

    test "no workspace identity", %{root: root} do
      File.rm_rf!(Path.join(root, ".aw"))
      actor = Identity.sign(record(), "run_step", "run-x", @at)["actor"]
      assert actor["attestation"] == "self-asserted"
      assert actor["unsigned_because"] =~ "no .aw workspace identity"
    end

    test "aw failing is recorded, and the record is still written", %{root: root, key: key} do
      Application.put_env(:noetic_harness, :aw, fake_aw(root, key, fail: true))
      actor = Identity.sign(record(), "run_step", "run-x", @at)["actor"]
      assert actor["attestation"] == "self-asserted"
      assert actor["unsigned_because"] =~ "exited 1"
    end

    test "a run id that is not a slug is not signed" do
      actor = Identity.sign(record(), "run_step", "run with spaces", @at)["actor"]
      assert actor["unsigned_because"] =~ "not a slug"
    end
  end

  describe "the real aw" do
    # Excluded — and the helper says so — until `aw team join` has put a
    # workspace identity above the repository.
    @describetag :aw

    test "a signature from the installed aw verifies here" do
      repo = Noetic.Harness.Checkout.root()

      dir =
        repo
        |> Stream.iterate(&Path.dirname/1)
        |> Enum.find(&File.dir?(Path.join(&1, ".aw")))

      {:ok, payload} = Signature.payload("run_step", "run-2026-09-23-interop", record(), @at)

      assert {:ok, %{"did_key" => did_key, "signature" => sig, "timestamp" => ts}} =
               Signature.sign(payload, dir)

      assert "did:key:z6Mk" <> _ = did_key
      assert Signature.valid?(payload, ts, sig, did_key)

      refute Signature.valid?(
               Map.put(payload, "sha256", String.duplicate("0", 64)),
               ts,
               sig,
               did_key
             )
    end
  end

  describe "the pieces" do
    test "a did:key round-trips to its Ed25519 key, and is the z6Mk form", %{key: key} do
      {der, 0} = System.cmd("openssl", ["pkey", "-in", key, "-pubout", "-outform", "DER"])
      public = binary_part(der, byte_size(der) - 32, 32)
      did = Signature.did_key(public)

      assert "did:key:z6Mk" <> _ = did
      assert {:ok, ^public} = Signature.public_key(did)
      assert :error = Signature.public_key("did:key:z0OIl")
      assert :error = Signature.public_key("did:aw:z6Mk")
    end

    test "canonical JSON refuses what it cannot write the way Go does" do
      assert {:ok, ~s({"a":"1","b":"2","timestamp":"t"})} =
               Signature.canonical(%{"b" => "2", "a" => "1"}, "t")

      for bad <- [~s(quote"), "back\\slash", "new\nline", "ünï"] do
        assert :error = Signature.canonical(%{"a" => bad}, "t")
      end
    end

    test "the digest ignores what signing adds, and not one other field" do
      a = record()

      signed_actor =
        Map.merge(a["actor"], %{
          "attestation" => "signed",
          "did_key" => "x",
          "signature" => "y",
          "signed_at" => "z",
          "custody" => "local"
        })

      assert Signature.digest(a) == Signature.digest(Map.put(a, "actor", signed_actor))
      refute Signature.digest(a) == Signature.digest(put_in(a, ["actor", "name"], "other"))
      refute Signature.digest(a) == Signature.digest(Map.put(a, "note", nil))
    end
  end
end
