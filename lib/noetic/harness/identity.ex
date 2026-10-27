defmodule Noetic.Harness.Identity do
  @moduledoc """
  Who did something, and whether anything stands behind the answer.

  Every record the harness keeps about an actor used to carry a name the actor
  typed — `HARNESS_AGENT`, else `$USER` — and `Environments` wrote
  `by_attested: false` beside it as a constant, so a later gate could not read
  the name without reading that nothing stood behind it. This module is where
  that constant stops being one.

  ## The shape

  `actor/1` returns a map shaped like an AWID identity:

  | key | when |
  |---|---|
  | `name`, `name_from` | always — what `by` and `by_from` have always been |
  | `did`, `address`, `custody` | when `.aw/identity.yaml` exists at the repository root — which `aw init` writes and `aw team join` does not |
  | `did_key`, `signature`, `signed_at` | when `sign/3` signed the record; `custody` is then `"local"` |
  | `attestation` | always: `"signed"` or `"self-asserted"` |

  A DID read out of a file is a claim anyone can copy. **A record is attested
  when `sign/3` put a signature on it and `attested?/3` can check it** — see
  `Noetic.Harness.Identity.Signature` for what is signed and against which
  keys. Signing goes through the `aw` CLI, in the directory holding the `.aw/`
  workspace identity nearest above the repository root; this module never
  opens the key file itself. Where there is no `aw`, no identity, or
  `:sign_records` is off (the test suite), a record stays `self-asserted` and
  says so.

  **What a signature proves here** (amended): `aw` signs with a key
  *on this machine*, in `.aw/`, readable by anything running as the user —
  including the agent whose work is being recorded. The actor says
  `custody: "local"`, and a signed record means "this workspace, on this
  machine", not "this person". The hosted custody the user first chose cannot
  sign through the CLI at all: `aw id sign` refuses an identity whose key it
  does not hold.

  ## Why read a YAML file without a YAML parser

  The harness has no runtime dependencies, deliberately (`mix.exs`), and the
  three fields read here are top-level `key: value` lines. A parser for them is
  eight lines; a YAML library is a dependency for the hook to load on every
  prompt.
  """

  alias Noetic.Harness.Identity.Signature

  @fields ~w(did address custody)

  @doc """
  The actor for a record. `opts[:by]` names it explicitly; otherwise the
  environment does.
  """
  @spec actor(keyword()) :: map()
  def actor(opts \\ []) do
    {name, from} =
      cond do
        by = opts[:by] -> {by, Keyword.get(opts, :by_from, "the caller's :by option")}
        value = System.get_env("HARNESS_AGENT") -> {value, "HARNESS_AGENT"}
        value = System.get_env("USER") -> {value, "USER"}
        true -> {"unattributed", "nothing said"}
      end

    base = %{"name" => name, "name_from" => from, "attestation" => "self-asserted"}

    case identity() do
      {:ok, identity} -> Map.merge(identity, base)
      :none -> base
    end
  end

  @doc """
  Whether an actor, **on its own**, is attested: never.

  A signature is over a record, not over an actor — an actor copied from a
  signed record onto another one carries a valid signature for the wrong
  thing. So an actor alone answers `false`, and `attested?/3` is the question
  with the record in it. Review showed an earlier version believing a
  hand-written `"signed"`; nothing that reads only the actor can be right.
  """
  @spec attested?(map() | nil) :: boolean()
  def attested?(_actor), do: false

  @doc """
  Whether `record` — a run step or stop, signed by `sign/4` under `kind` at
  `position` in run `run_id` — is attested: signed by a key the policy trusts,
  with the custody the policy records for it, over exactly this record at
  exactly this place in its run.

  **Not whether it says so.** Every field is re-derived: the payload from the
  record as it stands and the position it is asked about, the key and its
  custody from `.agents/policies/identity.json`. An edited record or actor, a
  record moved, duplicated or with its predecessor deleted, a signature from
  another record, a key the policy does not list and a hand-written `"signed"`
  all answer `false`. `Noetic.Harness.Run.attestation/1` walks a run file with
  the positions filled in.
  """
  @spec attested?(map(), String.t(), String.t(), map()) :: boolean()
  def attested?(
        %{"actor" => %{"attestation" => "signed"} = actor} = record,
        kind,
        run_id,
        position
      ) do
    with %{"did_key" => did_key, "signature" => signature, "signed_at" => timestamp} <- actor,
         %{"custody" => custody} <- Signature.trusted_entry(did_key),
         true <- actor["custody"] == custody,
         {:ok, payload} <- Signature.payload(kind, run_id, record, position) do
      Signature.valid?(payload, timestamp, signature, did_key)
    else
      _ -> false
    end
  end

  def attested?(_record, _kind, _run_id, _position), do: false

  @doc """
  Sign a record through `aw`, or leave it self-asserted and say why not.

  `position` is `%{seq: n, prev: digest_or_nil}` — where the record goes in
  its run and the digest of the record before it. The actor gains
  `attestation: "signed"`, `did_key`, `signature`, `signed_at` and
  `custody: "local"` only when `aw` signed it **and the signature it returned
  checks** against the payload: review had a fake `aw` print a made-up
  signature and got a `"signed"` actor. Otherwise the actor stays
  `self-asserted` with `unsigned_because`, since "nobody tried" and "it failed"
  are different facts.

  It never raises and never blocks a write — a ledger that refused to record
  work because a third-party binary was down would lose the record the
  signature was for. Review found two ways it raised; both are now
  `unsigned_because`.
  """
  @spec sign(map(), String.t(), String.t(), map()) :: map()
  def sign(%{"actor" => actor} = record, kind, run_id, position) when is_map(actor) do
    case signed(record, kind, run_id, position) do
      {:ok, found} ->
        Map.put(
          record,
          "actor",
          Map.merge(actor, %{
            "attestation" => "signed",
            "did_key" => found["did_key"],
            "signature" => found["signature"],
            "signed_at" => found["timestamp"],
            "custody" => "local"
          })
        )

      {:skip, why} ->
        Map.put(record, "actor", Map.put(actor, "unsigned_because", why))
    end
  end

  def sign(record, _kind, _run_id, _position), do: record

  defp signed(record, kind, run_id, position) do
    cond do
      Application.get_env(:noetic_harness, :sign_records, true) == false ->
        {:skip, "signing is off"}

      workspace() == nil ->
        {:skip, "no .aw workspace identity above the repository"}

      true ->
        {:ok, dir} = workspace()

        with {:ok, payload} <- Signature.payload(kind, run_id, record, position),
             {:ok, found} <-
               Signature.sign(payload, dir, aw: Application.get_env(:noetic_harness, :aw)),
             true <-
               Signature.valid?(payload, found["timestamp"], found["signature"], found["did_key"]) do
          {:ok, found}
        else
          :error ->
            {:skip, "the record cannot be signed: a run id that is not a slug, or not JSON"}

          {:error, why} ->
            {:skip, why}

          false ->
            {:skip, "aw returned a signature that does not verify"}
        end
    end
  rescue
    error -> {:skip, "signing raised: #{Exception.message(error)}"}
  end

  @doc """
  The directory whose `.aw/` holds the workspace identity: the repository
  root, or the nearest directory above it. Above, because an agent's worktree
  lives under the main checkout's `.claude/worktrees/`, and `aw` itself looks
  upward the same way.
  """
  @spec workspace() :: {:ok, Path.t()} | nil
  def workspace do
    Noetic.Harness.root()
    |> Path.expand()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while(nil, fn dir, _ ->
      cond do
        File.dir?(Path.join(dir, ".aw")) -> {:halt, {:ok, dir}}
        Path.dirname(dir) == dir -> {:halt, nil}
        true -> {:cont, nil}
      end
    end)
  end

  @doc """
  The configured AWID identity — `did`, `address`, `custody` from
  `.aw/identity.yaml` — or `:none`.
  """
  @spec identity() :: {:ok, map()} | :none
  def identity do
    path = Path.join([Noetic.Harness.root(), ".aw", "identity.yaml"])

    with {:ok, text} <- File.read(path),
         %{"did" => "did:aw:" <> _} = found <- parse(text) do
      {:ok, found}
    else
      _ -> :none
    end
  end

  # A key given twice is an identity that says two things, and it is refused
  # rather than resolved by taking one; so is a value that is a YAML block
  # indicator, which is not a value this reader can follow.
  @doc false
  def parse(text) do
    pairs =
      text
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(
               ~r/\A([a-z_]+):\s*(?:"([^"]*)"|'([^']*)'|([^\s"'#|>][^#]*?))\s*(?:#.*)?\z/,
               String.trim_trailing(line)
             ) do
          [_, key | values] when key in @fields ->
            case Enum.find(values, &(&1 != "")) do
              nil -> []
              value -> [{key, value}]
            end

          _ ->
            []
        end
      end)

    keys = Enum.map(pairs, &elem(&1, 0))
    if keys == Enum.uniq(keys), do: Map.new(pairs), else: %{}
  end
end
