defmodule Noetic.Harness.Validation.Schema do
  @moduledoc """
  A deliberately small JSON Schema subset evaluator.

  ## Why a subset, and why it says so

  The harness has no dependencies, on purpose: its tests must run when the
  product's services are down. A full JSON Schema implementation is a
  dependency-sized problem, and the schemas in `.agents/schemas/` use about
  eleven keywords between them.

  Supported: `type`, `required`, `properties`, `additionalProperties`, `items`,
  `enum`, `const`, `pattern`, `minItems`, `maxItems`, `minLength`,
  `maxLength`, `minimum`, `maximum`, and `$ref` to a local `#/definitions/…`.

  **Unsupported keywords are reported, not ignored.** `allOf`, `anyOf`,
  `oneOf`, `if`/`then` and `format` produce an explicit "unsupported keyword"
  finding. A validator that silently passes what it cannot check is worse than
  no validator: it converts an unchecked document into a checked one in the
  reader's mind.

  The bounds keywords were added because the reporting worked *too* well to
  live with. Twice a schema was written with `minLength` or `minimum`, twice
  the validator correctly announced it was not checking them, and twice the
  repair was to delete the constraint — because a constraint that warns is a
  constraint that lies. Each of them is three lines. Deleting a real
  constraint to silence an honest warning is the wrong end of the trade, and
  it happened twice before anyone noticed it was a pattern.

  The interesting checks are not here anyway. That every skill a role names
  exists on disk, that a gate's holder is a real role, that a workflow step's
  capability is supplied by somebody — none of those are expressible in JSON
  Schema, and they live in `Noetic.Harness.Validation`.
  """

  @supported ~w(type required properties additionalProperties items enum const pattern
                minItems maxItems minLength maxLength minimum maximum
                $ref $schema $id title description definitions doc)

  @doc """
  Validate `data` against `schema`. Returns a list of findings; `[]` is valid.

  `label` prefixes every finding so that a caller validating fifty documents
  can tell which one failed.
  """
  @spec validate(term(), map(), String.t()) :: [String.t()]
  def validate(data, schema, label \\ "") do
    check(data, schema, schema, path_of(label))
  end

  defp check(data, schema, root, path) do
    unsupported(schema, path) ++
      Enum.flat_map(schema, fn
        {"$ref", "#/definitions/" <> name} ->
          case get_in(root, ["definitions", name]) do
            nil -> ["#{path}: $ref to missing definition #{name}"]
            resolved -> check(data, resolved, root, path)
          end

        {"type", type} ->
          type_check(data, type, path)

        {"required", keys} when is_map(data) ->
          for key <- keys, not Map.has_key?(data, key), do: "#{path}: missing required key #{key}"

        {"properties", properties} when is_map(data) ->
          Enum.flat_map(properties, fn {key, subschema} ->
            case Map.fetch(data, key) do
              {:ok, value} -> check(value, subschema, root, "#{path}.#{key}")
              :error -> []
            end
          end)

        {"additionalProperties", false} when is_map(data) ->
          allowed = schema |> Map.get("properties", %{}) |> Map.keys() |> MapSet.new()

          for key <- Map.keys(data), not MapSet.member?(allowed, key) do
            "#{path}: unexpected key #{key}"
          end

        {"items", subschema} when is_list(data) ->
          data
          |> Enum.with_index()
          |> Enum.flat_map(fn {item, index} ->
            check(item, subschema, root, "#{path}[#{index}]")
          end)

        {"enum", values} ->
          if data in values,
            do: [],
            else: ["#{path}: #{inspect(data)} is not one of #{inspect(values)}"]

        {"const", value} ->
          if data == value,
            do: [],
            else: ["#{path}: expected #{inspect(value)}, got #{inspect(data)}"]

        {"pattern", pattern} when is_binary(data) ->
          # `dollar_endonly`: JSON Schema's patterns are ECMA-262's, where `$`
          # is the end of the string. PCRE's also matches before a final
          # newline, so `^[0-9a-f]{40}$` accepted a sha copied with its
          # newline — found by the review of an earlier change, whose handoff carries
          # a head that merge-check compares with S.
          case Regex.compile(pattern, [:dollar_endonly]) do
            {:ok, regex} ->
              if Regex.match?(regex, data),
                do: [],
                else: ["#{path}: #{inspect(data)} does not match #{pattern}"]

            {:error, _} ->
              ["#{path}: schema has an invalid pattern #{inspect(pattern)}"]
          end

        {"minItems", minimum} when is_list(data) ->
          if length(data) >= minimum,
            do: [],
            else: ["#{path}: expected at least #{minimum} items, got #{length(data)}"]

        {"maxItems", maximum} when is_list(data) ->
          if length(data) <= maximum,
            do: [],
            else: ["#{path}: expected at most #{maximum} items, got #{length(data)}"]

        {"minLength", minimum} when is_binary(data) ->
          # Graphemes, not bytes: a schema saying "at least one character"
          # should not be satisfied by half of one.
          length = String.length(data)

          if length >= minimum,
            do: [],
            else: ["#{path}: expected at least #{minimum} characters, got #{length}"]

        {"maxLength", maximum} when is_binary(data) ->
          length = String.length(data)

          if length <= maximum,
            do: [],
            else: ["#{path}: expected at most #{maximum} characters, got #{length}"]

        {"minimum", minimum} when is_number(data) ->
          if data >= minimum,
            do: [],
            else: ["#{path}: expected at least #{minimum}, got #{inspect(data)}"]

        {"maximum", maximum} when is_number(data) ->
          if data <= maximum,
            do: [],
            else: ["#{path}: expected at most #{maximum}, got #{inspect(data)}"]

        _ ->
          []
      end)
  end

  defp unsupported(schema, path) do
    schema
    |> Map.keys()
    |> Enum.reject(&(&1 in @supported))
    |> Enum.map(fn keyword ->
      "#{path}: schema uses #{keyword}, which this subset evaluator does not implement — " <>
        "the constraint is NOT checked"
    end)
  end

  defp type_check(data, types, path) when is_list(types) do
    if Enum.any?(types, &matches_type?(data, &1)),
      do: [],
      else: ["#{path}: expected one of #{inspect(types)}, got #{describe(data)}"]
  end

  defp type_check(data, type, path) do
    if matches_type?(data, type),
      do: [],
      else: ["#{path}: expected #{type}, got #{describe(data)}"]
  end

  defp matches_type?(data, "object"), do: is_map(data)
  defp matches_type?(data, "array"), do: is_list(data)
  defp matches_type?(data, "string"), do: is_binary(data)
  defp matches_type?(data, "integer"), do: is_integer(data)
  defp matches_type?(data, "number"), do: is_number(data)
  defp matches_type?(data, "boolean"), do: is_boolean(data)
  defp matches_type?(data, "null"), do: is_nil(data)
  defp matches_type?(_data, _type), do: true

  defp describe(data) when is_map(data), do: "object"
  defp describe(data) when is_list(data), do: "array"
  defp describe(data) when is_binary(data), do: "string"
  defp describe(data) when is_integer(data), do: "integer"
  defp describe(data) when is_float(data), do: "number"
  defp describe(data) when is_boolean(data), do: "boolean"
  defp describe(nil), do: "null"
  defp describe(other), do: inspect(other)

  defp path_of(""), do: "$"
  defp path_of(label), do: label
end
