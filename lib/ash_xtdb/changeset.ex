# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Changeset do
  @moduledoc """
  Changeset helpers for XTDB's bitemporal capabilities.

  These functions allow you to control the valid time of records when
  creating or updating them.

  ## Examples

      # Insert with specific valid time range
      User
      |> Ash.Changeset.for_create(:create, attrs)
      |> AshXTDB.Changeset.with_valid_from(~U[2024-01-01 00:00:00Z])
      |> Ash.create!()

      # Update for a specific portion of valid time
      user
      |> Ash.Changeset.for_update(:update, %{status: "inactive"})
      |> AshXTDB.Changeset.for_portion_of_valid_time(
        ~U[2024-01-01 00:00:00Z],
        ~U[2024-06-30 23:59:59Z]
      )
      |> Ash.update!()

  ## GDPR Compliance (ERASE)

      # Permanently erase a record from all history
      user
      |> AshXTDB.Changeset.erase!()
  """

  # ============================================================================
  # Valid Time Helpers
  # ============================================================================

  @doc """
  Set the valid-from timestamp for a changeset.

  The record will be valid from this timestamp until the end of time
  (or until a valid_to is also specified).

  ## Example

      User
      |> Ash.Changeset.for_create(:create, attrs)
      |> AshXTDB.Changeset.with_valid_from(~U[2024-01-01 00:00:00Z])
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
      |> AshXTDB.Changeset.with_valid_to(~U[2024-12-31 23:59:59Z])
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
      |> AshXTDB.Changeset.with_valid_time(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
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
      |> AshXTDB.Changeset.for_portion_of_valid_time(
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
      |> AshXTDB.Changeset.setting_valid_time(
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
      |> AshXTDB.Changeset.setting_valid_from(~U[2024-06-01 00:00:00Z])
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
      |> AshXTDB.Changeset.erase!()
  """
  @spec erase!(Ash.Resource.record()) :: :ok
  def erase!(record) do
    resource = record.__struct__
    repo = AshXTDB.DataLayer.Info.repo!(resource)
    table = AshXTDB.DataLayer.Info.table!(resource)

    pkey_attr = Ash.Resource.Info.primary_key(resource) |> List.first()
    pkey_value = Map.get(record, pkey_attr)

    quoted_table = AshXTDB.SQL.quote_identifier(table)
    sql = "ERASE FROM #{quoted_table} WHERE #{quoted_table}.\"_id\" = $1"
    inlined_sql = AshXTDB.SQL.inline_params(sql, [pkey_value])

    case repo.query(inlined_sql, []) do
      {:ok, _} -> :ok
      {:error, error} -> raise Ash.Error.to_ash_error(error)
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp put_changeset_temporal(changeset, key, value) do
    context = changeset.context || %{}
    temporal = Map.get(context, :temporal, %{})
    temporal = Map.put(temporal, key, value)
    Ash.Changeset.set_context(changeset, %{temporal: temporal})
  end
end
