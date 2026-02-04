# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Query do
  @moduledoc """
  Query helpers for XTDB's bitemporal capabilities.

  XTDB maintains two temporal dimensions for every record:

  - **Valid Time** (Application Time): When the data is valid in the real world.
    User-controlled and can represent past, present, or future states.

  - **System Time** (Transaction Time): When the data was recorded in the database.
    Automatically maintained by XTDB for audit purposes.

  ## Examples

      # Query data as it was valid on a specific date
      User
      |> AshXTDB.Query.as_of_valid_time(~U[2024-01-01 00:00:00Z])
      |> Ash.read!()

      # Query the complete history of all changes
      User
      |> AshXTDB.Query.for_all_valid_time()
      |> Ash.read!()

      # Query data as the system knew it at a specific point
      User
      |> AshXTDB.Query.as_of_system_time(~U[2024-01-01 00:00:00Z])
      |> Ash.read!()

      # Combine both dimensions
      User
      |> AshXTDB.Query.as_of_valid_time(~U[2024-06-01 00:00:00Z])
      |> AshXTDB.Query.as_of_system_time(~U[2024-01-01 00:00:00Z])
      |> Ash.read!()
  """

  @type temporal_option ::
          {:valid_time, :all | {:as_of, DateTime.t()} | {:between, DateTime.t(), DateTime.t()}}
          | {:system_time, :all | {:as_of, DateTime.t()} | {:between, DateTime.t(), DateTime.t()}}

  # ============================================================================
  # Valid Time Helpers
  # ============================================================================

  @doc """
  Query data as it was valid at a specific point in time.

  ## Example

      User
      |> AshXTDB.Query.as_of_valid_time(~U[2024-01-01 00:00:00Z])
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
      |> AshXTDB.Query.for_all_valid_time()
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
      |> AshXTDB.Query.for_valid_time_between(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
      |> Ash.read!()

  Generates SQL: `SELECT ... FROM users FOR VALID_TIME BETWEEN TIMESTAMP '...' AND TIMESTAMP '...'`
  """
  @spec for_valid_time_between(Ash.Query.t() | Ash.Resource.t(), DateTime.t(), DateTime.t()) ::
          Ash.Query.t()
  def for_valid_time_between(resource_or_query, %DateTime{} = from, %DateTime{} = to) do
    put_temporal_context(resource_or_query, :valid_time, {:between, from, to})
  end

  # ============================================================================
  # System Time Helpers
  # ============================================================================

  @doc """
  Query data as the system knew it at a specific point in time.

  Useful for auditing - see what the database looked like at a given moment.

  ## Example

      User
      |> AshXTDB.Query.as_of_system_time(~U[2024-01-01 00:00:00Z])
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
      |> AshXTDB.Query.for_all_system_time()
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
      |> AshXTDB.Query.for_system_time_between(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
      |> Ash.read!()
  """
  @spec for_system_time_between(Ash.Query.t() | Ash.Resource.t(), DateTime.t(), DateTime.t()) ::
          Ash.Query.t()
  def for_system_time_between(resource_or_query, %DateTime{} = from, %DateTime{} = to) do
    put_temporal_context(resource_or_query, :system_time, {:between, from, to})
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
end
