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
    # Build SET clause for regular changes
    {set_clauses, set_params, next_idx} =
      changes
      |> Map.to_list()
      |> Enum.reduce({[], [], 1}, fn {col, val}, {clauses, params, idx} ->
        clause = "#{Core.to_insert_column_name(col)} = $#{idx}"
        {[clause | clauses], [val | params], idx + 1}
      end)

    # Build SET clause for atomic updates (expressions)
    quoted_table = Core.quote_identifier(table)

    {atomic_clauses, atomic_params, next_idx} =
      atomics
      |> Enum.reduce({[], [], next_idx}, fn {col, expr}, {clauses, params, idx} ->
        {expr_sql, expr_params, new_idx} =
          atomic_expression_to_sql(expr, resource, quoted_table, idx)

        clause = "#{Core.to_insert_column_name(col)} = #{expr_sql}"
        {[clause | clauses], params ++ expr_params, new_idx}
      end)

    # Combine all SET clauses
    all_clauses = Enum.reverse(set_clauses) ++ Enum.reverse(atomic_clauses)
    set_clause = Enum.join(all_clauses, ", ")
    all_set_params = Enum.reverse(set_params) ++ atomic_params

    # Build WHERE clause for primary key
    pkey_attr = Ash.Resource.Info.primary_key(resource) |> List.first()
    pkey_value = Map.get(pkey, pkey_attr)

    # XTDB requires fully-qualified column in WHERE
    where_clause = "#{quoted_table}.\"_id\" = $#{next_idx}"
    where_params = [pkey_value]

    sql = "UPDATE #{quoted_table} SET #{set_clause} WHERE #{where_clause}"
    params = all_set_params ++ where_params

    {sql, params}
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
    # Build SET clause
    {set_clauses, set_params, next_idx} =
      changes
      |> Map.to_list()
      |> Enum.reduce({[], [], 1}, fn {col, val}, {clauses, params, idx} ->
        clause = "#{Core.to_insert_column_name(col)} = $#{idx}"
        {[clause | clauses], [val | params], idx + 1}
      end)

    set_clause = set_clauses |> Enum.reverse() |> Enum.join(", ")
    set_params = Enum.reverse(set_params)

    # Build WHERE clause for primary key
    pkey_attr = Ash.Resource.Info.primary_key(resource) |> List.first()
    pkey_value = Map.get(pkey, pkey_attr)
    quoted_table = Core.quote_identifier(table)
    where_clause = "#{quoted_table}.\"_id\" = $#{next_idx}"
    where_params = [pkey_value]

    # Build FOR PORTION OF clause
    portion_clause = Temporal.build_portion_of_clause(from, to)

    sql = "UPDATE #{quoted_table} #{portion_clause} SET #{set_clause} WHERE #{where_clause}"
    params = set_params ++ where_params

    {sql, params}
  end

  @doc """
  Builds an UPDATE statement with WHERE clause from a query filter.

  Supports both regular changes and atomic updates (expressions evaluated in SQL).
  Used for bulk update operations.
  """
  @spec build_update_query(String.t(), map(), list(), map(), Ash.Resource.t()) ::
          {String.t(), list()}
  def build_update_query(table, changes, atomics, query, resource) do
    # Build SET clause for regular changes
    {set_clauses, set_params, next_idx} =
      changes
      |> Map.to_list()
      |> Enum.reduce({[], [], 1}, fn {col, val}, {clauses, params, idx} ->
        clause = "#{Core.to_insert_column_name(col)} = $#{idx}"
        {[clause | clauses], [val | params], idx + 1}
      end)

    # Build SET clause for atomic updates (expressions)
    {atomic_clauses, atomic_params, next_idx} =
      atomics
      |> Enum.reduce({[], [], next_idx}, fn {col, expr}, {clauses, params, idx} ->
        {expr_sql, expr_params, new_idx} = atomic_expression_to_sql(expr, resource, table, idx)
        clause = "#{Core.to_insert_column_name(col)} = #{expr_sql}"
        {[clause | clauses], params ++ expr_params, new_idx}
      end)

    # Combine all SET clauses
    all_clauses = Enum.reverse(set_clauses) ++ Enum.reverse(atomic_clauses)
    set_clause = Enum.join(all_clauses, ", ")
    all_set_params = Enum.reverse(set_params) ++ atomic_params

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

    quoted_table = Core.quote_identifier(table)

    sql =
      if where_clause do
        "UPDATE #{quoted_table} SET #{set_clause} #{where_clause}"
      else
        "UPDATE #{quoted_table} SET #{set_clause}"
      end

    {sql, all_set_params ++ where_params}
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

    # Return the SQL, parameters, and next parameter index
    {sql, Enum.reverse(final_state.params), final_state.param_idx}
  end
end
