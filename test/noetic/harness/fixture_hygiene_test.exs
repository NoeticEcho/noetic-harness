defmodule Noetic.Harness.FixtureHygieneTest do
  @moduledoc """
  The engine's test fixtures name no machine, no person and no real key.

  `test/support/` travels with the engine: whoever reads its tests reads it,
  and the test pack is copied into every root a test makes. When an earlier change
  froze the pack from this repository's registry, it took the workspace's
  trusted signing key with it, the aweb address that key was joined under,
  and two paths under the person's home directory. None of them was needed:
  no test signs with the pack's key.

  So every file under `test/support/` is read, and each of these fails it:

  - a path under a home directory;
  - an e-mail address, a name at a dotted domain;
  - an aweb address;
  - a `did:key` that this repository's `.agents/policies/identity.json`
    trusts. The real key is read from there rather than written here, so this
    test does not become the next place it is copied to.

  The pack's `identity.json` keeps one trusted entry, so that a root on the
  pack still has a trust list with something in it, and that entry's key was
  generated for it and its private half thrown away.
  """

  use ExUnit.Case, async: true

  @support Path.expand("../../support", __DIR__)

  @patterns [
    {"a path under a home directory", ~r{/h[o]me/}},
    {"an e-mail address", ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/},
    {"an aweb address", ~r/\baweb\.ai\b/}
  ]

  defp files do
    @support
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  @doc false
  def findings(text, keys \\ []) do
    named =
      for {what, pattern} <- @patterns,
          [hit | _] <- Regex.scan(pattern, text),
          do: {what, hit}

    trusted = for key <- keys, String.contains?(text, key), do: {"a trusted did:key", key}
    Enum.uniq(named ++ trusted)
  end

  defp report(found) do
    Enum.map_join(found, "\n", fn {path, what, hit} ->
      "  #{Path.relative_to(path, @support)}: #{what}, #{inspect(hit)}"
    end)
  end

  test "the scan finds each thing it looks for" do
    text = """
    root: /ho#{"me"}/someone/work/.aw
    mail: someone@example.org
    joined: somewhere.aweb.ai/someone
    key: did:key:z6MkReal
    """

    kinds = text |> findings(["did:key:z6MkReal"]) |> Enum.map(&elem(&1, 0))

    assert kinds == [
             "a path under a home directory",
             "an e-mail address",
             "an aweb address",
             "a trusted did:key"
           ]

    # A name at an undotted host is test data, not an address.
    assert findings(~s(email: "t@t")) == []
  end

  test "no file under test/support names a home directory, an address or a mail" do
    found =
      for path <- files(),
          {what, hit} <- findings(File.read!(path)),
          do: {path, what, hit}

    assert found == [], "test/support names what it should not:\n" <> report(found)
  end

  @tag this_repository: true
  test "no file under test/support names a key this repository trusts" do
    keys =
      case File.read(Path.join([Noetic.Harness.root(), ".agents", "policies", "identity.json"])) do
        {:ok, json} -> for entry <- JSON.decode!(json)["trusted"], do: entry["did_key"]
        {:error, :enoent} -> []
      end

    found =
      for path <- files(),
          {what, hit} <- findings(File.read!(path), keys),
          what == "a trusted did:key",
          do: {path, what, hit}

    assert found == [], "test/support names a key the repository trusts:\n" <> report(found)
  end

  test "the pack's trusted key is well formed and names nothing else" do
    path = Path.join([@support, "pack", ".agents", "policies", "identity.json"])
    %{"trusted" => [entry]} = path |> File.read!() |> JSON.decode!()

    assert Map.keys(entry) |> Enum.sort() == ~w(added custody did_key why)

    assert {:ok, <<_::binary-size(32)>>} =
             Noetic.Harness.Identity.Signature.public_key(entry["did_key"])
  end
end
