defmodule Noetic.Harness.IdentityTest do
  @moduledoc """
  The actor says whether anything stands behind it.
  """

  # async: false: these tests set the HARNESS_AGENT environment variable, which
  # is process-global, and every async test reading an actor would see it.
  use ExUnit.Case, async: false

  alias Noetic.Harness.Identity

  setup do
    root = Path.join(System.tmp_dir!(), "harness-identity-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(root)
    previous_root = Noetic.Harness.root_override()
    Noetic.Harness.put_root(root)
    previous_agent = System.get_env("HARNESS_AGENT")

    on_exit(fn ->
      if previous_root,
        do: Noetic.Harness.put_root(previous_root),
        else: Noetic.Harness.delete_root()

      if previous_agent,
        do: System.put_env("HARNESS_AGENT", previous_agent),
        else: System.delete_env("HARNESS_AGENT")

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp identity!(root, text) do
    File.mkdir_p!(Path.join(root, ".aw"))
    File.write!(Path.join([root, ".aw", "identity.yaml"]), text)
  end

  test "with no identity, the actor is a name and says it is self-asserted" do
    System.put_env("HARNESS_AGENT", "claude-test")

    assert Identity.actor() ==
             %{
               "name" => "claude-test",
               "name_from" => "HARNESS_AGENT",
               "attestation" => "self-asserted"
             }

    refute Identity.attested?(Identity.actor())
  end

  test "a configured DID is recorded, and is still not attestation", %{root: root} do
    identity!(root, """
    did: "did:aw:z6MkExample"
    address: team.example/claude   # the team's
    custody: hosted
    signing_key: should-never-be-read
    """)

    actor = Identity.actor(by: "claude-test")
    assert actor["did"] == "did:aw:z6MkExample"
    assert actor["address"] == "team.example/claude"
    assert actor["custody"] == "hosted"
    assert actor["attestation"] == "self-asserted"
    refute Map.has_key?(actor, "signing_key")
    refute Identity.attested?(actor)
  end

  test "identity.yaml cannot make an actor signed, and the file cannot say two things", %{
    root: root
  } do
    identity!(root, "did: did:aw:z6MkA\nattestation: signed\n")
    assert Identity.actor()["attestation"] == "self-asserted"

    identity!(root, "did: did:aw:z6MkA\ndid: did:aw:z6MkEvil\n")
    assert Identity.identity() == :none

    identity!(root, "did: 'did:aw:z6MkQuoted'\naddress: |\n  somewhere\n")
    assert {:ok, found} = Identity.identity()
    assert found == %{"did" => "did:aw:z6MkQuoted"}
  end

  test "a record that says it is signed is not thereby attested" do
    # Review: a run file edited by hand to say "signed" was believed. There is
    # no verifier yet, so nothing is attested — which is the truth.
    forged = %{
      "name" => "x",
      "attestation" => "signed",
      "did" => "did:aw:z6MkForged",
      "signature" => "AAAA",
      "signed_at" => "2026-09-23T00:00:00Z"
    }

    refute Identity.attested?(forged)
  end

  test "a file without a did:aw DID is no identity", %{root: root} do
    identity!(root, "address: somewhere/someone\n")
    assert Identity.identity() == :none
  end

  test "a name or a DID is not attestation" do
    refute Identity.attested?(%{"name" => "x", "did" => "did:aw:z"})
    refute Identity.attested?(%{"attestation" => "self-asserted", "signature" => "abc"})
    refute Identity.attested?(nil)
  end

  test "an explicit :by wins over the environment" do
    System.put_env("HARNESS_AGENT", "from-env")

    assert %{"name" => "given", "name_from" => "the caller's :by option"} =
             Identity.actor(by: "given")
  end
end
