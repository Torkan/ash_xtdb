# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.DML.Delete do
  @moduledoc """
  SQL DELETE statement generation for XTDB.

  Provides functions to build DELETE statements including:
  - Simple deletes by primary key
  - Bulk deletes via WHERE clause (destroy_query)
  - Temporal deletes with FOR PORTION OF VALID_TIME

  ## XTDB-Specific Considerations

  - XTDB requires fully-qualified column names in WHERE clause
  - XTDB does not support table aliases in DELETE statements
  """

  alias AshXTDB.SQL.Core
  alias AshXTDB.SQL.Filter
  alias AshXTDB.SQL.Temporal

  @doc """
  Builds a DELETE statement for a single record by primary key.
  """
  @spec build_delete(String.t(), map(), Ash.Resource.t()) :: {String.t(), list()}
  def build_delete(table, pkey, resource) do
    pkey_attr = Ash.Resource.Info.primary_key(resource) |> List.first()
    pkey_value = Map.get(pkey, pkey_attr)

    # XTDB requires fully-qualified column in WHERE
    quoted_table = Core.quote_identifier(table)
    sql = "DELETE FROM #{quoted_table} WHERE #{quoted_table}.\"_id\" = $1"

    {sql, [pkey_value]}
  end

  @doc """
  Builds a DELETE statement with FOR PORTION OF VALID_TIME clause.

  This allows deleting a record for only a portion of its valid time range.
  XTDB will keep the record versions outside the specified time range.

  ## Example SQL

      DELETE FROM users FOR PORTION OF VALID_TIME
      FROM TIMESTAMP '2024-01-01T00:00:00Z' TO TIMESTAMP '2024-06-30T23:59:59Z'
      WHERE users."_id" = $1
  """
  @spec build_delete_for_portion(String.t(), map(), Ash.Resource.t(), DateTime.t(), DateTime.t()) ::
          {String.t(), list()}
  def build_delete_for_portion(table, pkey, resource, %DateTime{} = from, %DateTime{} = to) do
    pkey_attr = Ash.Resource.Info.primary_key(resource) |> List.first()
    pkey_value = Map.get(pkey, pkey_attr)

    portion_clause = Temporal.build_portion_of_clause(from, to)

    quoted_table = Core.quote_identifier(table)
    sql = "DELETE FROM #{quoted_table} #{portion_clause} WHERE #{quoted_table}.\"_id\" = $1"

    {sql, [pkey_value]}
  end

  @doc """
  Builds a DELETE statement with WHERE clause from a query filter.

  Used for bulk delete operations.
  """
  @spec build_destroy_query(String.t(), map(), Ash.Resource.t()) :: {String.t(), list()}
  def build_destroy_query(table, query, resource) do
    # Build WHERE clause from filter
    # Use table name (not alias) for DELETE statements since XTDB doesn't support aliases in DELETE
    {where_clause, where_params} =
      case query.filter do
        nil ->
          {nil, []}

        filter ->
          {where_sql, filter_params, _joins} = Filter.to_sql(filter, resource, table, 1, table)
          {where_sql, filter_params}
      end

    quoted_table = Core.quote_identifier(table)

    sql =
      if where_clause do
        "DELETE FROM #{quoted_table} #{where_clause}"
      else
        "DELETE FROM #{quoted_table}"
      end

    {sql, where_params}
  end
end
