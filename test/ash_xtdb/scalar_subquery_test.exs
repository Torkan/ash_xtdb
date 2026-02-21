# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.ScalarSubqueryTest do
  @moduledoc """
  Tests to determine whether XTDB supports scalar aggregate subqueries.

  These are needed for inline aggregate evaluation inside EXISTS subqueries,
  e.g. `exists(organization, user_count > 0)` would need to generate:

      EXISTS (SELECT 1 FROM organizations sub0
        WHERE sub0._id = t.organization_id
        AND (SELECT COUNT(*) FROM users sub1 WHERE sub1.organization_id = sub0._id) > 0)
  """
  use ExUnit.Case, async: false

  setup do
    AshXTDB.TestRepo.query("DELETE FROM posts WHERE posts.\"_id\" IS NOT NULL", [])
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])

    # Create two users
    AshXTDB.TestRepo.query!(
      "INSERT INTO users (_id, name, email, age, active) VALUES ($1, $2, $3, $4, $5)",
      [Ash.UUID.generate(), "Alice", "alice@test.com", 30, true]
    )

    AshXTDB.TestRepo.query!(
      "INSERT INTO users (_id, name, email, age, active) VALUES ($1, $2, $3, $4, $5)",
      [Ash.UUID.generate(), "Bob", "bob@test.com", 25, true]
    )

    # Create a post for Alice only
    {:ok, %{rows: [[alice_id]]}} =
      AshXTDB.TestRepo.query("SELECT u._id FROM users u WHERE u.name = 'Alice'", [])

    AshXTDB.TestRepo.query!(
      "INSERT INTO posts (_id, title, user_id) VALUES ($1, $2, $3)",
      [Ash.UUID.generate(), "Alice's Post", alice_id]
    )

    :ok
  end

  describe "connection-level type casting via OIDs" do
    test "integers, booleans, and floats are cast at the connection level" do
      {:ok, result} =
        AshXTDB.TestRepo.query(
          "SELECT COUNT(*) AS cnt, 'hello' AS txt, true AS bool_val, 3.14 AS float_val, 42 AS int_val",
          []
        )

      [[cnt, txt, bool_val, float_val, int_val]] = result.rows

      assert is_integer(cnt)
      assert cnt >= 1
      assert is_binary(txt)
      assert txt == "hello"
      assert is_boolean(bool_val)
      assert bool_val == true
      assert is_float(float_val)
      assert_in_delta float_val, 3.14, 0.001
      assert is_integer(int_val)
      assert int_val == 42
    end

    test "resource columns are properly typed" do
      {:ok, result} =
        AshXTDB.TestRepo.query(
          "SELECT u._id, u.name, u.age, u.active FROM users u LIMIT 1",
          []
        )

      [[id, name, age, active]] = result.rows

      assert is_binary(id)
      assert is_binary(name)
      assert is_integer(age)
      assert is_boolean(active)
    end

    test "NULL values remain nil regardless of type OID" do
      {:ok, result} =
        AshXTDB.TestRepo.query(
          "SELECT NULL AS int_col, NULL AS bool_col, NULL AS txt_col",
          []
        )

      [[int_col, bool_col, txt_col]] = result.rows

      assert is_nil(int_col)
      assert is_nil(bool_col)
      assert is_nil(txt_col)
    end
  end

  describe "XTDB scalar subquery support" do
    test "scalar subquery in SELECT" do
      {:ok, result} =
        AshXTDB.TestRepo.query(
          "SELECT (SELECT COUNT(*) FROM users) AS user_count",
          []
        )

      assert result.num_rows == 1
      [[count]] = result.rows
      # Connection-level casting converts int8 (OID 20) to integer
      assert count == 2
    end

    test "scalar subquery in WHERE clause" do
      result =
        AshXTDB.TestRepo.query(
          "SELECT 1 AS v WHERE (SELECT COUNT(*) FROM users) > 0",
          []
        )

      case result do
        {:ok, r} -> assert r.num_rows == 1
        {:error, err} -> flunk("Scalar subquery in WHERE not supported: #{inspect(err)}")
      end
    end

    test "correlated scalar subquery in WHERE" do
      # This is the pattern we need: count related records per parent row
      result =
        AshXTDB.TestRepo.query(
          """
          SELECT u._id, u.name
          FROM users u
          WHERE (SELECT COUNT(*) FROM posts p WHERE p.user_id = u._id) > 0
          """,
          []
        )

      case result do
        {:ok, r} ->
          assert r.num_rows == 1
          [[_id, name]] = r.rows
          assert name == "Alice"

        {:error, err} ->
          flunk("Correlated scalar subquery not supported: #{inspect(err)}")
      end
    end

    test "correlated scalar subquery inside EXISTS" do
      # This is the exact pattern: inside an EXISTS, use a scalar subquery
      # for an aggregate on the inner resource
      result =
        AshXTDB.TestRepo.query(
          """
          SELECT u._id, u.name
          FROM users u
          WHERE EXISTS (
            SELECT 1 FROM users u2
            WHERE u2._id = u._id
            AND (SELECT COUNT(*) FROM posts p WHERE p.user_id = u2._id) > 0
          )
          """,
          []
        )

      case result do
        {:ok, r} ->
          assert r.num_rows == 1
          [[_id, name]] = r.rows
          assert name == "Alice"

        {:error, err} ->
          flunk("Scalar subquery inside EXISTS not supported: #{inspect(err)}")
      end
    end
  end
end
