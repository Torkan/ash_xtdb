# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.Window do
  @moduledoc """
  SQL window function generation for XTDB.

  Generates SQL for window functions like:
  - Ranking: ROW_NUMBER, RANK, DENSE_RANK, NTILE
  - Value access: LAG, LEAD, FIRST_VALUE, LAST_VALUE
  - Aggregates as windows: SUM, AVG, MIN, MAX, COUNT

  ## Window Function Structure

  Window functions have:
  - `:name` - The result alias
  - `:function` - The window function (e.g., :row_number, :sum)
  - `:field` - The field to operate on (optional for some functions)
  - `:partition_by` - List of fields to partition by
  - `:order_by` - List of `{field, :asc | :desc}` tuples

  ## Examples

      %{
        name: :row_num,
        function: :row_number,
        partition_by: [:organization_id],
        order_by: [{:created_at, :desc}]
      }

      %{
        name: :running_total,
        function: :sum,
        field: :amount,
        order_by: [{:date, :asc}]
      }
  """

  @table_alias "t"

  @doc """
  Builds window function clauses for a SELECT statement.

  Returns nil if the list is empty, otherwise returns a comma-separated
  string of window function expressions.
  """
  @spec build_window_functions(list(map())) :: String.t() | nil
  def build_window_functions([]), do: nil

  def build_window_functions(window_functions) do
    Enum.map_join(window_functions, ", ", fn wf ->
      func_name = window_function_name(wf.function)
      field_arg = if wf[:field], do: "#{@table_alias}.#{wf.field}", else: ""

      partition_clause =
        if wf[:partition_by] && wf.partition_by != [] do
          cols = Enum.map_join(wf.partition_by, ", ", &"#{@table_alias}.#{&1}")
          "PARTITION BY #{cols}"
        else
          ""
        end

      order_clause =
        if wf[:order_by] && wf.order_by != [] do
          cols =
            Enum.map_join(wf.order_by, ", ", fn
              {field, :asc} -> "#{@table_alias}.#{field} ASC"
              {field, :desc} -> "#{@table_alias}.#{field} DESC"
              field when is_atom(field) -> "#{@table_alias}.#{field}"
            end)

          "ORDER BY #{cols}"
        else
          ""
        end

      over_clause =
        [partition_clause, order_clause]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" ")

      "#{func_name}(#{field_arg}) OVER (#{over_clause}) AS \"#{wf.name}\""
    end)
  end

  @doc """
  Converts a window function atom to its SQL name.

  ## Examples

      iex> window_function_name(:row_number)
      "ROW_NUMBER"

      iex> window_function_name(:dense_rank)
      "DENSE_RANK"
  """
  @spec window_function_name(atom()) :: String.t()
  def window_function_name(:row_number), do: "ROW_NUMBER"
  def window_function_name(:rank), do: "RANK"
  def window_function_name(:dense_rank), do: "DENSE_RANK"
  def window_function_name(:ntile), do: "NTILE"
  def window_function_name(:lag), do: "LAG"
  def window_function_name(:lead), do: "LEAD"
  def window_function_name(:first_value), do: "FIRST_VALUE"
  def window_function_name(:last_value), do: "LAST_VALUE"
  def window_function_name(:sum), do: "SUM"
  def window_function_name(:avg), do: "AVG"
  def window_function_name(:min), do: "MIN"
  def window_function_name(:max), do: "MAX"
  def window_function_name(:count), do: "COUNT"
  def window_function_name(func), do: String.upcase(to_string(func))

  @doc """
  Returns the default table alias used for window functions.
  """
  @spec table_alias() :: String.t()
  def table_alias, do: @table_alias
end
