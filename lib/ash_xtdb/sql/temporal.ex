# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.Temporal do
  @moduledoc """
  Temporal SQL clause generation for XTDB's bitemporal capabilities.

  XTDB maintains two temporal dimensions for every record:

  - **Valid Time** (Application Time): When the data is valid in the real world.
    User-controlled and can represent past, present, or future states.

  - **System Time** (Transaction Time): When the data was recorded in the database.
    Automatically maintained by XTDB for audit purposes.

  ## SQL Syntax

  XTDB uses standard SQL:2011 temporal syntax:

      -- Query at a specific point in time
      FROM users FOR VALID_TIME AS OF TIMESTAMP '2024-01-01T00:00:00Z' t

      -- Query all history
      FROM users FOR ALL VALID_TIME t

      -- Query a time range
      FROM users FOR VALID_TIME BETWEEN TIMESTAMP '...' AND TIMESTAMP '...' t

      -- Update for a portion of valid time
      UPDATE users FOR PORTION OF VALID_TIME FROM TIMESTAMP '...' TO TIMESTAMP '...'
      SET status = $1 WHERE users."_id" = $2
  """

  # ============================================================================
  # FROM Clause Temporal Modifiers
  # ============================================================================

  @doc """
  Builds a temporal clause for use in FROM clauses.

  ## Parameters

  - `type` - Either `"VALID_TIME"` or `"SYSTEM_TIME"`
  - `spec` - The temporal specification (see below)

  ## Temporal Specifications

  - `:all` - Query all history (`FOR ALL VALID_TIME`)
  - `{:as_of, DateTime.t()}` - Query at a specific point (`FOR VALID_TIME AS OF ...`)
  - `{:between, DateTime.t(), DateTime.t()}` - Query a range (`FOR VALID_TIME BETWEEN ... AND ...`)

  ## Examples

      iex> build_temporal_clause("VALID_TIME", :all)
      "FOR ALL VALID_TIME"

      iex> build_temporal_clause("VALID_TIME", {:as_of, ~U[2024-01-01 00:00:00Z]})
      "FOR VALID_TIME AS OF TIMESTAMP '2024-01-01T00:00:00Z'"

      iex> build_temporal_clause("SYSTEM_TIME", nil)
      nil
  """
  @spec build_temporal_clause(String.t(), term()) :: String.t() | nil
  def build_temporal_clause(_type, nil), do: nil

  def build_temporal_clause(type, :all) do
    "FOR ALL #{type}"
  end

  def build_temporal_clause(type, {:as_of, %DateTime{} = timestamp}) do
    "FOR #{type} AS OF TIMESTAMP '#{DateTime.to_iso8601(timestamp)}'"
  end

  def build_temporal_clause(type, {:between, %DateTime{} = from, %DateTime{} = to}) do
    "FOR #{type} BETWEEN TIMESTAMP '#{DateTime.to_iso8601(from)}' AND TIMESTAMP '#{DateTime.to_iso8601(to)}'"
  end

  # ============================================================================
  # DML Temporal Clauses
  # ============================================================================

  @doc """
  Builds a FOR PORTION OF VALID_TIME clause for UPDATE/DELETE statements.

  This allows updating or deleting a record for only a portion of its valid
  time range. XTDB will automatically create separate versions for the
  affected and unaffected time periods.

  ## Examples

      iex> build_portion_of_clause(~U[2024-01-01 00:00:00Z], ~U[2024-06-30 23:59:59Z])
      "FOR PORTION OF VALID_TIME FROM TIMESTAMP '2024-01-01T00:00:00Z' TO TIMESTAMP '2024-06-30T23:59:59Z'"
  """
  @spec build_portion_of_clause(DateTime.t(), DateTime.t()) :: String.t()
  def build_portion_of_clause(%DateTime{} = from, %DateTime{} = to) do
    "FOR PORTION OF VALID_TIME FROM TIMESTAMP '#{DateTime.to_iso8601(from)}' TO TIMESTAMP '#{DateTime.to_iso8601(to)}'"
  end

  @doc """
  Builds a valid time clause for PATCH statements.

  ## Parameters

  - `valid_from` - Start of valid time (optional)
  - `valid_to` - End of valid time (optional)

  ## Examples

      iex> build_valid_time_clause(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
      "FOR PORTION OF VALID_TIME FROM TIMESTAMP '2024-01-01T00:00:00Z' TO TIMESTAMP '2024-12-31T23:59:59Z'"

      iex> build_valid_time_clause(~U[2024-01-01 00:00:00Z], nil)
      "FOR PORTION OF VALID_TIME FROM TIMESTAMP '2024-01-01T00:00:00Z' TO END_OF_TIME()"

      iex> build_valid_time_clause(nil, nil)
      nil
  """
  @spec build_valid_time_clause(DateTime.t() | nil, DateTime.t() | nil) :: String.t() | nil
  def build_valid_time_clause(nil, nil), do: nil

  def build_valid_time_clause(%DateTime{} = from, %DateTime{} = to) do
    "FOR PORTION OF VALID_TIME FROM TIMESTAMP '#{DateTime.to_iso8601(from)}' TO TIMESTAMP '#{DateTime.to_iso8601(to)}'"
  end

  def build_valid_time_clause(%DateTime{} = from, nil) do
    # Only from specified - to end of time
    "FOR PORTION OF VALID_TIME FROM TIMESTAMP '#{DateTime.to_iso8601(from)}' TO END_OF_TIME()"
  end

  def build_valid_time_clause(nil, %DateTime{} = to) do
    # Only to specified - from now
    "FOR PORTION OF VALID_TIME FROM CURRENT_TIMESTAMP TO TIMESTAMP '#{DateTime.to_iso8601(to)}'"
  end

  # ============================================================================
  # Context Helpers
  # ============================================================================

  @doc """
  Extracts temporal configuration from a query context.

  Returns a map with `:valid_time` and/or `:system_time` keys.
  """
  @spec extract_temporal_context(map() | nil) :: map()
  def extract_temporal_context(nil), do: %{}
  def extract_temporal_context(context), do: Map.get(context, :temporal, %{})

  @doc """
  Builds both valid time and system time clauses from a context map.

  Returns a single string with all temporal clauses joined by space,
  or an empty string if no temporal clauses are needed.

  ## Example

      iex> context = %{temporal: %{valid_time: :all, system_time: {:as_of, ~U[2024-01-01 00:00:00Z]}}}
      iex> build_temporal_clauses_from_context(context)
      "FOR ALL VALID_TIME FOR SYSTEM_TIME AS OF TIMESTAMP '2024-01-01T00:00:00Z'"
  """
  @spec build_temporal_clauses_from_context(map() | nil) :: String.t()
  def build_temporal_clauses_from_context(context) do
    temporal = extract_temporal_context(context)

    valid_time_clause = build_temporal_clause("VALID_TIME", Map.get(temporal, :valid_time))
    system_time_clause = build_temporal_clause("SYSTEM_TIME", Map.get(temporal, :system_time))

    [valid_time_clause, system_time_clause]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end
end
