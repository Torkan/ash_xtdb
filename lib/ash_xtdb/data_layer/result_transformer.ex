# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.ResultTransformer do
  @moduledoc """
  Transforms database results into Ash resource structs.

  Handles the conversion of raw Postgrex result rows into properly typed
  Ash resource structs, including:

  - Column name to attribute mapping (including `_id` -> primary key)
  - Type casting (atoms, maps, etc.)
  - Calculation result extraction
  - Aggregate value casting (shared by data layer and lateral joins)

  ## Type Casting

  The connection layer (`AshXTDB.Connection`) handles primary type casting
  via XTDB's type OIDs: bool, int, float, date, timestamp, timestamptz,
  JSON, and UTF-8 decode on text. The casting functions here handle
  Ash-specific type conversions (atoms, maps) and serve as safety nets
  for edge cases like CASE expressions returning text OID 25.
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

  Handles Ash-specific type conversions (atoms, maps). Most primary type
  casting (booleans, dates, timestamps, numbers) is done at the connection layer.
  """
  @spec cast_value(term(), map() | nil) :: term()
  def cast_value(nil, _type_info), do: nil
  def cast_value(value, nil), do: value

  def cast_value(value, %{type: type, constraints: constraints}) do
    if type == Ash.Type.Atom and is_binary(value) do
      String.to_atom(value)
    else
      # Most primary types (booleans, dates, timestamps, numbers, UTF-8) are
      # already handled by the connection layer. This handles Ash-specific casts.
      case Ash.Type.cast_input(type, value, constraints) do
        {:ok, casted} ->
          casted

        _ ->
          case Ash.Type.cast_stored(type, value, constraints) do
            {:ok, casted} -> casted
            :error -> value
          end
      end
    end
  end

  def cast_value(value, _type_info), do: value

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
  def cast_aggregate_value(value, %{kind: :count}), do: value

  # Sum/Min/Max — pass through already-typed values; keep is_binary fallback
  # as safety net for CASE expressions that may return text OID 25
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

  # Avg — already a float from connection layer
  def cast_aggregate_value(value, %{kind: :avg}) when is_number(value), do: value
  def cast_aggregate_value(value, %{kind: :avg}), do: value

  # Exists — booleans arrive as booleans from connection layer
  def cast_aggregate_value(value, %{kind: :exists}) when is_boolean(value), do: value
  def cast_aggregate_value(nil, %{kind: :exists}), do: false
  def cast_aggregate_value(value, %{kind: :exists}), do: !!value

  # Statistical aggregates return floats; keep is_binary fallback for edge cases
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
  def cast_aggregate_value(value, %{kind: kind})
      when kind in [:bool_and, :bool_or] and is_boolean(value),
      do: value

  def cast_aggregate_value(nil, %{kind: kind}) when kind in [:bool_and, :bool_or], do: nil
  def cast_aggregate_value(value, %{kind: kind}) when kind in [:bool_and, :bool_or], do: !!value

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
  # Record Building
  # ============================================================================

  @doc """
  Extracts a record map from an applied changeset struct.

  Keeps only resource attributes (not relationships), removes nils,
  and maps the primary key to `_id` for XTDB.
  """
  @spec struct_to_record(struct(), Ash.Resource.t()) :: map()
  def struct_to_record(record, resource) do
    attr_names = AshXTDB.DataLayer.Info.attribute_names(resource)

    record
    |> Map.from_struct()
    |> Map.take(attr_names)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> map_primary_key_to_id(resource)
  end

  # ============================================================================
  # Aggregate Query Helpers
  # ============================================================================

  @doc """
  Executes an aggregate SQL query and maps results to aggregate names.

  Shared by both `DataLayer.run_aggregate_query/3` and
  `LateralJoins.run_aggregate_query/3` to avoid duplication.
  """
  @spec run_aggregate_query(AshXTDB.SQL.t(), [Ash.Query.Aggregate.t()], Ash.Resource.t()) ::
          {:ok, map()} | {:error, term()}
  def run_aggregate_query(query, aggregates, resource) do
    alias AshXTDB.DataLayer.{Errors, Info}
    alias AshXTDB.SQL

    repo = Info.repo!(resource)
    {sql, params} = SQL.to_aggregate_sql(query, aggregates)

    require Logger
    Logger.debug("AshXTDB Aggregate SQL: #{sql} with params: #{inspect(params)}")

    case repo.query(sql, params) do
      {:ok, %Postgrex.Result{rows: [row], columns: columns}} ->
        result =
          columns
          |> Enum.zip(row)
          |> Enum.reduce(%{}, fn {col_name, value}, acc ->
            agg = Enum.find(aggregates, fn a -> Atom.to_string(a.name) == col_name end)

            if agg do
              Map.put(acc, agg.name, cast_aggregate_value(value, agg))
            else
              acc
            end
          end)

        {:ok, result}

      {:ok, %Postgrex.Result{rows: []}} ->
        {:ok, default_aggregate_result(aggregates)}

      {:error, error} ->
        {:error, Errors.to_ash_error(error)}
    end
  end

  @doc """
  Builds a default aggregate result map with default values for each aggregate.
  """
  @spec default_aggregate_result([Ash.Query.Aggregate.t()]) :: map()
  def default_aggregate_result(aggregates) do
    Map.new(aggregates, fn agg -> {agg.name, agg.default_value} end)
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
end
