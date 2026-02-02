# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Temporal do
  @moduledoc """
  Temporal query and mutation helpers for XTDB's bitemporal capabilities.

  XTDB maintains two temporal dimensions for every record:

  - **Valid Time** (Application Time): When the data is valid in the real world.
    User-controlled and can represent past, present, or future states.

  - **System Time** (Transaction Time): When the data was recorded in the database.
    Automatically maintained by XTDB for audit purposes.

  ## Query Examples

      # Query data as it was valid on a specific date
      User
      |> AshXTDB.Temporal.as_of_valid_time(~U[2024-01-01 00:00:00Z])
      |> Ash.read!()

      # Query the complete history of all changes
      User
      |> AshXTDB.Temporal.for_all_valid_time()
      |> Ash.read!()

      # Query data as the system knew it at a specific point
      User
      |> AshXTDB.Temporal.as_of_system_time(~U[2024-01-01 00:00:00Z])
      |> Ash.read!()

      # Combine both dimensions
      User
      |> AshXTDB.Temporal.as_of_valid_time(~U[2024-06-01 00:00:00Z])
      |> AshXTDB.Temporal.as_of_system_time(~U[2024-01-01 00:00:00Z])
      |> Ash.read!()

  ## Mutation Examples

      # Insert with specific valid time range
      User
      |> Ash.Changeset.for_create(:create, attrs)
      |> AshXTDB.Temporal.with_valid_from(~U[2024-01-01 00:00:00Z])
      |> Ash.create!()

  ## GDPR Compliance (ERASE)

      # Permanently erase a record from all history
      user
      |> AshXTDB.Temporal.erase!()
  """

  @type temporal_option ::
          {:valid_time, :all | {:as_of, DateTime.t()} | {:between, DateTime.t(), DateTime.t()}}
          | {:system_time, :all | {:as_of, DateTime.t()} | {:between, DateTime.t(), DateTime.t()}}

  # ============================================================================
  # Query Helpers - Valid Time
  # ============================================================================

  @doc """
  Query data as it was valid at a specific point in time.

  ## Example

      User
      |> AshXTDB.Temporal.as_of_valid_time(~U[2024-01-01 00:00:00Z])
      |> Ash.read!()

  Generates SQL: `SELECT ... FROM users FOR VALID_TIME AS OF TIMESTAMP '...'`
  """
  @spec as_of_valid_time(Ash.Query.t() | Ash.Resource.t(), DateTime.t()) :: Ash.Query.t()
  def as_of_valid_time(resource_or_query, %DateTime{} = timestamp) do
    put_temporal_context(resource_or_query, :valid_time, {:as_of, timestamp})
  end

  @doc """
  Query the complete valid-time history of records.

  ## Example

      User
      |> AshXTDB.Temporal.for_all_valid_time()
      |> Ash.read!()

  Generates SQL: `SELECT ... FROM users FOR ALL VALID_TIME`
  """
  @spec for_all_valid_time(Ash.Query.t() | Ash.Resource.t()) :: Ash.Query.t()
  def for_all_valid_time(resource_or_query) do
    put_temporal_context(resource_or_query, :valid_time, :all)
  end

  @doc """
  Query data valid within a time range.

  ## Example

      User
      |> AshXTDB.Temporal.for_valid_time_between(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
      |> Ash.read!()

  Generates SQL: `SELECT ... FROM users FOR VALID_TIME BETWEEN TIMESTAMP '...' AND TIMESTAMP '...'`
  """
  @spec for_valid_time_between(Ash.Query.t() | Ash.Resource.t(), DateTime.t(), DateTime.t()) ::
          Ash.Query.t()
  def for_valid_time_between(resource_or_query, %DateTime{} = from, %DateTime{} = to) do
    put_temporal_context(resource_or_query, :valid_time, {:between, from, to})
  end

  # ============================================================================
  # Query Helpers - System Time
  # ============================================================================

  @doc """
  Query data as the system knew it at a specific point in time.

  Useful for auditing - see what the database looked like at a given moment.

  ## Example

      User
      |> AshXTDB.Temporal.as_of_system_time(~U[2024-01-01 00:00:00Z])
      |> Ash.read!()

  Generates SQL: `SELECT ... FROM users FOR SYSTEM_TIME AS OF TIMESTAMP '...'`
  """
  @spec as_of_system_time(Ash.Query.t() | Ash.Resource.t(), DateTime.t()) :: Ash.Query.t()
  def as_of_system_time(resource_or_query, %DateTime{} = timestamp) do
    put_temporal_context(resource_or_query, :system_time, {:as_of, timestamp})
  end

  @doc """
  Query the complete system-time history (audit log) of records.

  ## Example

      User
      |> AshXTDB.Temporal.for_all_system_time()
      |> Ash.read!()

  Generates SQL: `SELECT ... FROM users FOR ALL SYSTEM_TIME`
  """
  @spec for_all_system_time(Ash.Query.t() | Ash.Resource.t()) :: Ash.Query.t()
  def for_all_system_time(resource_or_query) do
    put_temporal_context(resource_or_query, :system_time, :all)
  end

  @doc """
  Query system-time history within a range.

  ## Example

      User
      |> AshXTDB.Temporal.for_system_time_between(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
      |> Ash.read!()
  """
  @spec for_system_time_between(Ash.Query.t() | Ash.Resource.t(), DateTime.t(), DateTime.t()) ::
          Ash.Query.t()
  def for_system_time_between(resource_or_query, %DateTime{} = from, %DateTime{} = to) do
    put_temporal_context(resource_or_query, :system_time, {:between, from, to})
  end

  # ============================================================================
  # Mutation Helpers
  # ============================================================================

  @doc """
  Set the valid-from timestamp for a changeset.

  The record will be valid from this timestamp until the end of time
  (or until a valid_to is also specified).

  ## Example

      User
      |> Ash.Changeset.for_create(:create, attrs)
      |> AshXTDB.Temporal.with_valid_from(~U[2024-01-01 00:00:00Z])
      |> Ash.create!()
  """
  @spec with_valid_from(Ash.Changeset.t(), DateTime.t()) :: Ash.Changeset.t()
  def with_valid_from(changeset, %DateTime{} = timestamp) do
    put_changeset_temporal(changeset, :valid_from, timestamp)
  end

  @doc """
  Set the valid-to timestamp for a changeset.

  The record will be valid until this timestamp.

  ## Example

      User
      |> Ash.Changeset.for_create(:create, attrs)
      |> AshXTDB.Temporal.with_valid_to(~U[2024-12-31 23:59:59Z])
      |> Ash.create!()
  """
  @spec with_valid_to(Ash.Changeset.t(), DateTime.t()) :: Ash.Changeset.t()
  def with_valid_to(changeset, %DateTime{} = timestamp) do
    put_changeset_temporal(changeset, :valid_to, timestamp)
  end

  @doc """
  Set both valid-from and valid-to timestamps for a changeset.

  ## Example

      User
      |> Ash.Changeset.for_create(:create, attrs)
      |> AshXTDB.Temporal.with_valid_time(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
      |> Ash.create!()
  """
  @spec with_valid_time(Ash.Changeset.t(), DateTime.t(), DateTime.t()) :: Ash.Changeset.t()
  def with_valid_time(changeset, %DateTime{} = from, %DateTime{} = to) do
    changeset
    |> with_valid_from(from)
    |> with_valid_to(to)
  end

  # ============================================================================
  # FOR PORTION OF VALID_TIME - Partial Period Updates
  # ============================================================================

  @doc """
  Apply an update to only a portion of the valid time period.

  This allows updating a record for a specific time range without affecting
  the record outside that range. XTDB will automatically create separate
  versions for the affected and unaffected time periods.

  ## Example

      # Update user status to "inactive" only for the first half of 2024
      user
      |> Ash.Changeset.for_update(:update, %{status: "inactive"})
      |> AshXTDB.Temporal.for_portion_of_valid_time(
        ~U[2024-01-01 00:00:00Z],
        ~U[2024-06-30 23:59:59Z]
      )
      |> Ash.update!()

  Generates SQL: `UPDATE ... FOR PORTION OF VALID_TIME FROM TIMESTAMP '...' TO TIMESTAMP '...'`
  """
  @spec for_portion_of_valid_time(Ash.Changeset.t(), DateTime.t(), DateTime.t()) ::
          Ash.Changeset.t()
  def for_portion_of_valid_time(changeset, %DateTime{} = from, %DateTime{} = to) do
    put_changeset_temporal(changeset, :portion_of_valid_time, {from, to})
  end

  # ============================================================================
  # SETTING Clauses - Explicit Valid Time on Insert/Update
  # ============================================================================

  @doc """
  Set the valid time period for an insert or update using SETTING clause.

  Unlike `with_valid_from/to` which may be limited, this uses XTDB's SETTING
  syntax for explicit valid time control.

  ## Example

      # Insert a record that was valid only in 2023
      User
      |> Ash.Changeset.for_create(:create, attrs)
      |> AshXTDB.Temporal.setting_valid_time(
        ~U[2023-01-01 00:00:00Z],
        ~U[2023-12-31 23:59:59Z]
      )
      |> Ash.create!()

  Generates SQL: `INSERT INTO ... (...) VALUES (...) SETTING VALID_TIME = PERIOD(...)`
  """
  @spec setting_valid_time(Ash.Changeset.t(), DateTime.t(), DateTime.t()) :: Ash.Changeset.t()
  def setting_valid_time(changeset, %DateTime{} = from, %DateTime{} = to) do
    put_changeset_temporal(changeset, :setting_valid_time, {from, to})
  end

  @doc """
  Set only the start of the valid time period (valid from now until end of time).

  ## Example

      # Record becomes valid starting from a specific date
      User
      |> Ash.Changeset.for_create(:create, attrs)
      |> AshXTDB.Temporal.setting_valid_from(~U[2024-06-01 00:00:00Z])
      |> Ash.create!()
  """
  @spec setting_valid_from(Ash.Changeset.t(), DateTime.t()) :: Ash.Changeset.t()
  def setting_valid_from(changeset, %DateTime{} = from) do
    put_changeset_temporal(changeset, :setting_valid_from, from)
  end

  # ============================================================================
  # GDPR Compliance - ERASE
  # ============================================================================

  @doc """
  Permanently erase a record from all history (GDPR right to be forgotten).

  Unlike normal DELETE which creates a tombstone, ERASE removes the record
  from all system-time and valid-time history as if it never existed.

  **WARNING**: This is irreversible and removes all audit history.

  ## Example

      user
      |> AshXTDB.Temporal.erase!()
  """
  @spec erase!(Ash.Resource.record()) :: :ok
  def erase!(record) do
    resource = record.__struct__
    repo = AshXTDB.DataLayer.Info.repo!(resource)
    table = AshXTDB.DataLayer.Info.table!(resource)

    pkey_attr = Ash.Resource.Info.primary_key(resource) |> List.first()
    pkey_value = Map.get(record, pkey_attr)

    quoted_table = AshXTDB.Query.quote_identifier(table)
    sql = "ERASE FROM #{quoted_table} WHERE #{quoted_table}.\"_id\" = $1"
    inlined_sql = AshXTDB.Query.inline_params(sql, [pkey_value])

    case repo.query(inlined_sql, []) do
      {:ok, _} -> :ok
      {:error, error} -> raise Ash.Error.to_ash_error(error)
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp put_temporal_context(resource_or_query, key, value) do
    query = ensure_query(resource_or_query)
    context = query.context || %{}
    temporal = Map.get(context, :temporal, %{})
    temporal = Map.put(temporal, key, value)
    Ash.Query.set_context(query, %{temporal: temporal})
  end

  defp ensure_query(%Ash.Query{} = query), do: query
  defp ensure_query(resource) when is_atom(resource), do: Ash.Query.new(resource)

  defp put_changeset_temporal(changeset, key, value) do
    context = changeset.context || %{}
    temporal = Map.get(context, :temporal, %{})
    temporal = Map.put(temporal, key, value)
    Ash.Changeset.set_context(changeset, %{temporal: temporal})
  end
end
