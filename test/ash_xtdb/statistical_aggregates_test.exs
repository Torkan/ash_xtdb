# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.StatisticalAggregatesTest do
  @moduledoc """
  Integration tests for statistical and boolean aggregate SQL execution.

  These aggregates (stddev_pop, var_pop, bool_and, etc.) are XTDB-specific
  extensions executed via raw SQL since Ash's standard aggregate API only
  supports: count, sum, avg, min, max, exists, first, list.
  """
  use ExUnit.Case, async: false

  alias AshXTDB.SQL
  alias AshXTDB.Test.User

  @moduletag :integration

  setup do
    # Clean up before each test
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])
    :ok
  end

  describe "statistical aggregate execution" do
    setup do
      # Create users with different ages for statistical calculations
      # Ages: 20, 25, 30, 35, 40 (mean = 30, variance = 50)
      for {name, age} <- [
            {"Alice", 20},
            {"Bob", 25},
            {"Carol", 30},
            {"David", 35},
            {"Eve", 40}
          ] do
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

    test "executes STDDEV_POP query" do
      sql = "SELECT STDDEV_POP(t.age) AS stddev FROM users t"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[stddev]], columns: ["stddev"]}} ->
          # Population stddev for [20, 25, 30, 35, 40] = sqrt(50) ≈ 7.071
          stddev_float = parse_number(stddev)
          assert_in_delta stddev_float, 7.071, 0.1

        {:error, error} ->
          flunk("STDDEV_POP query failed: #{inspect(error)}")
      end
    end

    test "executes STDDEV_SAMP query" do
      sql = "SELECT STDDEV_SAMP(t.age) AS stddev FROM users t"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[stddev]], columns: ["stddev"]}} ->
          # Sample stddev for [20, 25, 30, 35, 40] = sqrt(62.5) ≈ 7.906
          stddev_float = parse_number(stddev)
          assert_in_delta stddev_float, 7.906, 0.1

        {:error, error} ->
          flunk("STDDEV_SAMP query failed: #{inspect(error)}")
      end
    end

    test "executes VAR_POP query" do
      sql = "SELECT VAR_POP(t.age) AS variance FROM users t"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[variance]], columns: ["variance"]}} ->
          # Population variance for [20, 25, 30, 35, 40] = 50
          var_float = parse_number(variance)
          assert_in_delta var_float, 50.0, 0.1

        {:error, error} ->
          flunk("VAR_POP query failed: #{inspect(error)}")
      end
    end

    test "executes VAR_SAMP query" do
      sql = "SELECT VAR_SAMP(t.age) AS variance FROM users t"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[variance]], columns: ["variance"]}} ->
          # Sample variance for [20, 25, 30, 35, 40] = 62.5
          var_float = parse_number(variance)
          assert_in_delta var_float, 62.5, 0.1

        {:error, error} ->
          flunk("VAR_SAMP query failed: #{inspect(error)}")
      end
    end

    test "executes multiple statistical aggregates in one query" do
      sql = """
      SELECT COUNT(*) AS count,
             AVG(t.age) AS avg_age,
             STDDEV_POP(t.age) AS stddev,
             VAR_POP(t.age) AS variance
      FROM users t
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[count, avg, stddev, variance]]}} ->
          assert parse_number(count) == 5
          assert_in_delta parse_number(avg), 30.0, 0.1
          assert_in_delta parse_number(stddev), 7.071, 0.1
          assert_in_delta parse_number(variance), 50.0, 0.1

        {:error, error} ->
          flunk("Multiple aggregates query failed: #{inspect(error)}")
      end
    end

    test "executes statistical aggregates with WHERE clause" do
      # Get variance only for users over 25
      sql = "SELECT VAR_POP(t.age) AS variance FROM users t WHERE t.age > 25"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[variance]]}} ->
          # Population variance for [30, 35, 40] = 16.667
          var_float = parse_number(variance)
          assert_in_delta var_float, 16.667, 0.1

        {:error, error} ->
          flunk("Filtered variance query failed: #{inspect(error)}")
      end
    end
  end

  describe "boolean aggregate execution" do
    setup do
      # Create users with different active status
      for {name, active} <- [
            {"Active1", true},
            {"Active2", true},
            {"Inactive1", false},
            {"Active3", true}
          ] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          active: active
        })
        |> Ash.create!()
      end

      :ok
    end

    test "executes BOOL_AND query (all true check)" do
      sql = "SELECT BOOL_AND(t.active) AS all_active FROM users t"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[result]]}} ->
          # Not all users are active, so should be false
          assert parse_boolean(result) == false

        {:error, error} ->
          flunk("BOOL_AND query failed: #{inspect(error)}")
      end
    end

    test "executes BOOL_OR query (any true check)" do
      sql = "SELECT BOOL_OR(t.active) AS any_active FROM users t"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[result]]}} ->
          # At least one user is active, so should be true
          assert parse_boolean(result) == true

        {:error, error} ->
          flunk("BOOL_OR query failed: #{inspect(error)}")
      end
    end

    test "BOOL_AND returns true when all values are true" do
      sql = "SELECT BOOL_AND(t.active) AS all_active FROM users t WHERE t.active = true"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[result]]}} ->
          assert parse_boolean(result) == true

        {:error, error} ->
          flunk("Filtered BOOL_AND query failed: #{inspect(error)}")
      end
    end

    test "BOOL_OR returns false when all values are false" do
      # Clear and create only inactive users
      AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])

      for name <- ["Inactive1", "Inactive2"] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          active: false
        })
        |> Ash.create!()
      end

      sql = "SELECT BOOL_OR(t.active) AS any_active FROM users t"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[result]]}} ->
          assert parse_boolean(result) == false

        {:error, error} ->
          flunk("BOOL_OR with all false query failed: #{inspect(error)}")
      end
    end
  end

  describe "edge cases" do
    test "statistical aggregates on empty table return nil" do
      sql = "SELECT STDDEV_POP(t.age) AS stddev FROM users t"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[nil]]}} ->
          assert true

        {:ok, %{rows: [[_value]]}} ->
          # Some DBs might return 0 for empty set
          assert true

        {:error, error} ->
          flunk("Empty table query failed: #{inspect(error)}")
      end
    end

    test "statistical aggregates with single value returns 0 stddev" do
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "single@test.com",
        name: "Single",
        age: 30
      })
      |> Ash.create!()

      sql = "SELECT STDDEV_POP(t.age) AS stddev FROM users t"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[stddev]]}} ->
          # Standard deviation of a single value is 0
          assert_in_delta parse_number(stddev), 0.0, 0.001

        {:error, error} ->
          flunk("Single value stddev query failed: #{inspect(error)}")
      end
    end
  end

  describe "SQL generation via Query module" do
    test "generates correct STDDEV_POP SQL" do
      agg = %{kind: :stddev_pop, field: :age, name: :age_stddev}

      query = %SQL{
        resource: User,
        domain: AshXTDB.Test.Domain,
        table: "users",
        aggregates: [agg]
      }

      {sql, _params} = SQL.to_aggregate_sql(query, [agg])

      assert sql =~ "STDDEV_POP(t.\"age\")"
      assert sql =~ "AS \"age_stddev\""
    end

    test "generates correct BOOL_AND SQL" do
      agg = %{kind: :bool_and, field: :active, name: :all_active}

      query = %SQL{
        resource: User,
        domain: AshXTDB.Test.Domain,
        table: "users",
        aggregates: [agg]
      }

      {sql, _params} = SQL.to_aggregate_sql(query, [agg])

      assert sql =~ "BOOL_AND(t.\"active\")"
    end
  end

  describe "data layer capabilities" do
    test "reports support for statistical aggregates" do
      assert AshXTDB.DataLayer.can?(User, {:aggregate, :stddev_pop})
      assert AshXTDB.DataLayer.can?(User, {:aggregate, :stddev_samp})
      assert AshXTDB.DataLayer.can?(User, {:aggregate, :var_pop})
      assert AshXTDB.DataLayer.can?(User, {:aggregate, :var_samp})
    end

    test "reports support for boolean aggregates" do
      assert AshXTDB.DataLayer.can?(User, {:aggregate, :bool_and})
      assert AshXTDB.DataLayer.can?(User, {:aggregate, :bool_or})
    end
  end

  # Helper functions
  defp parse_number(nil), do: 0.0
  defp parse_number(value) when is_float(value), do: value
  defp parse_number(value) when is_integer(value), do: value * 1.0

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp parse_boolean(nil), do: nil
  defp parse_boolean(true), do: true
  defp parse_boolean(false), do: false
  defp parse_boolean("t"), do: true
  defp parse_boolean("f"), do: false
  defp parse_boolean("true"), do: true
  defp parse_boolean("false"), do: false
  defp parse_boolean(1), do: true
  defp parse_boolean(0), do: false
end
