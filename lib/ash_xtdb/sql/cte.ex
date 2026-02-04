# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.CTE do
  @moduledoc """
  SQL Common Table Expression (CTE) and set operation generation for XTDB.

  ## CTEs (WITH clauses)

  CTEs allow defining reusable subqueries:

      WITH active_users AS (
        SELECT * FROM users WHERE status = 'active'
      )
      SELECT * FROM active_users WHERE created_at > '2024-01-01'

  ## Set Operations

  Supports combining queries with:
  - UNION - Combines distinct results
  - UNION ALL - Combines all results including duplicates
  - INTERSECT - Returns common results
  - EXCEPT - Returns results in first query but not in second
  """

  @doc """
  Builds the WITH clause for CTEs.

  Returns nil if there are no CTEs, otherwise returns a WITH clause string.

  ## Parameters

  - `ctes` - List of `%{name: String.t(), query: AshXTDB.SQL.t()}` maps
  - `to_sql_fn` - Function to convert query to SQL `(query -> {sql, params})`

  ## Example

      iex> build_cte_clause([%{name: "active", query: query}], &to_sql/1)
      "WITH active AS (SELECT ...)"
  """
  @spec build_cte_clause(list(map()) | nil, (map() -> {String.t(), list()})) :: String.t() | nil
  def build_cte_clause([], _to_sql_fn), do: nil
  def build_cte_clause(nil, _to_sql_fn), do: nil

  def build_cte_clause(ctes, to_sql_fn) do
    cte_sql =
      Enum.map_join(ctes, ", ", fn %{name: name, query: query} ->
        {subquery, _params} = to_sql_fn.(query)
        "#{name} AS (#{subquery})"
      end)

    "WITH #{cte_sql}"
  end

  @doc """
  Builds a set operation clause (UNION, INTERSECT, EXCEPT).

  Returns nil if there's no set operation.

  ## Parameters

  - `set_operation` - Tuple of `{:union | :union_all | :intersect | :except, query}`
  - `to_sql_fn` - Function to convert query to SQL

  ## Examples

      iex> build_set_operation({:union, query}, &to_sql/1)
      "UNION SELECT ..."

      iex> build_set_operation({:union_all, query}, &to_sql/1)
      "UNION ALL SELECT ..."
  """
  @spec build_set_operation(tuple() | nil, (map() -> {String.t(), list()})) :: String.t() | nil
  def build_set_operation(nil, _to_sql_fn), do: nil

  def build_set_operation({:union, query}, to_sql_fn) do
    {subquery, _params} = to_sql_fn.(query)
    "UNION #{subquery}"
  end

  def build_set_operation({:union_all, query}, to_sql_fn) do
    {subquery, _params} = to_sql_fn.(query)
    "UNION ALL #{subquery}"
  end

  def build_set_operation({:intersect, query}, to_sql_fn) do
    {subquery, _params} = to_sql_fn.(query)
    "INTERSECT #{subquery}"
  end

  def build_set_operation({:except, query}, to_sql_fn) do
    {subquery, _params} = to_sql_fn.(query)
    "EXCEPT #{subquery}"
  end
end
