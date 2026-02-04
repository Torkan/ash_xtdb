# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.DML.Insert do
  @moduledoc """
  SQL INSERT statement generation for XTDB.

  Provides functions to build INSERT statements including:
  - Simple inserts
  - Inserts with explicit valid time periods
  - Bulk inserts for multiple records

  ## XTDB-Specific Considerations

  - XTDB uses `_id` (quoted) for the primary key column
  - Valid time can be specified via `_valid_from` and `_valid_to` columns
  - XTDB INSERT is naturally upsert behavior (INSERT OR REPLACE)
  """

  alias AshXTDB.SQL.Core

  @doc """
  Builds an INSERT statement.

  XTDB requires _id column (quoted) for the primary key.

  ## Example

      iex> build_insert("users", %{_id: "user-1", name: "Alice"}, MyResource)
      {"INSERT INTO \\"users\\" (\\"_id\\", name) VALUES ($1, $2)", ["user-1", "Alice"]}
  """
  @spec build_insert(String.t(), map(), Ash.Resource.t()) :: {String.t(), list()}
  def build_insert(table, record, _resource) do
    # Convert to list of tuples to ensure column-value alignment
    items = Enum.to_list(record)
    columns = Enum.map(items, fn {k, _v} -> k end)
    values = Enum.map(items, fn {_k, v} -> v end)

    column_list = Enum.map_join(columns, ", ", &Core.to_insert_column_name/1)
    placeholders = Enum.map_join(1..length(values), ", ", fn i -> "$#{i}" end)

    sql = "INSERT INTO #{Core.quote_identifier(table)} (#{column_list}) VALUES (#{placeholders})"

    {sql, values}
  end

  @doc """
  Builds an INSERT statement with explicit valid time period.

  XTDB v2 uses _valid_from and _valid_to columns to specify the valid time range.

  ## Example SQL

      INSERT INTO users ("_id", name, "_valid_from", "_valid_to")
      VALUES ($1, $2, TIMESTAMP '2024-01-01T00:00:00Z', TIMESTAMP '2024-12-31T23:59:59Z')
  """
  @spec build_insert_with_valid_time(
          String.t(),
          map(),
          Ash.Resource.t(),
          DateTime.t(),
          DateTime.t()
        ) ::
          {String.t(), list()}
  def build_insert_with_valid_time(table, record, _resource, %DateTime{} = from, %DateTime{} = to) do
    # Add _valid_from and _valid_to to the record
    record_with_valid_time =
      record
      |> Map.put(:_valid_from, from)
      |> Map.put(:_valid_to, to)

    # Convert to list of tuples to ensure column-value alignment
    items = Enum.to_list(record_with_valid_time)
    columns = Enum.map(items, fn {k, _v} -> k end)
    values = Enum.map(items, fn {_k, v} -> v end)

    column_list = Enum.map_join(columns, ", ", &Core.to_insert_column_name/1)
    placeholders = Enum.map_join(1..length(values), ", ", fn i -> "$#{i}" end)

    sql = "INSERT INTO #{Core.quote_identifier(table)} (#{column_list}) VALUES (#{placeholders})"

    {sql, values}
  end

  @doc """
  Builds an INSERT statement with explicit valid_from time.

  XTDB v2 uses _valid_from column to specify the start of valid time.
  The end of valid time will be "end of time" (infinity).

  ## Example SQL

      INSERT INTO users ("_id", name, "_valid_from")
      VALUES ($1, $2, TIMESTAMP '2024-06-01T00:00:00Z')
  """
  @spec build_insert_with_valid_from(String.t(), map(), Ash.Resource.t(), DateTime.t()) ::
          {String.t(), list()}
  def build_insert_with_valid_from(table, record, _resource, %DateTime{} = from) do
    # Add _valid_from to the record
    record_with_valid_from = Map.put(record, :_valid_from, from)

    # Convert to list of tuples to ensure column-value alignment
    items = Enum.to_list(record_with_valid_from)
    columns = Enum.map(items, fn {k, _v} -> k end)
    values = Enum.map(items, fn {_k, v} -> v end)

    column_list = Enum.map_join(columns, ", ", &Core.to_insert_column_name/1)
    placeholders = Enum.map_join(1..length(values), ", ", fn i -> "$#{i}" end)

    sql = "INSERT INTO #{Core.quote_identifier(table)} (#{column_list}) VALUES (#{placeholders})"

    {sql, values}
  end

  @doc """
  Builds a bulk INSERT statement for multiple records.

  All records are inserted in a single statement using multiple value tuples.

  ## Example

      iex> build_bulk_insert("users", [%{_id: "1", name: "A"}, %{_id: "2", name: "B"}], Res)
      {"INSERT INTO \\"users\\" (\\"_id\\", name) VALUES ($1, $2), ($3, $4)", ["1", "A", "2", "B"]}
  """
  @spec build_bulk_insert(String.t(), list(map()), Ash.Resource.t()) :: {String.t(), list()}
  def build_bulk_insert(table, records, _resource) when is_list(records) do
    # Get all unique columns from all records
    all_columns =
      records
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    column_list = Enum.map_join(all_columns, ", ", &Core.to_insert_column_name/1)

    # Build values and params
    {value_clauses, params, _} =
      Enum.reduce(records, {[], [], 1}, fn record, {clauses, params, idx} ->
        {placeholders, new_params, new_idx} =
          Enum.reduce(all_columns, {[], [], idx}, fn col, {ph, p, i} ->
            value = Map.get(record, col)
            {["$#{i}" | ph], [value | p], i + 1}
          end)

        clause = "(#{placeholders |> Enum.reverse() |> Enum.join(", ")})"
        {[clause | clauses], params ++ Enum.reverse(new_params), new_idx}
      end)

    values = value_clauses |> Enum.reverse() |> Enum.join(", ")
    sql = "INSERT INTO #{Core.quote_identifier(table)} (#{column_list}) VALUES #{values}"

    {sql, params}
  end
end
