# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.ResultTransformer do
  @moduledoc """
  Transforms database results into Ash resource structs.

  Handles the conversion of raw Postgrex result rows into properly typed
  Ash resource structs, including:

  - Column name to attribute mapping (including `_id` -> primary key)
  - Type casting (booleans, atoms, dates, etc.)
  - Calculation result extraction
  - Aggregate value casting (shared by data layer and lateral joins)

  ## Type Casting

  The connection layer (`AshXTDB.Connection`) handles primary type casting
  via XTDB's type OIDs (bool->boolean, int->integer, float->float). The
  casting functions here serve as safety nets for edge cases where values
  may still arrive as strings (e.g., atoms, certain JSON-encoded values).
  """

  @doc """
  Transforms database rows into resource structs with calculation metadata.

  Returns a list of `{struct, sql_calculations}` tuples where `sql_calculations`
  is a map of calculation names to their SQL-computed values (for calculations
  with `__calc_` prefixed column names).

  ## Parameters

  - `rows` - Raw row data from Postgrex result
  - `columns` - Column names from Postgrex result
  - `resource` - The Ash resource module

  ## Returns

  List of `{resource_struct, sql_calculations_map}` tuples.
  """
  @spec rows_to_records(list(list()), list(String.t()), Ash.Resource.t()) ::
          list({struct(), map()})
  def rows_to_records(rows, columns, resource) do
    # Use String.to_atom since XTDB may return synthetic column names
    columns = Enum.map(columns, &String.to_atom/1)

    # Separate calculation columns (prefixed with __calc_) from regular columns
    {calc_columns, attr_columns} =
      Enum.split_with(columns, fn col ->
        col |> Atom.to_string() |> String.starts_with?("__calc_")
      end)

    # Get attribute info for type casting
    attr_types = get_attribute_types(resource)

    Enum.map(rows, fn row ->
      # Build a map of column -> value
      col_values = Enum.zip(columns, row) |> Map.new()

      # Extract and cast regular attributes
      attrs =
        attr_columns
        |> Enum.map(fn col ->
          val = Map.get(col_values, col)
          {col, cast_value(val, Map.get(attr_types, col))}
        end)
        |> Map.new()

      # Map _id back to the primary key attribute
      attrs = map_id_to_primary_key(attrs, resource)

      # Extract SQL-calculated values
      sql_calculations =
        calc_columns
        |> Enum.map(fn col ->
          # Strip __calc_ prefix to get the original calculation name
          calc_name =
            col
            |> Atom.to_string()
            |> String.replace_prefix("__calc_", "")
            |> String.to_atom()

          {calc_name, Map.get(col_values, col)}
        end)
        |> Map.new()

      # Create struct with __sql_calculations__ metadata
      record = struct(resource, attrs)

      # Store SQL calculations in a metadata field that add_calculations_to_records can use
      {record, sql_calculations}
    end)
  end

  @doc """
  Transforms a single row into a resource struct.

  Similar to `rows_to_records/3` but for a single row without calculation support.
  Used primarily for mutation operations where we don't have calculations.
  """
  @spec row_to_record(list(), list(String.t()), Ash.Resource.t()) :: struct()
  def row_to_record(row, columns, resource) do
    columns = Enum.map(columns, &String.to_atom/1)
    attr_types = get_attribute_types(resource)

    attrs =
      columns
      |> Enum.zip(row)
      |> Enum.map(fn {col, val} -> {col, cast_value(val, Map.get(attr_types, col))} end)
      |> Map.new()
      |> map_id_to_primary_key(resource)

    struct(resource, attrs)
  end

  # ============================================================================
  # Type Casting
  # ============================================================================

  @doc """
  Gets attribute type information for a resource.

  Returns a map of attribute names to type info including initialized constraints.
  """
  @spec get_attribute_types(Ash.Resource.t()) :: map()
  def get_attribute_types(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(fn attr ->
      type = Ash.Type.get_type(attr.type)
      # Initialize constraints to get proper defaults (e.g., precision for datetime types)
      constraints = init_constraints(type, attr.constraints)
      {attr.name, %{type: type, constraints: constraints}}
    end)
    |> Map.new()
    |> Map.put(:_id, %{type: Ash.Type.String, constraints: []})
  end

  @doc """
  Casts a raw value to the appropriate Elixir type.

  Handles XTDB-specific value formats like "t"/"f" for booleans.
  """
  @spec cast_value(term(), map() | nil) :: term()
  def cast_value(nil, _type_info), do: nil
  def cast_value(value, nil), do: value

  def cast_value(value, %{type: type, constraints: constraints}) do
    # XTDB via pgwire returns raw values that need proper casting:
    # - Atoms come as strings -> need String.to_atom
    # - Booleans may come as "t"/"f" strings -> need explicit conversion
    # - Maps may come as JSON strings -> cast_input handles this
    # - DateTimes come as strings -> cast_input handles this
    cond do
      # Boolean type with string value - XTDB often returns "t"/"f"
      type == Ash.Type.Boolean and is_binary(value) ->
        coerce_boolean(value)

      # Atom type with string value - convert string to atom
      type == Ash.Type.Atom and is_binary(value) ->
        String.to_atom(value)

      # Try cast_input first (handles JSON strings for maps, datetime strings, etc.)
      true ->
        case Ash.Type.cast_input(type, value, constraints) do
          {:ok, casted} ->
            # Decode 4-byte UTF-8 escape sequences (XTDB workaround)
            decode_utf8_workaround(casted)

          _ ->
            # Fall back to cast_stored for already-typed values
            case Ash.Type.cast_stored(type, value, constraints) do
              {:ok, casted} -> decode_utf8_workaround(casted)
              :error -> value
            end
        end
    end
  end

  def cast_value(value, _type_info), do: value

  @doc """
  Coerces XTDB boolean string representations to Elixir booleans.

  Note: The connection layer now handles boolean casting via OIDs for most cases.
  This remains as a safety net for edge cases.
  """
  @spec coerce_boolean(term()) :: boolean() | term()
  def coerce_boolean(value) when value in ["t", "true", "TRUE", "1", "yes", "YES"], do: true
  def coerce_boolean(value) when value in ["f", "false", "FALSE", "0", "no", "NO", ""], do: false
  def coerce_boolean(value), do: value

  # ============================================================================
  # Aggregate Value Casting
  # ============================================================================

  @doc """
  Casts an aggregate result value to the appropriate Elixir type.

  The connection layer now casts most values via OIDs (integers arrive as
  integers, booleans as booleans). The `when is_integer`/`when is_number`
  clauses handle the common (already-typed) path; the `when is_binary`
  clauses remain as fallbacks for edge cases.
  """
  @spec cast_aggregate_value(term(), map()) :: term()
  def cast_aggregate_value(nil, _agg), do: nil

  # Count — already an integer from connection layer
  def cast_aggregate_value(value, %{kind: :count}) when is_integer(value), do: value

  def cast_aggregate_value(value, %{kind: :count}) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  # Sum/Min/Max — pass through already-typed values
  def cast_aggregate_value(value, %{kind: kind}) when kind in [:sum, :min, :max] do
    if is_binary(value) do
      case Integer.parse(value) do
        {int, ""} ->
          int

        _ ->
          case Float.parse(value) do
            {float, ""} -> float
            _ -> value
          end
      end
    else
      value
    end
  end

  # Avg — pass through already-typed numbers
  def cast_aggregate_value(value, %{kind: :avg}) when is_number(value), do: value

  def cast_aggregate_value(value, %{kind: :avg}) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> value
    end
  end

  # Exists — booleans arrive as booleans from connection layer
  def cast_aggregate_value(true, %{kind: :exists}), do: true
  def cast_aggregate_value(false, %{kind: :exists}), do: false

  def cast_aggregate_value(value, %{kind: :exists}) do
    case value do
      "t" -> true
      "f" -> false
      "true" -> true
      "false" -> false
      1 -> true
      0 -> false
      "1" -> true
      "0" -> false
      nil -> false
      _ -> !!value
    end
  end

  # Statistical aggregates return floats
  def cast_aggregate_value(value, %{kind: kind})
      when kind in [:stddev_pop, :stddev_samp, :var_pop, :var_samp] do
    cond do
      is_nil(value) ->
        nil

      is_float(value) ->
        value

      is_integer(value) ->
        value * 1.0

      is_binary(value) ->
        case Float.parse(value) do
          {float, _} -> float
          :error -> value
        end

      true ->
        value
    end
  end

  # Boolean aggregates — booleans arrive as booleans from connection layer
  def cast_aggregate_value(true, %{kind: kind}) when kind in [:bool_and, :bool_or], do: true
  def cast_aggregate_value(false, %{kind: kind}) when kind in [:bool_and, :bool_or], do: false

  def cast_aggregate_value(value, %{kind: kind}) when kind in [:bool_and, :bool_or] do
    case value do
      "t" -> true
      "f" -> false
      "true" -> true
      "false" -> false
      1 -> true
      0 -> false
      "1" -> true
      "0" -> false
      nil -> nil
      _ -> !!value
    end
  end

  def cast_aggregate_value(value, _agg), do: value

  # ============================================================================
  # ID Mapping
  # ============================================================================

  @doc """
  Maps the `_id` column back to the resource's primary key attribute.
  """
  @spec map_id_to_primary_key(map(), Ash.Resource.t()) :: map()
  def map_id_to_primary_key(attrs, resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [pkey] when pkey != :_id ->
        case Map.pop(attrs, :_id) do
          {nil, attrs} -> attrs
          {id_value, attrs} -> Map.put(attrs, pkey, id_value)
        end

      _ ->
        attrs
    end
  end

  @doc """
  Maps the resource's primary key attribute to `_id` for XTDB.
  """
  @spec map_primary_key_to_id(map(), Ash.Resource.t()) :: map()
  def map_primary_key_to_id(attrs, resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [pkey] when pkey != :_id ->
        case Map.pop(attrs, pkey) do
          {nil, attrs} -> attrs
          {pkey_value, attrs} -> Map.put(attrs, :_id, pkey_value)
        end

      _ ->
        attrs
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp init_constraints(type, constraints) do
    if function_exported?(type, :init, 1) do
      case type.init(constraints) do
        {:ok, initialized} -> initialized
        _ -> constraints
      end
    else
      constraints
    end
  end

  # Decode 4-byte UTF-8 escape sequences from XTDB workaround
  defp decode_utf8_workaround(value) when is_binary(value) do
    AshXTDB.UTF8Workaround.decode(value)
  end

  # Structs (DateTime, Date, etc.) should pass through unchanged
  defp decode_utf8_workaround(value) when is_struct(value), do: value

  defp decode_utf8_workaround(value) when is_map(value) do
    AshXTDB.UTF8Workaround.decode_deep(value)
  end

  defp decode_utf8_workaround(value), do: value
end
