# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.Mutations do
  @moduledoc """
  Mutation operations for the XTDB data layer.

  Provides create, update, destroy, and upsert operations for individual records.

  ## XTDB-Specific Considerations

  - XTDB INSERT is naturally an upsert based on `_id`
  - XTDB doesn't allow SELECTs in DML transactions, so after updates we can't
    refetch computed values - the caller must refetch if needed
  """

  require Logger

  alias AshXTDB.DataLayer.Errors
  alias AshXTDB.DataLayer.Info
  alias AshXTDB.DataLayer.ResultTransformer
  alias AshXTDB.SQL

  @doc """
  Creates a new record from a changeset.
  """
  @spec create(Ash.Resource.t(), Ash.Changeset.t()) :: {:ok, struct()} | {:error, term()}
  def create(resource, changeset) do
    repo = Info.repo!(resource)
    table = Info.table!(resource)

    # Apply attributes to get all values including generated defaults (UUIDs, etc.)
    case Ash.Changeset.apply_attributes(changeset) do
      {:ok, applied_record} ->
        # Build record map from applied struct
        record = ResultTransformer.struct_to_record(applied_record, resource)
        {sql, params} = SQL.build_insert(table, record, resource)

        Logger.debug("AshXTDB INSERT: #{sql} with params: #{inspect(params)}")

        case repo.query(sql, params) do
          {:ok, _result} ->
            # Map _id back to the primary key attribute for the struct
            result_attrs = ResultTransformer.map_id_to_primary_key(record, resource)
            {:ok, struct(resource, result_attrs)}

          {:error, error} ->
            {:error, Errors.to_ash_error(error)}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Updates an existing record from a changeset.
  """
  @spec update(Ash.Resource.t(), Ash.Changeset.t()) :: {:ok, struct()} | {:error, term()}
  def update(resource, changeset) do
    repo = Info.repo!(resource)
    table = Info.table!(resource)

    # Get the primary key value(s) for WHERE clause
    pkey = primary_key_value(changeset.data, resource)

    # Get changed attributes and atomics
    changes = Map.new(changeset.attributes)
    atomics = changeset.atomics || []

    if map_size(changes) == 0 and atomics == [] do
      # No changes, return existing record
      {:ok, changeset.data}
    else
      {sql, params} = SQL.build_update(table, pkey, changes, atomics, resource)

      Logger.debug("AshXTDB UPDATE: #{sql} with params: #{inspect(params)}")

      case repo.query(sql, params) do
        {:ok, _result} ->
          # Note: XTDB doesn't allow SELECTs in DML transactions, so we can't
          # refetch to get computed atomic values. We return the record with
          # regular changes applied. For atomics, the caller must refetch.
          updated = Map.merge(changeset.data, changes)
          {:ok, updated}

        {:error, error} ->
          {:error, Errors.to_ash_error(error)}
      end
    end
  end

  @doc """
  Destroys a record.
  """
  @spec destroy(Ash.Resource.t(), Ash.Changeset.t()) :: :ok | {:error, term()}
  def destroy(resource, changeset) do
    repo = Info.repo!(resource)
    table = Info.table!(resource)

    pkey = primary_key_value(changeset.data, resource)
    {sql, params} = SQL.build_delete(table, pkey, resource)

    Logger.debug("AshXTDB DELETE: #{sql} with params: #{inspect(params)}")

    case repo.query(sql, params) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        {:error, Errors.to_ash_error(error)}
    end
  end

  @doc """
  Upserts a record.

  XTDB INSERT is naturally an upsert based on _id, so this delegates to create.
  """
  @spec upsert(Ash.Resource.t(), Ash.Changeset.t(), list(atom())) ::
          {:ok, struct()} | {:error, term()}
  def upsert(resource, changeset, _keys) do
    # XTDB INSERT is naturally an upsert based on _id
    create(resource, changeset)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp primary_key_value(record, resource) do
    pkey_attrs = Ash.Resource.Info.primary_key(resource)

    Map.new(pkey_attrs, fn attr ->
      {attr, Map.get(record, attr)}
    end)
  end
end
