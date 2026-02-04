# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.Aggregate do
  @moduledoc """
  SQL aggregate function generation for XTDB.

  Generates SQL for various aggregate functions:
  - Basic: COUNT, SUM, AVG, MIN, MAX
  - Boolean: BOOL_AND, BOOL_OR
  - Statistical: STDDEV_POP, STDDEV_SAMP, VAR_POP, VAR_SAMP
  - Special: EXISTS (as COUNT(*) > 0), FIRST (as MIN), LIST (as ARRAY_AGG)

  ## Usage

  Typically used through `AshXTDB.SQL.to_aggregate_sql/2` which builds a
  complete aggregate query from a Query struct and list of aggregates.
  """

  alias AshXTDB.SQL.Core

  @table_alias "t"

  @doc """
  Builds the SELECT clause for aggregate functions.

  Returns a SQL SELECT clause string with all aggregates.
  """
  @spec build_aggregate_select(list(map())) :: String.t()
  def build_aggregate_select(aggregates) do
    clauses =
      Enum.map_join(aggregates, ", ", fn agg ->
        sql_func = aggregate_to_sql(agg)
        # Quote the alias to handle reserved words like 'exists'
        "#{sql_func} AS \"#{agg.name}\""
      end)

    "SELECT #{clauses}"
  end

  @doc """
  Converts a single aggregate definition to SQL.

  ## Examples

      iex> aggregate_to_sql(%{kind: :count, field: nil})
      "COUNT(*)"

      iex> aggregate_to_sql(%{kind: :sum, field: :amount})
      "SUM(t.amount)"
  """
  @spec aggregate_to_sql(map()) :: String.t()
  def aggregate_to_sql(%{kind: :count, field: nil}) do
    "COUNT(*)"
  end

  def aggregate_to_sql(%{kind: :count, field: field, uniq?: true}) do
    "COUNT(DISTINCT #{@table_alias}.#{Core.field_to_column(field)})"
  end

  def aggregate_to_sql(%{kind: :count, field: field}) do
    "COUNT(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  def aggregate_to_sql(%{kind: :sum, field: field}) do
    "SUM(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  def aggregate_to_sql(%{kind: :avg, field: field}) do
    "AVG(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  def aggregate_to_sql(%{kind: :min, field: field}) do
    "MIN(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  def aggregate_to_sql(%{kind: :max, field: field}) do
    "MAX(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  def aggregate_to_sql(%{kind: :exists}) do
    # EXISTS returns boolean based on whether any rows exist
    "COUNT(*) > 0"
  end

  def aggregate_to_sql(%{kind: :first, field: field}) do
    # XTDB may not support this directly, use MIN as approximation
    "MIN(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  def aggregate_to_sql(%{kind: :list, field: field}) do
    # XTDB may support ARRAY_AGG
    "ARRAY_AGG(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  # Statistical aggregates
  def aggregate_to_sql(%{kind: :stddev_pop, field: field}) do
    "STDDEV_POP(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  def aggregate_to_sql(%{kind: :stddev_samp, field: field}) do
    "STDDEV_SAMP(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  def aggregate_to_sql(%{kind: :var_pop, field: field}) do
    "VAR_POP(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  def aggregate_to_sql(%{kind: :var_samp, field: field}) do
    "VAR_SAMP(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  # Boolean aggregates
  def aggregate_to_sql(%{kind: :bool_and, field: field}) do
    "BOOL_AND(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  def aggregate_to_sql(%{kind: :bool_or, field: field}) do
    "BOOL_OR(#{@table_alias}.#{Core.field_to_column(field)})"
  end

  @doc """
  Returns the default table alias used for aggregate queries.
  """
  @spec table_alias() :: String.t()
  def table_alias, do: @table_alias
end
