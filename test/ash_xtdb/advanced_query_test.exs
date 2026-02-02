# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.AdvancedQueryTest do
  @moduledoc """
  Integration tests for advanced query features: window functions, CTEs, and set operations.
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Query
  alias AshXTDB.Test.User

  @moduletag :integration

  setup do
    # Clean up before each test
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])
    :ok
  end

  describe "window function execution" do
    setup do
      # Create organization UUIDs for partition tests
      org1 = Ash.UUID.generate()
      org2 = Ash.UUID.generate()

      # Create users with different ages for window function tests
      for {name, age, org_id} <- [
            {"Alice", 25, org1},
            {"Bob", 30, org1},
            {"Carol", 35, org1},
            {"David", 28, org2},
            {"Eve", 32, org2}
          ] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: age,
          organization_id: org_id
        })
        |> Ash.create!()
      end

      {:ok, org1: org1, org2: org2}
    end

    test "executes ROW_NUMBER window function" do
      sql = """
      SELECT t.name, t.age, ROW_NUMBER() OVER (ORDER BY t.age ASC) AS row_num
      FROM users t
      ORDER BY t.age ASC
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: rows}} ->
          # Should have 5 rows with ascending row numbers
          assert length(rows) == 5
          row_nums = Enum.map(rows, fn [_name, _age, row_num] -> parse_int(row_num) end)
          assert row_nums == [1, 2, 3, 4, 5]

        {:error, error} ->
          flunk("ROW_NUMBER query failed: #{inspect(error)}")
      end
    end

    # Note: RANK() is not yet implemented in XTDB v2
    @tag :skip
    test "executes RANK window function" do
      sql = """
      SELECT t.name, t.age, RANK() OVER (ORDER BY t.age ASC) AS user_rank
      FROM users t
      ORDER BY t.age ASC
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: rows}} ->
          assert length(rows) == 5
          # First row should have rank 1
          [[_name, _age, rank] | _] = rows
          assert parse_int(rank) == 1

        {:error, error} ->
          flunk("RANK query failed: #{inspect(error)}")
      end
    end

    test "executes window function with PARTITION BY", %{org1: org1, org2: org2} do
      sql = """
      SELECT t.name, t.organization_id, t.age,
             ROW_NUMBER() OVER (PARTITION BY t.organization_id ORDER BY t.age ASC) AS org_row_num
      FROM users t
      ORDER BY t.organization_id, t.age
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: rows}} ->
          assert length(rows) == 5
          # Each organization should have its own row numbering starting from 1
          org1_rows = Enum.filter(rows, fn [_, org_id, _, _] -> org_id == org1 end)
          org1_nums = Enum.map(org1_rows, fn [_, _, _, num] -> parse_int(num) end)
          assert org1_nums == [1, 2, 3]

          org2_rows = Enum.filter(rows, fn [_, org_id, _, _] -> org_id == org2 end)
          org2_nums = Enum.map(org2_rows, fn [_, _, _, num] -> parse_int(num) end)
          assert org2_nums == [1, 2]

        {:error, error} ->
          flunk("PARTITION BY query failed: #{inspect(error)}")
      end
    end

    # Note: Aggregate window functions (SUM() OVER) are not yet implemented in XTDB v2
    @tag :skip
    test "executes SUM window function for running total" do
      sql = """
      SELECT t.name, t.age, SUM(t.age) OVER (ORDER BY t.age ASC) AS running_total
      FROM users t
      ORDER BY t.age ASC
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: rows}} ->
          # Running totals should accumulate
          totals = Enum.map(rows, fn [_name, _age, total] -> parse_int(total) end)
          # Ages sorted: 25, 28, 30, 32, 35
          # Running totals: 25, 53, 83, 115, 150
          assert hd(totals) == 25
          assert List.last(totals) == 150

        {:error, error} ->
          flunk("SUM window function failed: #{inspect(error)}")
      end
    end
  end

  describe "CTE (WITH clause) execution" do
    setup do
      for {name, age, active} <- [
            {"Active1", 25, true},
            {"Active2", 30, true},
            {"Inactive1", 35, false},
            {"Active3", 40, true}
          ] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: age,
          active: active
        })
        |> Ash.create!()
      end

      :ok
    end

    test "executes simple CTE query" do
      sql = """
      WITH active_users AS (
        SELECT t.\"_id\", t.name, t.age
        FROM users t
        WHERE t.active = true
      )
      SELECT * FROM active_users
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: rows}} ->
          # Should only have active users (3)
          assert length(rows) == 3

        {:error, error} ->
          flunk("CTE query failed: #{inspect(error)}")
      end
    end

    test "executes CTE with aggregation" do
      sql = """
      WITH age_stats AS (
        SELECT AVG(t.age) AS avg_age
        FROM users t
        WHERE t.active = true
      )
      SELECT avg_age FROM age_stats
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[avg_age]]}} ->
          # Average of 25, 30, 40 = 31.67
          assert_in_delta parse_float(avg_age), 31.67, 0.1

        {:error, error} ->
          flunk("CTE with aggregation failed: #{inspect(error)}")
      end
    end

    test "executes multiple CTEs" do
      sql = """
      WITH
        young_users AS (
          SELECT t.\"_id\", t.name FROM users t WHERE t.age < 30
        ),
        old_users AS (
          SELECT t.\"_id\", t.name FROM users t WHERE t.age >= 30
        )
      SELECT
        (SELECT COUNT(*) FROM young_users) AS young_count,
        (SELECT COUNT(*) FROM old_users) AS old_count
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[young, old]]}} ->
          assert parse_int(young) == 1  # Age 25
          assert parse_int(old) == 3    # Ages 30, 35, 40

        {:error, error} ->
          flunk("Multiple CTEs query failed: #{inspect(error)}")
      end
    end
  end

  describe "set operation execution" do
    setup do
      # Create users in main table
      for {name, age} <- [{"Alice", 25}, {"Bob", 30}, {"Carol", 35}] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: age
        })
        |> Ash.create!()
      end

      :ok
    end

    test "executes UNION query" do
      # UNION of users with age < 30 and users with age > 30
      sql = """
      SELECT t.name FROM users t WHERE t.age < 30
      UNION
      SELECT t.name FROM users t WHERE t.age > 30
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: rows}} ->
          names = Enum.map(rows, fn [name] -> name end) |> Enum.sort()
          # Alice (25) and Carol (35), Bob (30) excluded from both
          assert names == ["Alice", "Carol"]

        {:error, error} ->
          flunk("UNION query failed: #{inspect(error)}")
      end
    end

    test "executes UNION ALL query (includes duplicates)" do
      sql = """
      SELECT t.name FROM users t WHERE t.age <= 30
      UNION ALL
      SELECT t.name FROM users t WHERE t.age >= 30
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: rows}} ->
          # Alice (<=30), Bob (<=30 and >=30), Carol (>=30)
          # UNION ALL keeps duplicates, so Bob appears twice
          assert length(rows) == 4

        {:error, error} ->
          flunk("UNION ALL query failed: #{inspect(error)}")
      end
    end

    test "executes INTERSECT query" do
      sql = """
      SELECT t.name FROM users t WHERE t.age >= 25
      INTERSECT
      SELECT t.name FROM users t WHERE t.age <= 35
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: rows}} ->
          # All users are in range 25-35
          names = Enum.map(rows, fn [name] -> name end) |> Enum.sort()
          assert names == ["Alice", "Bob", "Carol"]

        {:error, error} ->
          flunk("INTERSECT query failed: #{inspect(error)}")
      end
    end

    test "executes EXCEPT query" do
      sql = """
      SELECT t.name FROM users t
      EXCEPT
      SELECT t.name FROM users t WHERE t.age > 30
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: rows}} ->
          # All users except Carol (age 35)
          names = Enum.map(rows, fn [name] -> name end) |> Enum.sort()
          assert names == ["Alice", "Bob"]

        {:error, error} ->
          flunk("EXCEPT query failed: #{inspect(error)}")
      end
    end
  end

  describe "Query module SQL generation" do
    test "generates window function SQL correctly" do
      query = %Query{
        resource: User,
        domain: AshXTDB.Test.Domain,
        table: "users",
        window_functions: [
          %{
            name: :row_num,
            function: :row_number,
            partition_by: [:organization_id],
            order_by: [{:age, :desc}]
          }
        ]
      }

      {sql, _params} = Query.to_sql(query, :select)

      assert sql =~ "ROW_NUMBER() OVER (PARTITION BY t.organization_id ORDER BY t.age DESC)"
      assert sql =~ "AS \"row_num\""
    end

    test "generates CTE SQL correctly" do
      inner_query = %Query{
        resource: User,
        domain: AshXTDB.Test.Domain,
        table: "users"
      }

      query = %Query{
        resource: User,
        domain: AshXTDB.Test.Domain,
        table: "active_users_cte",
        ctes: [%{name: "active_users_cte", query: inner_query}]
      }

      {sql, _params} = Query.to_sql(query, :select)

      assert sql =~ "WITH active_users_cte AS (SELECT"
    end

    test "generates UNION SQL correctly" do
      query1 = %Query{
        resource: User,
        domain: AshXTDB.Test.Domain,
        table: "users"
      }

      query2 = %Query{
        resource: User,
        domain: AshXTDB.Test.Domain,
        table: "archived_users"
      }

      combined = Query.union(query1, query2)
      {sql, _params} = Query.to_sql(combined, :select)

      assert sql =~ "FROM \"users\" t"
      assert sql =~ "UNION SELECT"
    end

    test "add_window_function helper works" do
      query =
        %Query{
          resource: User,
          domain: AshXTDB.Test.Domain,
          table: "users"
        }
        |> Query.add_window_function(%{
          name: :row_num,
          function: :row_number,
          order_by: [{:age, :asc}]
        })

      assert length(query.window_functions) == 1
      [window_fn] = query.window_functions
      assert window_fn.name == :row_num
      assert window_fn.function == :row_number
      assert window_fn.order_by == [{:age, :asc}]
    end

    test "add_cte helper works" do
      inner_query = %Query{
        resource: User,
        domain: AshXTDB.Test.Domain,
        table: "users"
      }

      query =
        %Query{
          resource: User,
          domain: AshXTDB.Test.Domain,
          table: "result"
        }
        |> Query.add_cte("my_cte", inner_query)

      assert length(query.ctes) == 1
      [cte] = query.ctes
      assert cte.name == "my_cte"
      assert cte.query == inner_query
      assert cte.query.table == "users"
    end
  end

  # Helper functions
  defp parse_int(nil), do: 0
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp parse_float(nil), do: 0.0
  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 0.0
    end
  end
end
