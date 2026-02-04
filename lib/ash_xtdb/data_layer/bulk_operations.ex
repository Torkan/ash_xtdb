# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.BulkOperations do
  @moduledoc """
  Bulk operations for the XTDB data layer.

  Provides efficient batch operations for creating, updating, and destroying
  multiple records in a single query.

  ## Operations

  - `bulk_create/3` - Insert multiple records in a single INSERT statement
  - `update_query/4` - Update records matching a filter condition
  - `destroy_query/4` - Delete records matching a filter condition

  ## XTDB-Specific Considerations

  - XTDB doesn't support RETURNING clauses in DML statements, so after bulk
    operations we cannot return the actual affected records. When `return_records?`
    is true, Ash will re-fetch if needed.
  - Parameters are inlined for XTDB's simple query protocol.
  """

  require Logger

  alias AshXTDB.DataLayer.Errors
  alias AshXTDB.DataLayer.Info
  alias AshXTDB.DataLayer.ResultTransformer
  alias AshXTDB.SQL

  @doc """
  Creates multiple records in a single bulk INSERT.

  ## Options

  - `:return_records?` - When true, returns the created records (default: false)

  ## Returns

  - `:ok` when return_records? is false
  - `{:ok, records}` when return_records? is true
  - `{:error, error}` on failure
  """
  @spec bulk_create(Ash.Resource.t(), Enumerable.t(), map()) ::
          :ok | {:ok, [struct()]} | {:error, term()}
  def bulk_create(resource, stream, options) do
    repo = Info.repo!(resource)
    table = Info.table!(resource)
    options = options || %{}
    return_records? = Map.get(options, :return_records?, false)

    # Convert stream to list and apply attributes to get full records
    changesets = Enum.to_list(stream)

    # Get attribute names (not relationships)
    attr_names = resource |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

    records_with_changesets =
      changesets
      |> Enum.reduce_while({:ok, []}, fn changeset, {:ok, acc} ->
        case Ash.Changeset.apply_attributes(changeset) do
          {:ok, record} ->
            # Convert struct to map, keeping only attributes (not relationships)
            record_map =
              record
              |> Map.from_struct()
              |> Map.take(attr_names)
              |> Enum.reject(fn {_k, v} -> is_nil(v) end)
              |> Map.new()
              |> ResultTransformer.map_primary_key_to_id(resource)

            {:cont, {:ok, [{record_map, changeset} | acc]}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end)

    case records_with_changesets do
      {:error, error} ->
        {:error, error}

      {:ok, []} ->
        if return_records?, do: {:ok, []}, else: :ok

      {:ok, records_with_changesets} ->
        # Reverse to maintain order
        records_with_changesets = Enum.reverse(records_with_changesets)
        records = Enum.map(records_with_changesets, fn {record, _} -> record end)

        # Build batch INSERT SQL
        {sql, params} = SQL.build_bulk_insert(table, records, resource)

        Logger.debug("AshXTDB BULK INSERT: #{sql} with params: #{inspect(params)}")

        # XTDB requires inlined params for inserts
        inlined_sql = SQL.inline_params(sql, params)

        case repo.query(inlined_sql, []) do
          {:ok, _result} ->
            if return_records? do
              # Map records back to structs with bulk metadata
              result_records =
                Enum.map(records_with_changesets, fn {record, changeset} ->
                  attrs = ResultTransformer.map_id_to_primary_key(record, resource)
                  result = struct(resource, attrs)
                  # Add bulk operation metadata from changeset context
                  Ash.Actions.Helpers.Bulk.put_metadata(result, changeset)
                end)

              {:ok, result_records}
            else
              :ok
            end

          {:error, error} ->
            {:error, Errors.to_ash_error(error)}
        end
    end
  end

  @doc """
  Updates records matching a query filter.

  Builds an UPDATE statement with a WHERE clause derived from the query filter.

  ## Options

  - `:return_records?` - When true, returns empty list (XTDB limitation)

  ## Returns

  - `:ok` when return_records? is false
  - `{:ok, []}` when return_records? is true (XTDB doesn't support RETURNING)
  - `{:error, error}` on failure
  """
  @spec update_query(SQL.t(), Ash.Changeset.t(), Ash.Resource.t(), map()) ::
          :ok | {:ok, []} | {:error, term()}
  def update_query(query, changeset, resource, options) do
    repo = Info.repo!(resource)
    table = Info.table!(resource)
    return_records? = Map.get(options, :return_records?, false)

    # Get the changes and atomics from changeset
    changes = get_changes(changeset)
    atomics = changeset.atomics || []

    if map_size(changes) == 0 and atomics == [] do
      if return_records?, do: {:ok, []}, else: :ok
    else
      # Build UPDATE with WHERE from filter, including atomics
      {sql, params} = SQL.build_update_query(table, changes, atomics, query, resource)

      Logger.debug("AshXTDB UPDATE QUERY: #{sql} with params: #{inspect(params)}")

      # Inline params for XTDB
      inlined_sql = SQL.inline_params(sql, params)

      case repo.query(inlined_sql, []) do
        {:ok, _result} ->
          # XTDB doesn't allow SELECT in DML transactions, so we can't return
          # the actual updated records. Return empty list when return_records? is true.
          # Ash will re-fetch if needed.
          if return_records? do
            {:ok, []}
          else
            :ok
          end

        {:error, error} ->
          {:error, Errors.to_ash_error(error)}
      end
    end
  end

  @doc """
  Destroys records matching a query filter.

  Builds a DELETE statement with a WHERE clause derived from the query filter.

  ## Options

  - `:return_records?` - When true, returns empty list (XTDB limitation)

  ## Returns

  - `:ok` when return_records? is false
  - `{:ok, []}` when return_records? is true (XTDB doesn't support RETURNING)
  - `{:error, error}` on failure
  """
  @spec destroy_query(SQL.t(), Ash.Changeset.t(), Ash.Resource.t(), map()) ::
          :ok | {:ok, []} | {:error, term()}
  def destroy_query(query, _changeset, resource, options) do
    repo = Info.repo!(resource)
    table = Info.table!(resource)
    return_records? = Map.get(options, :return_records?, false)

    # Build DELETE with WHERE from filter
    {sql, params} = SQL.build_destroy_query(table, query, resource)

    Logger.debug("AshXTDB DESTROY QUERY: #{sql} with params: #{inspect(params)}")

    # Inline params for XTDB
    inlined_sql = SQL.inline_params(sql, params)

    case repo.query(inlined_sql, []) do
      {:ok, _result} ->
        # XTDB doesn't allow SELECT in DML transactions, so we can't return
        # the actual destroyed records. Return empty list when return_records? is true.
        if return_records? do
          {:ok, []}
        else
          :ok
        end

      {:error, error} ->
        {:error, Errors.to_ash_error(error)}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_changes(changeset) do
    changeset.attributes
    |> Map.new()
  end
end
