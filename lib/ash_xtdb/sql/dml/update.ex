# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.DML.Update do
  @moduledoc """
  SQL UPDATE statement generation for XTDB.

  Provides functions to build UPDATE statements including:
  - Simple updates by primary key
  - Updates with atomic expressions (e.g., counter = counter + 1)
  - Bulk updates via WHERE clause (update_query)
  - Temporal updates with FOR PORTION OF VALID_TIME

  ## Atomic Updates

  Atomic updates allow expressions that reference the current value:

      build_update("users", %{id: 1}, %{}, [{:counter, {:+, :counter, 1}}], resource)

  This generates SQL like:
      UPDATE users SET counter = users.counter + 1 WHERE users."_id" = $1

  ## XTDB-Specific Considerations

  - XTDB requires fully-qualified column names in WHERE clause
  - XTDB does not support table aliases in UPDATE statements
  """

  alias AshXTDB.SQL.Core
  alias AshXTDB.SQL.Filter
  alias AshXTDB.SQL.Temporal

  @doc """
  Builds an UPDATE statement.

  Supports both regular changes and atomic updates (expressions evaluated in SQL).
  """
  @spec build_update(String.t(), map(), map(), list(), Ash.Resource.t()) :: {String.t(), list()}
  def build_update(table, pkey, changes, atomics, resource) do
    quoted_table = Core.quote_identifier(table)

    {set_clause, set_params, next_idx} =
      build_full_set_clause(changes, atomics, resource, quoted_table)

    {where_clause, where_params} = Core.build_pkey_where(quoted_table, pkey, resource, next_idx)

    sql = "UPDATE #{quoted_table} SET #{set_clause} WHERE #{where_clause}"
    {sql, set_params ++ where_params}
  end

  @doc """
  Builds an UPDATE statement with FOR PORTION OF VALID_TIME clause.

  This allows updating a record for only a portion of its valid time range.
  XTDB will automatically create separate versions for the affected and
  unaffected time periods.

  ## Example SQL

      UPDATE users FOR PORTION OF VALID_TIME
      FROM TIMESTAMP '2024-01-01T00:00:00Z' TO TIMESTAMP '2024-06-30T23:59:59Z'
      SET status = $1
      WHERE users."_id" = $2
  """
  @spec build_update_for_portion(
          String.t(),
          map(),
          map(),
          Ash.Resource.t(),
          DateTime.t(),
          DateTime.t()
        ) :: {String.t(), list()}
  def build_update_for_portion(
        table,
        pkey,
        changes,
        resource,
        %DateTime{} = from,
        %DateTime{} = to
      ) do
    {set_clauses, set_params, next_idx} = build_set_clauses(changes)

    set_clause = set_clauses |> Enum.reverse() |> Enum.join(", ")
    set_params = Enum.reverse(set_params)

    quoted_table = Core.quote_identifier(table)
    {where_clause, where_params} = Core.build_pkey_where(quoted_table, pkey, resource, next_idx)
    portion_clause = Temporal.build_portion_of_clause(from, to)

    sql = "UPDATE #{quoted_table} #{portion_clause} SET #{set_clause} WHERE #{where_clause}"
    {sql, set_params ++ where_params}
  end

  @doc """
  Builds an UPDATE statement with WHERE clause from a query filter.

  Supports both regular changes and atomic updates (expressions evaluated in SQL).
  Used for bulk update operations.
  """
  @spec build_update_query(String.t(), map(), list(), map(), Ash.Resource.t()) ::
          {String.t(), list()}
  def build_update_query(table, changes, atomics, query, resource) do
    quoted_table = Core.quote_identifier(table)

    {set_clause, set_params, next_idx} =
      build_full_set_clause(changes, atomics, resource, table)

    # Build WHERE clause from filter
    # Use table name (not alias) for UPDATE statements since XTDB doesn't support aliases in UPDATE
    {where_clause, where_params} =
      case query.filter do
        nil ->
          {nil, []}

        filter ->
          {where_sql, filter_params, _joins} =
            Filter.to_sql(filter, resource, table, next_idx, table)

          {where_sql, filter_params}
      end

    sql =
      if where_clause do
        "UPDATE #{quoted_table} SET #{set_clause} #{where_clause}"
      else
        "UPDATE #{quoted_table} SET #{set_clause}"
      end

    {sql, set_params ++ where_params}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Builds SET clauses from a changes map. Returns {clauses, params, next_idx}.
  defp build_set_clauses(changes, start_idx \\ 1) do
    changes
    |> Map.to_list()
    |> Enum.reduce({[], [], start_idx}, fn {col, val}, {clauses, params, idx} ->
      clause = "#{Core.to_insert_column_name(col)} = $#{idx}"
      {[clause | clauses], [val | params], idx + 1}
    end)
  end

  # Builds a combined SET clause from both regular changes and atomic expressions.
  # Returns {set_clause_string, all_params, next_idx}.
  defp build_full_set_clause(changes, atomics, resource, table_ref) do
    {set_clauses, set_params, next_idx} = build_set_clauses(changes)

    {atomic_clauses, atomic_params, next_idx} =
      Enum.reduce(atomics, {[], [], next_idx}, fn {col, expr}, {clauses, params, idx} ->
        {expr_sql, expr_params, new_idx} =
          atomic_expression_to_sql(expr, resource, table_ref, idx)

        clause = "#{Core.to_insert_column_name(col)} = #{expr_sql}"
        {[clause | clauses], params ++ expr_params, new_idx}
      end)

    all_clauses = Enum.reverse(set_clauses) ++ Enum.reverse(atomic_clauses)
    set_clause = Enum.join(all_clauses, ", ")
    all_params = Enum.reverse(set_params) ++ atomic_params

    {set_clause, all_params, next_idx}
  end

  # Convert an atomic expression to SQL for use in UPDATE SET clause
  defp atomic_expression_to_sql(expr, resource, table, start_idx) do
    state = %{
      resource: resource,
      param_idx: start_idx,
      params: [],
      joins: %{},
      join_counter: 0,
      table_alias: table
    }

    {sql, final_state} = Filter.expression_to_sql(expr, state)

    {sql, Enum.reverse(final_state.params), final_state.param_idx}
  end
end
