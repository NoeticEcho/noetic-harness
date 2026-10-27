defmodule Noetic.Harness.RedactTest do
  @moduledoc """
  What every committed record is scrubbed of. Secrets are
  passed as an explicit environment, so nothing here reads or prints the
  machine's own.
  """

  use ExUnit.Case, async: true

  alias Noetic.Harness.Redact

  describe "which names hold a secret" do
    test "the last segment decides, so AUTHOR and a socket path are not secrets" do
      for name <- ~w(CLAUDE_CODE_MESSAGING_TOKEN AWEB_API_KEY DOLT_REMOTE_PASSWORD GH_PAT
                     OPENAI_APIKEY GITHUB_ACCESSTOKEN CLIENT_SECRET),
          do: assert(Redact.secret?(name, "0123456789abcdef"), name)

      for name <- ~w(GIT_AUTHOR_NAME SSH_AUTH_SOCK XAUTHORITY CLAUDE_CODE_OAUTH_SCOPES
                     KEYBOARD_LAYOUT DOLT_REMOTE_USER),
          do: refute(Redact.secret?(name, "0123456789abcdef"), name)
    end

    test "a password is redacted from six bytes, a key or token from eight" do
      assert Redact.secret?("DB_PASSWORD", "hunter2")
      refute Redact.secret?("DB_PASSWORD", "dev12")
      refute Redact.secret?("SERVICE_KEY", "hunter2")
      assert Redact.secret?("SERVICE_KEY", "hunter22")
    end
  end

  describe "secrets" do
    test "longest value first, so a shorter secret inside a longer one cannot shadow it" do
      env = %{"A_TOKEN" => "abcdefgh", "B_TOKEN" => "xxabcdefghyy"}
      assert Redact.secrets("see xxabcdefghyy", env) == "see [redacted $B_TOKEN]"
      assert Redact.secrets("see abcdefgh", env) == "see [redacted $A_TOKEN]"
    end

    test "the name is written, on purpose, and the value is not" do
      out = Redact.secrets("key=s3cr3t-v4lu3", %{"AWEB_API_KEY" => "s3cr3t-v4lu3"})
      assert out == "key=[redacted $AWEB_API_KEY]"
    end
  end

  describe "paths" do
    test "the root and home become . and ~, the longer first" do
      root = Noetic.Harness.root()
      assert Redact.paths(Path.join(root, "apps/x.ex")) == "./apps/x.ex"
      home = System.get_env("HOME")
      if home not in [nil, ""], do: assert(Redact.paths(Path.join(home, ".ssh")) == "~/.ssh")
    end

    test "scrub walks lists and maps and leaves other terms alone" do
      root = Noetic.Harness.root()
      assert Redact.scrub([root, %{"a" => root}, 3, nil]) == [".", %{"a" => "."}, 3, nil]
    end
  end

  test "a credential url is recognised so a caller can withhold it" do
    assert Redact.credential_url?("clone https://bob:pa55word@git.example.com/x")
    refute Redact.credential_url?("clone https://git.example.com/x")
  end
end
