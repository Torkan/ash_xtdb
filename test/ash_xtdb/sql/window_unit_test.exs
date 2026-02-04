# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.WindowUnitTest do
  @moduledoc """
  Unit tests for SQL window function generation.

  Tests verify correct SQL generation for various window function
  configurations including ranking, value access, and aggregate windows.
  """
  use ExUnit.Case, async: true

  alias AshXTDB.SQL.Window

  describe "window_function_name/1" do
    test "converts :row_number" do
      assert Window.window_function_name(:row_number) == "ROW_NUMBER"
    end

    test "converts :rank" do
      assert Window.window_function_name(:rank) == "RANK"
    end

    test "converts :dense_rank" do
      assert Window.window_function_name(:dense_rank) == "DENSE_RANK"
    end

    test "converts :ntile" do
      assert Window.window_function_name(:ntile) == "NTILE"
    end

    test "converts :lag" do
      assert Window.window_function_name(:lag) == "LAG"
    end

    test "converts :lead" do
      assert Window.window_function_name(:lead) == "LEAD"
    end

    test "converts :first_value" do
      assert Window.window_function_name(:first_value) == "FIRST_VALUE"
    end

    test "converts :last_value" do
      assert Window.window_function_name(:last_value) == "LAST_VALUE"
    end

    test "converts :sum" do
      assert Window.window_function_name(:sum) == "SUM"
    end

    test "converts :avg" do
      assert Window.window_function_name(:avg) == "AVG"
    end

    test "converts :min" do
      assert Window.window_function_name(:min) == "MIN"
    end

    test "converts :max" do
      assert Window.window_function_name(:max) == "MAX"
    end

    test "converts :count" do
      assert Window.window_function_name(:count) == "COUNT"
    end

    test "converts unknown function by uppercasing" do
      assert Window.window_function_name(:custom_func) == "CUSTOM_FUNC"
    end
  end

  describe "build_window_functions/1 with empty list" do
    test "returns nil for empty list" do
      assert Window.build_window_functions([]) == nil
    end
  end

  describe "build_window_functions/1 with single window" do
    test "builds ROW_NUMBER without partition or order" do
      windows = [
        %{
          name: :row_num,
          function: :row_number
        }
      ]

      result = Window.build_window_functions(windows)

      assert result == "ROW_NUMBER() OVER () AS \"row_num\""
    end

    test "builds ROW_NUMBER with partition by" do
      windows = [
        %{
          name: :row_num,
          function: :row_number,
          partition_by: [:organization_id]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result == "ROW_NUMBER() OVER (PARTITION BY t.organization_id) AS \"row_num\""
    end

    test "builds ROW_NUMBER with order by ascending" do
      windows = [
        %{
          name: :row_num,
          function: :row_number,
          order_by: [{:created_at, :asc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result == "ROW_NUMBER() OVER (ORDER BY t.created_at ASC) AS \"row_num\""
    end

    test "builds ROW_NUMBER with order by descending" do
      windows = [
        %{
          name: :row_num,
          function: :row_number,
          order_by: [{:created_at, :desc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result == "ROW_NUMBER() OVER (ORDER BY t.created_at DESC) AS \"row_num\""
    end

    test "builds ROW_NUMBER with partition and order" do
      windows = [
        %{
          name: :row_num,
          function: :row_number,
          partition_by: [:organization_id],
          order_by: [{:created_at, :desc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result ==
               "ROW_NUMBER() OVER (PARTITION BY t.organization_id ORDER BY t.created_at DESC) AS \"row_num\""
    end

    test "builds RANK with multiple partition columns" do
      windows = [
        %{
          name: :user_rank,
          function: :rank,
          partition_by: [:organization_id, :department_id],
          order_by: [{:score, :desc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result ==
               "RANK() OVER (PARTITION BY t.organization_id, t.department_id ORDER BY t.score DESC) AS \"user_rank\""
    end

    test "builds SUM with field argument" do
      windows = [
        %{
          name: :running_total,
          function: :sum,
          field: :amount,
          order_by: [{:date, :asc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result ==
               "SUM(t.amount) OVER (ORDER BY t.date ASC) AS \"running_total\""
    end

    test "builds AVG with field and partition" do
      windows = [
        %{
          name: :dept_avg,
          function: :avg,
          field: :salary,
          partition_by: [:department_id]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result ==
               "AVG(t.salary) OVER (PARTITION BY t.department_id) AS \"dept_avg\""
    end

    test "builds COUNT with field" do
      windows = [
        %{
          name: :running_count,
          function: :count,
          field: :id,
          order_by: [{:created_at, :asc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result ==
               "COUNT(t.id) OVER (ORDER BY t.created_at ASC) AS \"running_count\""
    end
  end

  describe "build_window_functions/1 with multiple windows" do
    test "builds multiple window functions" do
      windows = [
        %{
          name: :row_num,
          function: :row_number,
          order_by: [{:created_at, :desc}]
        },
        %{
          name: :user_rank,
          function: :rank,
          partition_by: [:organization_id],
          order_by: [{:score, :desc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result =~ "ROW_NUMBER() OVER (ORDER BY t.created_at DESC) AS \"row_num\""
      assert result =~ ", "

      assert result =~
               "RANK() OVER (PARTITION BY t.organization_id ORDER BY t.score DESC) AS \"user_rank\""
    end

    test "builds three window functions" do
      windows = [
        %{name: :rn, function: :row_number, order_by: [{:id, :asc}]},
        %{name: :total, function: :sum, field: :amount, partition_by: [:category]},
        %{name: :max_val, function: :max, field: :value}
      ]

      result = Window.build_window_functions(windows)

      parts = String.split(result, ", ")
      assert length(parts) == 3
    end
  end

  describe "build_window_functions/1 with multiple order by columns" do
    test "builds with multiple order by columns" do
      windows = [
        %{
          name: :row_num,
          function: :row_number,
          order_by: [{:last_name, :asc}, {:first_name, :asc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result ==
               "ROW_NUMBER() OVER (ORDER BY t.last_name ASC, t.first_name ASC) AS \"row_num\""
    end

    test "builds with mixed order directions" do
      windows = [
        %{
          name: :row_num,
          function: :row_number,
          order_by: [{:priority, :desc}, {:created_at, :asc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result ==
               "ROW_NUMBER() OVER (ORDER BY t.priority DESC, t.created_at ASC) AS \"row_num\""
    end

    test "handles order by with just field atom (no direction)" do
      windows = [
        %{
          name: :row_num,
          function: :row_number,
          order_by: [:created_at]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result == "ROW_NUMBER() OVER (ORDER BY t.created_at) AS \"row_num\""
    end
  end

  describe "build_window_functions/1 edge cases" do
    test "handles empty partition_by list" do
      windows = [
        %{
          name: :row_num,
          function: :row_number,
          partition_by: [],
          order_by: [{:id, :asc}]
        }
      ]

      result = Window.build_window_functions(windows)

      # Empty partition_by should not produce PARTITION BY clause
      refute result =~ "PARTITION BY"
      assert result =~ "ORDER BY"
    end

    test "handles empty order_by list" do
      windows = [
        %{
          name: :row_num,
          function: :row_number,
          partition_by: [:org_id],
          order_by: []
        }
      ]

      result = Window.build_window_functions(windows)

      # Empty order_by should not produce ORDER BY clause
      assert result =~ "PARTITION BY"
      refute result =~ "ORDER BY"
    end

    test "handles nil partition_by" do
      windows = [
        %{
          name: :row_num,
          function: :row_number,
          partition_by: nil,
          order_by: [{:id, :asc}]
        }
      ]

      result = Window.build_window_functions(windows)

      refute result =~ "PARTITION BY"
    end

    test "handles nil order_by" do
      windows = [
        %{
          name: :row_num,
          function: :row_number,
          partition_by: [:org_id],
          order_by: nil
        }
      ]

      result = Window.build_window_functions(windows)

      refute result =~ "ORDER BY"
    end
  end

  describe "table_alias/0" do
    test "returns the default table alias" do
      assert Window.table_alias() == "t"
    end
  end

  describe "value access window functions" do
    test "builds LAG function" do
      windows = [
        %{
          name: :prev_value,
          function: :lag,
          field: :amount,
          order_by: [{:date, :asc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result == "LAG(t.amount) OVER (ORDER BY t.date ASC) AS \"prev_value\""
    end

    test "builds LEAD function" do
      windows = [
        %{
          name: :next_value,
          function: :lead,
          field: :amount,
          order_by: [{:date, :asc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result == "LEAD(t.amount) OVER (ORDER BY t.date ASC) AS \"next_value\""
    end

    test "builds FIRST_VALUE function" do
      windows = [
        %{
          name: :first_amt,
          function: :first_value,
          field: :amount,
          partition_by: [:category],
          order_by: [{:date, :asc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result ==
               "FIRST_VALUE(t.amount) OVER (PARTITION BY t.category ORDER BY t.date ASC) AS \"first_amt\""
    end

    test "builds LAST_VALUE function" do
      windows = [
        %{
          name: :last_amt,
          function: :last_value,
          field: :amount,
          partition_by: [:category],
          order_by: [{:date, :asc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result ==
               "LAST_VALUE(t.amount) OVER (PARTITION BY t.category ORDER BY t.date ASC) AS \"last_amt\""
    end
  end

  describe "ranking functions" do
    test "builds DENSE_RANK" do
      windows = [
        %{
          name: :dense_rank,
          function: :dense_rank,
          partition_by: [:department],
          order_by: [{:salary, :desc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result ==
               "DENSE_RANK() OVER (PARTITION BY t.department ORDER BY t.salary DESC) AS \"dense_rank\""
    end

    test "builds NTILE" do
      windows = [
        %{
          name: :quartile,
          function: :ntile,
          order_by: [{:score, :desc}]
        }
      ]

      result = Window.build_window_functions(windows)

      assert result == "NTILE() OVER (ORDER BY t.score DESC) AS \"quartile\""
    end
  end
end
