defmodule Noetic.Harness.Redact do
  @moduledoc """
  What every committed record is scrubbed of before it is written: this
  machine's paths, and the secrets this process is holding.

  **One module, three writers.** `Artifact.new/1` redacted paths, the
  environments evaluator redacted secret values, and `Run` — whose evidence is
  an agent quoting the command it just ran, the text most likely to carry both
  — redacted nothing. A home-directory path reached a committed run file and
  was scrubbed with `sed` after the fact. A redaction that only one of three
  writers performs is a redaction that will be missed, so all three call this.

  ## Paths

  The repository root becomes `.`, `$HOME` becomes `~`. Longest first, so a
  root inside `$HOME` is not half-replaced by the shorter one.

  ## Secrets, by value

  Every environment variable whose *name* says it holds a credential, and whose
  value is long enough to be one, is replaced wherever its value appears. That
  covers the population that can actually leak from here — the secrets this
  process holds — rather than a guess at what a secret looks like.

  **The name rule reads the last segment.** The first version matched
  `TOKEN|SECRET|PASSWORD|PASSWD|KEY|CREDENTIAL|AUTH` anywhere in the name.
  Measured on the machine this was written on (2026-09-23): of eight variables
  it matched, one held a secret. The others were `GIT_AUTHOR_NAME` — the `AUTH`
  in `AUTHOR`, which would have redacted the author's name out of every `git
  log` — `SSH_AUTH_SOCK` and `XAUTHORITY` (paths), `CLAUDE_CODE_OAUTH_SCOPES`,
  and three flags. A name is a secret's when its last `_`-segment is one of
  `@secret_segments`, or ends in `KEY`, `TOKEN` or `SECRET` (`APIKEY`,
  `ACCESSTOKEN`). A secret held under a name this misses is caught, if at all,
  by `withhold_credentials/1`; the rule is a heuristic and says so.

  **Two floors, not one.** A value shorter than its floor is not redacted,
  because a variable called `USER_KEY` holding `"dev"` would otherwise delete
  every "dev" from a stack trace — silently corrupted evidence is worse than a
  rare verbatim secret in a private repository. Keys and tokens are machine
  generated and long when real: eight bytes. Passwords are chosen by people:
  six, so `hunter2` (seven) is caught, which the eight-byte floor let through.

  **Longest value first.** Replacements used to run in `System.get_env/0`'s map
  order, so a short value that is a substring of a longer one shadowed it
  depending on hash order. Longest-first makes the result one thing.

  **The replacement names the variable** — `[redacted $AWEB_API_KEY]` — and
  that is decided, not accidental: it tells a reader which credentials the
  runner held, and a redaction nobody can attribute is one nobody can audit.
  The name is not the secret.
  """

  @secret_segments ~w(TOKEN SECRET PASSWORD PASSWD PASS KEY APIKEY CREDENTIAL CREDENTIALS AUTH PAT)
  @human_segments ~w(PASSWORD PASSWD PASS)
  @machine_floor 8
  @human_floor 6
  @credential_url ~r{[a-z][a-z0-9+.-]*://[^\s/@:]+:[^\s/@]+@}i

  @doc """
  Paths and secrets, in any term: strings are scrubbed, lists and maps are
  walked, everything else is returned as it is.
  """
  @spec scrub(term()) :: term()
  def scrub(text) when is_binary(text), do: text |> paths() |> secrets()
  def scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)
  def scrub(%{__struct__: _} = struct), do: struct
  def scrub(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, scrub(v)} end)
  def scrub(other), do: other

  @doc "The repository root as `.`, `$HOME` as `~`, longest first."
  @spec paths(String.t()) :: String.t()
  def paths(text) when is_binary(text) do
    [{Noetic.Harness.root(), "."}, {System.get_env("HOME"), "~"}]
    |> Enum.reject(fn {path, _} -> path in [nil, "", "/"] end)
    |> Enum.sort_by(fn {path, _} -> -byte_size(path) end)
    |> Enum.reduce(text, fn {path, with}, acc -> String.replace(acc, path, with) end)
  end

  @doc "Every held secret's value as `[redacted $NAME]`, longest value first."
  @spec secrets(String.t(), %{String.t() => String.t()}) :: String.t()
  def secrets(text, env \\ System.get_env()) when is_binary(text) do
    env
    |> Enum.filter(fn {name, value} -> is_binary(value) and secret?(name, value) end)
    |> Enum.sort_by(fn {name, value} -> {-byte_size(value), name} end)
    |> Enum.reduce(text, fn {name, value}, acc ->
      String.replace(acc, value, "[redacted $#{name}]")
    end)
  end

  @doc "Whether a variable is treated as a secret: its name's last segment, and its floor."
  @spec secret?(String.t(), String.t()) :: boolean()
  def secret?(name, value) do
    last = name |> String.upcase() |> String.split("_", trim: true) |> List.last() || ""

    cond do
      last in @human_segments -> byte_size(value) >= @human_floor
      last in @secret_segments -> byte_size(value) >= @machine_floor
      String.ends_with?(last, ["KEY", "TOKEN", "SECRET"]) -> byte_size(value) >= @machine_floor
      true -> false
    end
  end

  @doc """
  Whether text still carries a `scheme://user:password@host` run after
  redaction — a secret this process never held, so redaction by value could not
  know it. Callers withhold such evidence rather than write it.
  """
  @spec credential_url?(String.t()) :: boolean()
  def credential_url?(text) when is_binary(text), do: Regex.match?(@credential_url, text)
end
