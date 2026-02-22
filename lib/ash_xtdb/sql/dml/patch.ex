# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.DML.Patch do
  @moduledoc """
  XTDB PATCH statement support.

  PATCH patches documents already in a table with the given document - updating
  those that exist, inserting any that don't (an 'upsert') - optionally for a
  period of valid-time.

  ## XTDB v2 PATCH Syntax

  ```sql
  PATCH INTO <table name>
    FOR PORTION OF VALID_TIME FROM <timestamp> TO <timestamp>
    RECORDS {_id: value, column1: value1, ...}, {...}
  ```

  ## Key Behaviors

  - The `_id` column cannot be patched - matching is always by `_id`
  - Documents merge at key level: present keys override, absent/null keys preserve
  - If valid-time isn't specified, effective range is now through end-of-time
  - The valid-time columns cannot be updated outside the `FOR PORTION OF` clause

  ## Examples

      # Simple upsert
      AshXTDB.SQL.DML.Patch.execute(
        resource: User,
        records: [%{id: uuid, email: "alice@test.com", name: "Alice"}]
      )

      # Upsert with valid time
      AshXTDB.SQL.DML.Patch.execute(
        resource: User,
        records: [%{id: uuid, name: "Alice"}],
        valid_from: ~U[2024-01-01 00:00:00Z],
        valid_to: ~U[2024-12-31 23:59:59Z]
      )
  """

  alias AshXTDB.DataLayer.Info
  alias AshXTDB.SQL
  alias AshXTDB.SQL.Core
  alias AshXTDB.SQL.Temporal

  @type patch_option ::
          {:resource, Ash.Resource.t()}
          | {:records, list(map())}
          | {:valid_from, DateTime.t()}
          | {:valid_to, DateTime.t()}

  @doc """
  Executes a PATCH operation.

  ## Options

  - `:resource` - The Ash resource to patch (required)
  - `:records` - List of record maps to patch (required). Each must have an `id` or `_id` key.
  - `:valid_from` - Start of valid time period (optional)
  - `:valid_to` - End of valid time period (optional)

  ## Examples

      # Upsert users
      AshXTDB.SQL.DML.Patch.execute(
        resource: User,
        records: [
          %{id: "uuid1", email: "alice@test.com", name: "Alice"},
          %{id: "uuid2", email: "bob@test.com", name: "Bob"}
        ]
      )

      # Upsert with temporal bounds
      AshXTDB.SQL.DML.Patch.execute(
        resource: User,
        records: [%{id: "uuid1", name: "Updated Name"}],
        valid_from: ~U[2024-01-01 00:00:00Z],
        valid_to: ~U[2024-06-30 23:59:59Z]
      )
  """
  @spec execute(keyword()) :: :ok | {:error, term()}
  def execute(opts) do
    resource = Keyword.fetch!(opts, :resource)
    records = Keyword.fetch!(opts, :records)
    valid_from = Keyword.get(opts, :valid_from)
    valid_to = Keyword.get(opts, :valid_to)

    repo = Info.repo!(resource)
    table = Info.table!(resource)

    # Build the PATCH SQL
    sql = build_patch_sql(table, records, valid_from, valid_to)

    case repo.query(sql, []) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Builds a PATCH SQL statement using XTDB v2's RECORDS syntax.

  ## Parameters

  - `table` - The table name
  - `records` - List of record maps (each must have `id` or `_id`)
  - `valid_from` - Optional start of valid time
  - `valid_to` - Optional end of valid time

  ## Examples

      iex> build_patch_sql("users", [%{id: "123", name: "Alice"}], nil, nil)
      "PATCH INTO users RECORDS {_id: '123', name: 'Alice'}"

      iex> build_patch_sql("users", [%{id: "123", name: "Alice"}],
      ...>   ~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
      "PATCH INTO users FOR PORTION OF VALID_TIME FROM TIMESTAMP '2024-01-01T00:00:00Z' TO TIMESTAMP '2024-12-31T23:59:59Z' RECORDS {_id: '123', name: 'Alice'}"
  """
  @spec build_patch_sql(String.t(), list(map()), DateTime.t() | nil, DateTime.t() | nil) ::
          String.t()
  def build_patch_sql(table, records, valid_from, valid_to) do
    records_clause = build_records_clause(records)
    valid_time_clause = Temporal.build_valid_time_clause(valid_from, valid_to)
    quoted_table = SQL.quote_identifier(table)

    if valid_time_clause do
      "PATCH INTO #{quoted_table} #{valid_time_clause} RECORDS #{records_clause}"
    else
      "PATCH INTO #{quoted_table} RECORDS #{records_clause}"
    end
  end

  # Build the RECORDS clause with XTDB map syntax
  defp build_records_clause(records) do
    Enum.map_join(records, ", ", &record_to_xtdb_map/1)
  end

  # Convert an Elixir map to XTDB's map literal syntax
  defp record_to_xtdb_map(record) do
    entries =
      Enum.map_join(record, ", ", fn {key, value} ->
        # Map :id to :_id for XTDB
        xtdb_key = if key == :id, do: :_id, else: key
        "#{xtdb_key}: #{Core.escape_value(value)}"
      end)

    "{#{entries}}"
  end

  @doc """
  Builds a simple upsert PATCH for a single record.
  """
  @spec upsert(Ash.Resource.t(), map()) :: :ok | {:error, term()}
  def upsert(resource, record) do
    execute(resource: resource, records: [record])
  end

  @doc """
  Patches multiple records with temporal bounds.
  """
  @spec patch_for_valid_time(
          Ash.Resource.t(),
          list(map()),
          DateTime.t(),
          DateTime.t()
        ) :: :ok | {:error, term()}
  def patch_for_valid_time(resource, records, valid_from, valid_to) do
    execute(
      resource: resource,
      records: records,
      valid_from: valid_from,
      valid_to: valid_to
    )
  end
end
