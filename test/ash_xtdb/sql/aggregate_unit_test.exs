# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.AggregateUnitTest do
  @moduledoc """
  Unit tests for SQL aggregate function generation.

  Tests verify correct SQL generation for various aggregate function
  types including basic aggregates, statistical, and boolean aggregates.
  """
  use ExUnit.Case, async: true

  alias AshXTDB.SQL.Aggregate

  describe "aggregate_to_sql/1 basic aggregates" do
    test "COUNT(*) with nil field" do
      result = Aggregate.aggregate_to_sql(%{kind: :count, field: nil})

      assert result == "COUNT(*)"
    end

    test "COUNT with specific field" do
      result = Aggregate.aggregate_to_sql(%{kind: :count, field: :email})

      assert result == "COUNT(t.\"email\")"
    end

    test "COUNT DISTINCT" do
      result = Aggregate.aggregate_to_sql(%{kind: :count, field: :email, uniq?: true})

      assert result == "COUNT(DISTINCT t.\"email\")"
    end

    test "SUM" do
      result = Aggregate.aggregate_to_sql(%{kind: :sum, field: :amount})

      assert result == "SUM(t.\"amount\")"
    end

    test "AVG" do
      result = Aggregate.aggregate_to_sql(%{kind: :avg, field: :score})

      assert result == "AVG(t.\"score\")"
    end

    test "MIN" do
      result = Aggregate.aggregate_to_sql(%{kind: :min, field: :price})

      assert result == "MIN(t.\"price\")"
    end

    test "MAX" do
      result = Aggregate.aggregate_to_sql(%{kind: :max, field: :price})

      assert result == "MAX(t.\"price\")"
    end
  end

  describe "aggregate_to_sql/1 special aggregates" do
    test "EXISTS returns COUNT(*) > 0" do
      result = Aggregate.aggregate_to_sql(%{kind: :exists})

      assert result == "COUNT(*) > 0"
    end

    test "FIRST uses MIN as approximation" do
      result = Aggregate.aggregate_to_sql(%{kind: :first, field: :name})

      assert result == "MIN(t.\"name\")"
    end

    test "LIST uses ARRAY_AGG" do
      result = Aggregate.aggregate_to_sql(%{kind: :list, field: :tag})

      assert result == "ARRAY_AGG(t.\"tag\")"
    end
  end

  describe "aggregate_to_sql/1 statistical aggregates" do
    test "STDDEV_POP" do
      result = Aggregate.aggregate_to_sql(%{kind: :stddev_pop, field: :value})

      assert result == "STDDEV_POP(t.\"value\")"
    end

    test "STDDEV_SAMP" do
      result = Aggregate.aggregate_to_sql(%{kind: :stddev_samp, field: :value})

      assert result == "STDDEV_SAMP(t.\"value\")"
    end

    test "VAR_POP" do
      result = Aggregate.aggregate_to_sql(%{kind: :var_pop, field: :value})

      assert result == "VAR_POP(t.\"value\")"
    end

    test "VAR_SAMP" do
      result = Aggregate.aggregate_to_sql(%{kind: :var_samp, field: :value})

      assert result == "VAR_SAMP(t.\"value\")"
    end
  end

  describe "aggregate_to_sql/1 boolean aggregates" do
    test "BOOL_AND" do
      result = Aggregate.aggregate_to_sql(%{kind: :bool_and, field: :active})

      assert result == "BOOL_AND(t.\"active\")"
    end

    test "BOOL_OR" do
      result = Aggregate.aggregate_to_sql(%{kind: :bool_or, field: :active})

      assert result == "BOOL_OR(t.\"active\")"
    end
  end

  describe "aggregate_to_sql/1 with :id field" do
    test "COUNT with id field maps to _id" do
      result = Aggregate.aggregate_to_sql(%{kind: :count, field: :id})

      assert result == "COUNT(t.\"_id\")"
    end

    test "MIN with id field maps to _id" do
      result = Aggregate.aggregate_to_sql(%{kind: :min, field: :id})

      assert result == "MIN(t.\"_id\")"
    end

    test "MAX with id field maps to _id" do
      result = Aggregate.aggregate_to_sql(%{kind: :max, field: :id})

      assert result == "MAX(t.\"_id\")"
    end
  end

  describe "build_aggregate_select/1" do
    test "builds SELECT with single aggregate" do
      aggregates = [
        %{name: :total_count, kind: :count, field: nil}
      ]

      result = Aggregate.build_aggregate_select(aggregates)

      assert result == "SELECT COUNT(*) AS \"total_count\""
    end

    test "builds SELECT with multiple aggregates" do
      aggregates = [
        %{name: :total_count, kind: :count, field: nil},
        %{name: :total_amount, kind: :sum, field: :amount}
      ]

      result = Aggregate.build_aggregate_select(aggregates)

      assert result == "SELECT COUNT(*) AS \"total_count\", SUM(t.\"amount\") AS \"total_amount\""
    end

    test "builds SELECT with all basic aggregates" do
      aggregates = [
        %{name: :cnt, kind: :count, field: nil},
        %{name: :total, kind: :sum, field: :value},
        %{name: :average, kind: :avg, field: :value},
        %{name: :minimum, kind: :min, field: :value},
        %{name: :maximum, kind: :max, field: :value}
      ]

      result = Aggregate.build_aggregate_select(aggregates)

      assert result =~ "SELECT"
      assert result =~ "COUNT(*) AS \"cnt\""
      assert result =~ "SUM(t.\"value\") AS \"total\""
      assert result =~ "AVG(t.\"value\") AS \"average\""
      assert result =~ "MIN(t.\"value\") AS \"minimum\""
      assert result =~ "MAX(t.\"value\") AS \"maximum\""
    end

    test "builds SELECT with exists aggregate" do
      aggregates = [
        %{name: :has_items, kind: :exists}
      ]

      result = Aggregate.build_aggregate_select(aggregates)

      assert result == "SELECT COUNT(*) > 0 AS \"has_items\""
    end

    test "quotes aggregate names that are reserved words" do
      aggregates = [
        %{name: :exists, kind: :exists},
        %{name: :count, kind: :count, field: nil}
      ]

      result = Aggregate.build_aggregate_select(aggregates)

      # Names should be quoted
      assert result =~ "AS \"exists\""
      assert result =~ "AS \"count\""
    end

    test "builds SELECT with mixed aggregate types" do
      aggregates = [
        %{name: :row_count, kind: :count, field: nil},
        %{name: :unique_emails, kind: :count, field: :email, uniq?: true},
        %{name: :has_data, kind: :exists},
        %{name: :tags, kind: :list, field: :tag}
      ]

      result = Aggregate.build_aggregate_select(aggregates)

      assert result =~ "COUNT(*) AS \"row_count\""
      assert result =~ "COUNT(DISTINCT t.\"email\") AS \"unique_emails\""
      assert result =~ "COUNT(*) > 0 AS \"has_data\""
      assert result =~ "ARRAY_AGG(t.\"tag\") AS \"tags\""
    end
  end

  describe "table_alias/0" do
    test "returns the default table alias" do
      assert Aggregate.table_alias() == "t"
    end
  end

  describe "field name handling" do
    test "handles snake_case field names" do
      result = Aggregate.aggregate_to_sql(%{kind: :sum, field: :total_amount})

      assert result == "SUM(t.\"total_amount\")"
    end

    test "handles field names with numbers" do
      result = Aggregate.aggregate_to_sql(%{kind: :sum, field: :value_1})

      assert result == "SUM(t.\"value_1\")"
    end

    test "handles single character field names" do
      result = Aggregate.aggregate_to_sql(%{kind: :sum, field: :x})

      assert result == "SUM(t.\"x\")"
    end
  end
end
