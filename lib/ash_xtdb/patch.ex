# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Patch do
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
      AshXTDB.Patch.execute(
        resource: User,
        records: [%{id: uuid, email: "alice@test.com", name: "Alice"}]
      )

      # Upsert with valid time
      AshXTDB.Patch.execute(
        resource: User,
        records: [%{id: uuid, name: "Alice"}],
        valid_from: ~U[2024-01-01 00:00:00Z],
        valid_to: ~U[2024-12-31 23:59:59Z]
      )
  """

  alias AshXTDB.DataLayer.Info
  alias AshXTDB.Query

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
      AshXTDB.Patch.execute(
        resource: User,
        records: [
          %{id: "uuid1", email: "alice@test.com", name: "Alice"},
          %{id: "uuid2", email: "bob@test.com", name: "Bob"}
        ]
      )

      # Upsert with temporal bounds
      AshXTDB.Patch.execute(
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
    valid_time_clause = build_valid_time_clause(valid_from, valid_to)
    quoted_table = AshXTDB.Query.quote_identifier(table)

    if valid_time_clause do
      "PATCH INTO #{quoted_table} #{valid_time_clause} RECORDS #{records_clause}"
    else
      "PATCH INTO #{quoted_table} RECORDS #{records_clause}"
    end
  end

  @doc """
  Legacy build_patch_sql for backwards compatibility.
  Converts the old API to the new XTDB v2 syntax.
  """
  @spec build_patch_sql(
          String.t(),
          list(map()),
          list(atom()),
          :update | :delete | :skip,
          :insert | :skip,
          :all | list(atom()),
          Ash.Resource.t()
        ) :: String.t()
  def build_patch_sql(table, records, _match_keys, _on_match, _on_no_match, _update_fields, _resource) do
    # XTDB v2's PATCH always upserts by _id, ignoring match_keys and on_match/on_no_match
    # The merge behavior is at key level: present keys override, absent keys preserve
    build_patch_sql(table, records, nil, nil)
  end

  # Build the RECORDS clause with XTDB map syntax
  defp build_records_clause(records) do
    records
    |> Enum.map(&record_to_xtdb_map/1)
    |> Enum.join(", ")
  end

  # Convert an Elixir map to XTDB's map literal syntax
  defp record_to_xtdb_map(record) do
    entries =
      record
      |> Enum.map(fn {key, value} ->
        # Map :id to :_id for XTDB
        xtdb_key = if key == :id, do: :_id, else: key
        "#{xtdb_key}: #{format_value(value)}"
      end)
      |> Enum.join(", ")

    "{#{entries}}"
  end

  # Format a value for XTDB SQL
  defp format_value(nil), do: "NULL"
  defp format_value(value) when is_binary(value), do: Query.escape_value(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: Float.to_string(value)
  defp format_value(true), do: "true"
  defp format_value(false), do: "false"

  defp format_value(%DateTime{} = dt) do
    "TIMESTAMP '#{DateTime.to_iso8601(dt)}'"
  end

  defp format_value(%Date{} = d) do
    "DATE '#{Date.to_iso8601(d)}'"
  end

  defp format_value(value) do
    # Fallback: use Query.escape_value for complex types
    Query.escape_value(value)
  end

  # Build the FOR PORTION OF VALID_TIME clause
  defp build_valid_time_clause(nil, nil), do: nil

  defp build_valid_time_clause(%DateTime{} = from, %DateTime{} = to) do
    "FOR PORTION OF VALID_TIME FROM TIMESTAMP '#{DateTime.to_iso8601(from)}' TO TIMESTAMP '#{DateTime.to_iso8601(to)}'"
  end

  defp build_valid_time_clause(%DateTime{} = from, nil) do
    # Only from specified - to end of time
    "FOR PORTION OF VALID_TIME FROM TIMESTAMP '#{DateTime.to_iso8601(from)}' TO END_OF_TIME()"
  end

  defp build_valid_time_clause(nil, %DateTime{} = to) do
    # Only to specified - from now
    "FOR PORTION OF VALID_TIME FROM CURRENT_TIMESTAMP TO TIMESTAMP '#{DateTime.to_iso8601(to)}'"
  end

  @doc """
  Builds a simple upsert PATCH for a single record.
  """
  @spec upsert(Ash.Resource.t(), map()) :: :ok | {:error, term()}
  def upsert(resource, record) do
    execute(resource: resource, records: [record])
  end

  @doc """
  Builds a simple upsert PATCH for a single record (legacy API with match_keys).
  """
  @spec upsert(Ash.Resource.t(), map(), list(atom())) :: :ok | {:error, term()}
  def upsert(resource, record, _match_keys) do
    # XTDB v2 always matches by _id, match_keys is ignored
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
