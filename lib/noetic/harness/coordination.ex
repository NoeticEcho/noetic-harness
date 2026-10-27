defmodule Noetic.Harness.Coordination do
  @moduledoc """
  The coordination records under `.agents/coordination/`, checked against
  `.agents/schemas/coordination.schema.json`.

  A record is the coordinator's account of an act: an assignment written by
  `noetic-harness assign` (`Noetic.Harness.Assign.record/3`), or an approval or a
  decision written by hand. `Assign.live/1` decides who holds an
  epic from these files, so a record with a misspelt `act` or a `scope` that
  is not a list silently stops being an assignment. Until this check nothing
  said so: an earlier change wrote the records with a `schema` field reading "None
  yet".

  ## What is checked

  - every `*.json` in the directory decodes, to an object;
  - the object passes the schema: the four fields every record has (`id`,
    `act`, `at`, `by`) and the type of each field the records carry;
  - what its act requires beyond those, `definitions.act_<act>` in the same
    schema, applied here because the subset evaluator has no `if`/`then`
    (`Noetic.Harness.Validation.Schema`);
  - its `id` is its file's name, and the act named in the id is its `act`.
    `Assign.write/1` names the file for the id; a hand record that did not
    would be a second record with the same name waiting to happen.

  The schema was derived from the records on develop, and a record is never
  rewritten (the class is add-only). So a record that fails is a finding for
  the coordinator, reported by `noetic-harness validate`, not something a
  check can repair.

  ## Why it reaches `validate` through the profiles check

  `Noetic.Harness.Validation` lists its checks and its schema pairs, and it is
  behind the evaluator fence. `Noetic.Harness.Profiles.validate/1`, which the
  `profiles` check runs, is not, and `profiles.json` is where the coordination
  records are declared an add-only class. So the check is called from there;
  a `coordination` check of its own in `Validation` is a change to the fence,
  and a request for the coordinator rather than an edit here.
  """

  alias Noetic.Harness.{Loader, Validation.Schema}

  @type finding :: {:error, String.t()}

  @doc "Where the records live: `Noetic.Harness.Assign.dir/0`."
  @spec dir() :: Path.t()
  def dir, do: Noetic.Harness.Assign.dir()

  @doc "The schema's path."
  @spec schema_path() :: Path.t()
  def schema_path,
    do: Path.join(Noetic.Harness.agents_path("schemas"), "coordination.schema.json")

  @doc """
  Check every record. `[]` means every one passes.

  Options, each read from the repository when absent:
  - `:records`: `[{file_name, decoded}]`, in place of the directory; a
    decoded value of `{:error, message}` stands for a file that did not parse;
  - `:dir`: the directory to read;
  - `:schema`: the decoded schema.
  """
  @spec validate(keyword()) :: [finding()]
  def validate(opts \\ []) do
    with {:ok, schema} <- fetch_schema(opts) do
      opts
      |> records()
      |> Enum.flat_map(&check(&1, schema))
      |> Enum.map(&{:error, "coordination: " <> &1})
    else
      {:error, message} -> [{:error, "coordination: " <> message}]
    end
  end

  @doc "Check one decoded record, named by its file. Returns the messages, unprefixed."
  @spec check({String.t(), term()}, map()) :: [String.t()]
  def check({file, {:error, message}}, _schema), do: ["#{file}: #{message}"]

  def check({file, record}, schema) when is_map(record) do
    Schema.validate(record, schema, file) ++ by_act(record, schema, file) ++ named(record, file)
  end

  def check({file, _other}, _schema), do: ["#{file}: a coordination record is a JSON object"]

  # What the act requires, from `definitions.act_<act>`. An act outside the
  # enum is already a schema finding, and has no requirements to add.
  # A `$ref` into the schema's own definitions, so a missing `act_<act>` is
  # the evaluator's "missing definition" finding rather than a silent pass.
  defp by_act(%{"act" => act} = record, schema, label) when is_binary(act) do
    acts = get_in(schema, ["properties", "act", "enum"]) || []

    if act in acts do
      Schema.validate(
        record,
        %{"definitions" => schema["definitions"] || %{}, "$ref" => "#/definitions/act_" <> act},
        label
      )
    else
      []
    end
  end

  defp by_act(_record, _schema, _label), do: []

  # `id` is the file's name, and names the record's act.
  defp named(record, file) do
    stem = Path.basename(file, ".json")
    id = record["id"]

    same_name =
      if is_binary(id) and id != stem,
        do: ["#{file}: id #{inspect(id)} is not the file's name (#{inspect(stem)})"],
        else: []

    same_act =
      with true <- is_binary(id),
           [_, act_in_id] <- Regex.run(~r/^(?:coord-)?\d{4}-\d{2}-\d{2}-([a-z]+)-/, id),
           act when is_binary(act) and act != act_in_id <- record["act"] do
        ["#{file}: id #{inspect(id)} names the act #{act_in_id}, and the record's act is #{act}"]
      else
        _ -> []
      end

    same_name ++ same_act
  end

  defp fetch_schema(opts) do
    case Keyword.fetch(opts, :schema) do
      {:ok, schema} -> {:ok, schema}
      :error -> Loader.load(schema_path())
    end
  end

  defp records(opts) do
    Keyword.get_lazy(opts, :records, fn ->
      opts
      |> Keyword.get_lazy(:dir, &dir/0)
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(fn path ->
        case Loader.load(path) do
          {:ok, decoded} -> {Path.basename(path), decoded}
          {:error, message} -> {Path.basename(path), {:error, message}}
        end
      end)
    end)
  end
end
