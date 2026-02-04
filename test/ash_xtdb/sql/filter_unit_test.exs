# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.FilterUnitTest do
  @moduledoc """
  Unit tests for SQL Filter expression generation.

  These tests verify SQL generation for individual expression types without
  going through the full filter pipeline. This provides targeted coverage for
  edge cases and rarely-used features.
  """
  use ExUnit.Case, async: true

  alias AshXTDB.SQL.Filter

  # Base state for expression_to_sql tests
  defp base_state do
    %{
      resource: AshXTDB.Test.User,
      param_idx: 1,
      params: [],
      joins: %{},
      join_counter: 0,
      table_alias: "t",
      aggregate_alias_map: %{}
    }
  end

  describe "string_split/1 (split on space)" do
    test "generates STRING_TO_ARRAY with space delimiter" do
      state = base_state()

      expr = %Ash.Query.Function.StringSplit{
        arguments: [%Ash.Query.Ref{attribute: :name, relationship_path: []}]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "STRING_TO_ARRAY(t.\"name\", ' ')"
    end

    test "generates STRING_TO_ARRAY with literal string" do
      state = base_state()

      expr = %Ash.Query.Function.StringSplit{
        arguments: ["hello world"]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "STRING_TO_ARRAY($1, ' ')"
      assert state.params == ["hello world"]
    end
  end

  describe "string_split/2 (split with custom delimiter)" do
    test "generates STRING_TO_ARRAY with custom delimiter" do
      state = base_state()

      expr = %Ash.Query.Function.StringSplit{
        arguments: [%Ash.Query.Ref{attribute: :name, relationship_path: []}, ","]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "STRING_TO_ARRAY(t.\"name\", $1)"
      assert state.params == [","]
    end

    test "generates STRING_TO_ARRAY with literal strings" do
      state = base_state()

      expr = %Ash.Query.Function.StringSplit{
        arguments: ["a,b,c", ","]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "STRING_TO_ARRAY($1, $2)"
      assert state.params == [",", "a,b,c"]
    end
  end

  describe "string_split edge cases" do
    test "handles empty arguments gracefully" do
      state = base_state()

      expr = %Ash.Query.Function.StringSplit{
        arguments: []
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "NULL"
    end
  end

  describe "start_of_day/1 (without timezone)" do
    test "generates DATE_TRUNC with DAY" do
      state = base_state()

      expr = %Ash.Query.Function.StartOfDay{
        arguments: [%Ash.Query.Ref{attribute: :created_at, relationship_path: []}]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "DATE_TRUNC(DAY, t.\"created_at\")"
    end
  end

  describe "start_of_day/2 (with timezone)" do
    test "generates DATE_TRUNC with timezone parameter" do
      state = base_state()

      expr = %Ash.Query.Function.StartOfDay{
        arguments: [
          %Ash.Query.Ref{attribute: :created_at, relationship_path: []},
          "America/New_York"
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "DATE_TRUNC(DAY, t.\"created_at\", $1)"
      assert state.params == ["America/New_York"]
    end

    test "generates DATE_TRUNC with Europe/London timezone" do
      state = base_state()

      expr = %Ash.Query.Function.StartOfDay{
        arguments: [
          %Ash.Query.Ref{attribute: :created_at, relationship_path: []},
          "Europe/London"
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "DATE_TRUNC(DAY, t.\"created_at\", $1)"
      assert state.params == ["Europe/London"]
    end
  end

  describe "IN operator with empty list" do
    test "generates IN with empty list" do
      state = base_state()

      expr = %Ash.Query.Operator.In{
        left: %Ash.Query.Ref{attribute: :name, relationship_path: []},
        right: []
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      # Empty IN clause - no placeholders
      assert sql == "t.\"name\" IN ()"
      assert state.params == []
    end
  end

  describe "IN operator with empty MapSet" do
    test "generates IN with empty MapSet" do
      state = base_state()

      expr = %Ash.Query.Operator.In{
        left: %Ash.Query.Ref{attribute: :name, relationship_path: []},
        right: MapSet.new()
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      # Empty IN clause from MapSet
      assert sql == "t.\"name\" IN ()"
      assert state.params == []
    end
  end

  describe "IN operator with Ref on right side" do
    test "generates ANY with array column reference" do
      state = base_state()

      expr = %Ash.Query.Operator.In{
        left: "test_value",
        right: %Ash.Query.Ref{attribute: :tags, relationship_path: []}
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "$1 = ANY(t.\"tags\")"
      assert state.params == ["test_value"]
    end
  end

  describe "IN operator with MapSet" do
    test "generates IN with MapSet values" do
      state = base_state()

      expr = %Ash.Query.Operator.In{
        left: %Ash.Query.Ref{attribute: :name, relationship_path: []},
        right: MapSet.new(["Alice", "Bob"])
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      # MapSet order is undefined, so we check structure
      assert sql =~ "t.\"name\" IN ("
      assert sql =~ "$1"
      assert sql =~ "$2"
      assert length(state.params) == 2
      assert Enum.sort(state.params) == ["Alice", "Bob"]
    end
  end

  describe "Duration with multiple components" do
    test "generates interval addition for year and month" do
      state = base_state()
      duration = Duration.new!(year: 1, month: 2)

      expr = %Ash.Query.Function.DateAdd{
        arguments: [
          %Ash.Query.Ref{attribute: :created_at, relationship_path: []},
          duration
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "t.\"created_at\""
      assert sql =~ "INTERVAL"
      assert sql =~ "YEAR"
      assert sql =~ "MONTH"
    end

    test "generates interval for year, month, and day" do
      state = base_state()
      duration = Duration.new!(year: 1, month: 2, day: 3)

      expr = %Ash.Query.Function.DateAdd{
        arguments: [
          %Ash.Query.Ref{attribute: :created_at, relationship_path: []},
          duration
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "t.\"created_at\""
      assert sql =~ "INTERVAL"
      assert sql =~ "YEAR"
      assert sql =~ "MONTH"
      assert sql =~ "DAY"
    end

    test "generates zero-second interval for zero duration" do
      state = base_state()
      duration = Duration.new!([])

      expr = %Ash.Query.Function.DateAdd{
        arguments: [
          %Ash.Query.Ref{attribute: :created_at, relationship_path: []},
          duration
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "INTERVAL '0' SECOND"
    end

    test "generates single interval for single component duration" do
      state = base_state()
      duration = Duration.new!(day: 7)

      expr = %Ash.Query.Function.DateAdd{
        arguments: [
          %Ash.Query.Ref{attribute: :created_at, relationship_path: []},
          duration
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "INTERVAL '7 DAY'"
    end

    test "converts weeks to days in duration" do
      state = base_state()
      duration = Duration.new!(week: 2)

      expr = %Ash.Query.Function.DateAdd{
        arguments: [
          %Ash.Query.Ref{attribute: :created_at, relationship_path: []},
          duration
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      # 2 weeks = 14 days
      assert sql =~ "INTERVAL '14 DAY'"
    end
  end

  describe "unhandled struct fallback" do
    test "returns nil for unknown struct and logs warning" do
      state = base_state()

      # Create a struct that is not handled
      expr = %{__struct__: SomeUnknownModule, data: "test"}

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == nil
    end
  end

  describe "unhandled non-struct expressions" do
    test "returns nil for raw map without struct" do
      state = base_state()

      expr = %{not_a_struct: true}

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == nil
    end

    test "returns nil for tuple expression" do
      state = base_state()

      expr = {:unknown, :expression}

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == nil
    end
  end

  describe "date_add with three arguments" do
    test "generates interval addition with amount and unit" do
      state = base_state()

      expr = %Ash.Query.Function.DateAdd{
        arguments: [
          %Ash.Query.Ref{attribute: :created_at, relationship_path: []},
          7,
          :day
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "t.\"created_at\""
      assert sql =~ "+ $1 * INTERVAL '1' DAY"
      assert state.params == [7]
    end

    test "generates interval with hour unit" do
      state = base_state()

      expr = %Ash.Query.Function.DateAdd{
        arguments: [
          %Ash.Query.Ref{attribute: :created_at, relationship_path: []},
          24,
          :hour
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "INTERVAL '1' HOUR"
      assert state.params == [24]
    end
  end

  describe "fragment expression" do
    test "generates raw SQL from fragment" do
      state = base_state()

      expr = %Ash.Query.Function.Fragment{
        arguments: [
          {:raw, "UPPER("},
          {:expr, %Ash.Query.Ref{attribute: :name, relationship_path: []}},
          {:raw, ")"}
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "UPPER(t.\"name\")"
    end

    test "handles casted_expr in fragment" do
      state = base_state()

      expr = %Ash.Query.Function.Fragment{
        arguments: [
          {:raw, "COALESCE("},
          {:casted_expr, %Ash.Query.Ref{attribute: :name, relationship_path: []}},
          {:raw, ", 'default')"}
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "COALESCE(t.\"name\", 'default')"
    end
  end

  describe "GetPath expression" do
    test "generates path traversal for map access" do
      state = base_state()

      expr = %Ash.Query.Function.GetPath{
        arguments: [
          %Ash.Query.Ref{attribute: :metadata, relationship_path: []},
          [:user, :name]
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "(t.\"metadata\").user.name"
    end

    test "generates path traversal with array index" do
      state = base_state()

      expr = %Ash.Query.Function.GetPath{
        arguments: [
          %Ash.Query.Ref{attribute: :items, relationship_path: []},
          [0, :name]
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "(t.\"items\")[0].name"
    end

    test "handles empty path" do
      state = base_state()

      expr = %Ash.Query.Function.GetPath{
        arguments: [
          %Ash.Query.Ref{attribute: :metadata, relationship_path: []},
          []
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"metadata\""
    end
  end

  describe "boolean expression short-circuits" do
    test "AND with nil left returns right" do
      state = base_state()

      expr = %Ash.Query.BooleanExpression{
        op: :and,
        left: %{__struct__: SomeUnknownModule},
        right: %Ash.Query.Operator.Eq{
          left: %Ash.Query.Ref{attribute: :name, relationship_path: []},
          right: "Alice"
        }
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"name\" = $1"
      assert state.params == ["Alice"]
    end

    test "AND with nil right returns left" do
      state = base_state()

      expr = %Ash.Query.BooleanExpression{
        op: :and,
        left: %Ash.Query.Operator.Eq{
          left: %Ash.Query.Ref{attribute: :name, relationship_path: []},
          right: "Alice"
        },
        right: %{__struct__: SomeUnknownModule}
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"name\" = $1"
      assert state.params == ["Alice"]
    end

    test "OR with nil left returns right" do
      state = base_state()

      expr = %Ash.Query.BooleanExpression{
        op: :or,
        left: %{__struct__: SomeUnknownModule},
        right: %Ash.Query.Operator.Eq{
          left: %Ash.Query.Ref{attribute: :name, relationship_path: []},
          right: "Bob"
        }
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"name\" = $1"
      assert state.params == ["Bob"]
    end

    test "OR with nil right returns left" do
      state = base_state()

      expr = %Ash.Query.BooleanExpression{
        op: :or,
        left: %Ash.Query.Operator.Eq{
          left: %Ash.Query.Ref{attribute: :name, relationship_path: []},
          right: "Bob"
        },
        right: %{__struct__: SomeUnknownModule}
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"name\" = $1"
      assert state.params == ["Bob"]
    end
  end

  describe "NOT expression" do
    test "generates NOT for valid expression" do
      state = base_state()

      expr = %Ash.Query.Not{
        expression: %Ash.Query.Operator.Eq{
          left: %Ash.Query.Ref{attribute: :active, relationship_path: []},
          right: true
        }
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "NOT (t.\"active\" = TRUE)"
    end

    test "returns nil for NOT with nil inner expression" do
      state = base_state()

      expr = %Ash.Query.Not{
        expression: %{__struct__: SomeUnknownModule}
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == nil
    end
  end

  describe "math functions via Call" do
    test "floor generates FLOOR" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :floor,
        args: [%Ash.Query.Ref{attribute: :age, relationship_path: []}]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "FLOOR(t.\"age\")"
    end

    test "ceil generates CEIL" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :ceil,
        args: [%Ash.Query.Ref{attribute: :age, relationship_path: []}]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "CEIL(t.\"age\")"
    end

    test "abs generates ABS" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :abs,
        args: [%Ash.Query.Ref{attribute: :age, relationship_path: []}]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "ABS(t.\"age\")"
    end

    test "round with single argument" do
      state = base_state()

      expr = %Ash.Query.Function.Round{
        arguments: [%Ash.Query.Ref{attribute: :age, relationship_path: []}]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "ROUND(t.\"age\")"
    end

    test "round with precision argument" do
      state = base_state()

      expr = %Ash.Query.Function.Round{
        arguments: [%Ash.Query.Ref{attribute: :age, relationship_path: []}, 2]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "ROUND(t.\"age\", $1)"
      assert state.params == [2]
    end
  end

  describe "date/time functions" do
    test "now generates CURRENT_TIMESTAMP" do
      state = base_state()

      expr = %Ash.Query.Function.Now{
        arguments: []
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "CURRENT_TIMESTAMP"
    end

    test "today generates CURRENT_DATE" do
      state = base_state()

      expr = %Ash.Query.Function.Today{
        arguments: []
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "CURRENT_DATE"
    end

    test "ago generates CURRENT_TIMESTAMP minus interval" do
      state = base_state()

      expr = %Ash.Query.Function.Ago{
        arguments: [5, :day]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "(CURRENT_TIMESTAMP - ($1 * INTERVAL '1' DAY))"
      assert state.params == [5]
    end

    test "from_now generates CURRENT_TIMESTAMP plus interval" do
      state = base_state()

      expr = %Ash.Query.Function.FromNow{
        arguments: [3, :hour]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "(CURRENT_TIMESTAMP + ($1 * INTERVAL '1' HOUR))"
      assert state.params == [3]
    end
  end

  describe "string_position function" do
    test "generates CASE with POSITION" do
      state = base_state()

      expr = %Ash.Query.Function.StringPosition{
        arguments: [
          %Ash.Query.Ref{attribute: :name, relationship_path: []},
          "test"
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~
               "(CASE WHEN POSITION($1 IN t.\"name\") = 0 THEN NULL ELSE POSITION($1 IN t.\"name\") - 1 END)"

      assert state.params == ["test"]
    end
  end

  describe "string_join function" do
    test "joins list without separator using concatenation" do
      state = base_state()

      expr = %Ash.Query.Function.StringJoin{
        arguments: [
          [
            %Ash.Query.Ref{attribute: :name, relationship_path: []},
            "suffix"
          ]
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"name\" || $1"
      assert state.params == ["suffix"]
    end

    test "joins list with separator" do
      state = base_state()

      expr = %Ash.Query.Function.StringJoin{
        arguments: [
          [
            %Ash.Query.Ref{attribute: :name, relationship_path: []},
            "middle",
            "end"
          ],
          "-"
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "t.\"name\""
      assert sql =~ " || $"
      assert length(state.params) == 3
    end
  end

  describe "cond expression via Call" do
    test "generates CASE WHEN for multiple branches" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :cond,
        args: [
          [
            {%Ash.Query.Operator.LessThan{
               left: %Ash.Query.Ref{attribute: :age, relationship_path: []},
               right: 18
             }, "minor"},
            {%Ash.Query.Operator.LessThan{
               left: %Ash.Query.Ref{attribute: :age, relationship_path: []},
               right: 65
             }, "adult"}
          ]
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "CASE"
      assert sql =~ "WHEN t.\"age\" < $1 THEN $2"
      assert sql =~ "WHEN t.\"age\" < $3 THEN $4"
      assert sql =~ "ELSE NULL END"
      assert state.params == ["adult", 65, "minor", 18]
    end
  end

  describe "if expression" do
    test "generates CASE WHEN for if with keyword args" do
      state = base_state()

      # Using Call since If struct may have different argument format
      expr = %Ash.Query.Call{
        name: :if,
        args: [
          %Ash.Query.Operator.GreaterThan{
            left: %Ash.Query.Ref{attribute: :age, relationship_path: []},
            right: 18
          },
          [do: "adult", else: "minor"]
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "CASE WHEN t.\"age\" > $1 THEN $2 ELSE $3 END"
      assert state.params == ["minor", "adult", 18]
    end
  end

  describe "Type function" do
    test "passes through inner expression" do
      state = base_state()

      expr = %Ash.Query.Function.Type{
        arguments: [
          %Ash.Query.Ref{attribute: :age, relationship_path: []},
          :integer
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"age\""
    end
  end

  describe "string concatenation operator" do
    test "generates || for Concat operator" do
      state = base_state()

      expr = %Ash.Query.Operator.Basic.Concat{
        left: %Ash.Query.Ref{attribute: :name, relationship_path: []},
        right: "_suffix"
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "(t.\"name\" || $1)"
      assert state.params == ["_suffix"]
    end
  end

  describe "call-based functions" do
    test "call to :is_nil generates IS NULL" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :is_nil,
        args: [%Ash.Query.Ref{attribute: :name, relationship_path: []}]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"name\" IS NULL"
    end

    test "call to :not generates NOT" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :not,
        args: [
          %Ash.Query.Operator.Eq{
            left: %Ash.Query.Ref{attribute: :active, relationship_path: []},
            right: true
          }
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "NOT (t.\"active\" = TRUE)"
    end

    test "call to arithmetic operators" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :+,
        args: [
          %Ash.Query.Ref{attribute: :age, relationship_path: []},
          5
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "(t.\"age\" + $1)"
      assert state.params == [5]
    end

    test "call to string concatenation" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :<>,
        args: [
          %Ash.Query.Ref{attribute: :name, relationship_path: []},
          " Jr."
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "(t.\"name\" || $1)"
      assert state.params == [" Jr."]
    end

    test "unhandled function call returns nil" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :unknown_function,
        args: ["arg1", "arg2"]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == nil
    end
  end

  describe "interval string conversion" do
    test "handles millisecond interval" do
      state = base_state()

      expr = %Ash.Query.Function.Ago{
        arguments: [500, :millisecond]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "MILLISECOND"
      assert state.params == [500]
    end

    test "handles microsecond interval" do
      state = base_state()

      expr = %Ash.Query.Function.Ago{
        arguments: [1000, :microsecond]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "MICROSECOND"
      assert state.params == [1000]
    end

    test "handles string interval" do
      state = base_state()

      expr = %Ash.Query.Function.Ago{
        arguments: [2, "day"]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "DAY"
      assert state.params == [2]
    end
  end

  describe "rem function via Call" do
    test "generates MOD for rem" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :rem,
        args: [
          %Ash.Query.Ref{attribute: :age, relationship_path: []},
          10
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "MOD(t.\"age\", $1)"
      assert state.params == [10]
    end
  end

  describe "comparison operators via Call" do
    test "== generates equality" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :==,
        args: [
          %Ash.Query.Ref{attribute: :age, relationship_path: []},
          25
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"age\" = $1"
      assert state.params == [25]
    end

    test "!= generates inequality" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :!=,
        args: [
          %Ash.Query.Ref{attribute: :age, relationship_path: []},
          25
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"age\" != $1"
      assert state.params == [25]
    end

    test "> generates greater than" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :>,
        args: [
          %Ash.Query.Ref{attribute: :age, relationship_path: []},
          18
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"age\" > $1"
      assert state.params == [18]
    end

    test "< generates less than" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :<,
        args: [
          %Ash.Query.Ref{attribute: :age, relationship_path: []},
          18
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"age\" < $1"
      assert state.params == [18]
    end

    test ">= generates greater than or equal" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :>=,
        args: [
          %Ash.Query.Ref{attribute: :age, relationship_path: []},
          18
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"age\" >= $1"
      assert state.params == [18]
    end

    test "<= generates less than or equal" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :<=,
        args: [
          %Ash.Query.Ref{attribute: :age, relationship_path: []},
          18
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"age\" <= $1"
      assert state.params == [18]
    end
  end

  describe "date/time calls" do
    test "now call generates CURRENT_TIMESTAMP" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :now,
        args: []
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "CURRENT_TIMESTAMP"
    end

    test "today call generates CURRENT_DATE" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :today,
        args: []
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "CURRENT_DATE"
    end

    test "ago call generates CURRENT_TIMESTAMP minus interval" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :ago,
        args: [7, :day]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "(CURRENT_TIMESTAMP - ($1 * INTERVAL '1' DAY))"
      assert state.params == [7]
    end

    test "from_now call generates CURRENT_TIMESTAMP plus interval" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :from_now,
        args: [1, :week]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "(CURRENT_TIMESTAMP + ($1 * INTERVAL '1' WEEK))"
      assert state.params == [1]
    end

    test "date_add call generates interval addition" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :date_add,
        args: [
          %Ash.Query.Ref{attribute: :created_at, relationship_path: []},
          30,
          :minute
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "t.\"created_at\""
      assert sql =~ "INTERVAL '1' MINUTE"
      assert state.params == [30]
    end

    test "start_of_day call generates DATE_TRUNC" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :start_of_day,
        args: [%Ash.Query.Ref{attribute: :created_at, relationship_path: []}]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "DATE_TRUNC(DAY, t.\"created_at\")"
    end
  end

  describe "get_path call" do
    test "generates XTDB path traversal" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :get_path,
        args: [
          %Ash.Query.Ref{attribute: :data, relationship_path: []},
          [:nested, :value]
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "(t.\"data\").nested.value"
    end
  end

  describe "type call" do
    test "passes through inner expression" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :type,
        args: [
          %Ash.Query.Ref{attribute: :age, relationship_path: []},
          :integer
        ]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "t.\"age\""
    end
  end

  describe "string functions via Call" do
    test "string_downcase generates LOWER" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :string_downcase,
        args: [%Ash.Query.Ref{attribute: :name, relationship_path: []}]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "LOWER(t.\"name\")"
    end

    test "string_length generates LENGTH" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :string_length,
        args: [%Ash.Query.Ref{attribute: :name, relationship_path: []}]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "LENGTH(t.\"name\")"
    end

    test "string_trim generates TRIM" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :string_trim,
        args: [%Ash.Query.Ref{attribute: :name, relationship_path: []}]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "TRIM(t.\"name\")"
    end

    test "string_position generates CASE with POSITION" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :string_position,
        args: [
          %Ash.Query.Ref{attribute: :name, relationship_path: []},
          "test"
        ]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql =~
               "(CASE WHEN POSITION($1 IN t.\"name\") = 0 THEN NULL ELSE POSITION($1 IN t.\"name\") - 1 END)"

      assert state.params == ["test"]
    end
  end

  describe "round function via Call" do
    test "round with single argument" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :round,
        args: [%Ash.Query.Ref{attribute: :age, relationship_path: []}]
      }

      {sql, _state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "ROUND(t.\"age\")"
    end

    test "round with precision argument" do
      state = base_state()

      expr = %Ash.Query.Call{
        name: :round,
        args: [%Ash.Query.Ref{attribute: :age, relationship_path: []}, 2]
      }

      {sql, state} = Filter.expression_to_sql_for_test(expr, state)

      assert sql == "ROUND(t.\"age\", $1)"
      assert state.params == [2]
    end
  end
end
