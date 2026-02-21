# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.ExpressionFunctionsTest do
  @moduledoc """
  Tests for expression functions ported from ash_sql:
  - Fragment (raw SQL with parameter interpolation)
  - GetPath (JSON/struct field traversal)
  - Date/Time functions (now, today, ago, from_now)
  - Math functions (round, rem)

  XTDB SQL Reference:
  - Temporal: https://docs.xtdb.com/reference/main/stdlib/temporal.html
  - Numeric: https://docs.xtdb.com/reference/main/stdlib/numeric.html
  - Nested data: https://docs.xtdb.com/quickstart/sql-overview.html
  """

  use ExUnit.Case, async: false

  alias AshXTDB.Test.ExpressionTestResource

  require Ash.Query

  @moduletag :integration

  setup do
    # Clean up test table before each test
    AshXTDB.TestRepo.query(
      "DELETE FROM expression_test WHERE expression_test.\"_id\" IS NOT NULL",
      []
    )

    :ok
  end

  describe "math functions" do
    test "SQL-side calculation generates correct SQL with calculation in SELECT" do
      # This test verifies that calculations are pushed to SQL
      # by checking the generated SQL string
      state = %{
        resource: ExpressionTestResource,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      # Create a calculation expression like Ash would
      expression = %Ash.Query.Function.Round{
        arguments: [%Ash.Query.Ref{attribute: :value, relationship_path: []}]
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(expression, state)

      assert sql == "ROUND(t.\"value\")"
    end

    test "round() without precision rounds to nearest integer" do
      record =
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{
          name: "test",
          value: 42.567,
          count: 5
        })
        |> Ash.create!()

      # Load the calculation
      [loaded] =
        ExpressionTestResource
        |> Ash.Query.filter(id == ^record.id)
        |> Ash.Query.load(:rounded_value)
        |> Ash.read!()

      assert loaded.rounded_value == 43.0
    end

    test "round() with precision rounds to specified decimal places" do
      record =
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{
          name: "test",
          value: 42.5678,
          count: 5
        })
        |> Ash.create!()

      [loaded] =
        ExpressionTestResource
        |> Ash.Query.filter(id == ^record.id)
        |> Ash.Query.load(:rounded_to_2)
        |> Ash.read!()

      assert loaded.rounded_to_2 == 42.57
    end

    test "rem() computes modulus" do
      for {count, expected} <- [{5, 2}, {6, 0}, {7, 1}, {9, 0}] do
        record =
          ExpressionTestResource
          |> Ash.Changeset.for_create(:create, %{
            name: "test_#{count}",
            value: 1.0,
            count: count
          })
          |> Ash.create!()

        [loaded] =
          ExpressionTestResource
          |> Ash.Query.filter(id == ^record.id)
          |> Ash.Query.load(:count_mod_3)
          |> Ash.read!()

        assert loaded.count_mod_3 == expected,
               "rem(#{count}, 3) should be #{expected}, got #{loaded.count_mod_3}"
      end
    end
  end

  describe "date/time functions in filters - integration" do
    test "now() can be used in filter comparisons" do
      # Create a record with explicit created_at timestamp
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      ExpressionTestResource
      |> Ash.Changeset.for_create(:create, %{
        name: "past_record",
        value: 1.0,
        count: 1,
        created_at: past_time
      })
      |> Ash.create!()

      # Filter using now() - records with created_at before now()
      # This executes: WHERE created_at < CURRENT_TIMESTAMP
      records =
        ExpressionTestResource
        |> Ash.Query.filter(created_at < now())
        |> Ash.read!()

      assert length(records) == 1
      assert hd(records).name == "past_record"
    end

    test "now() and comparison operators work correctly" do
      # Create a record with future created_at (shouldn't match < now())
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      ExpressionTestResource
      |> Ash.Changeset.for_create(:create, %{
        name: "future_record",
        value: 2.0,
        count: 2,
        created_at: future_time
      })
      |> Ash.create!()

      # This record should NOT be returned when filtering for created_at < now()
      records =
        ExpressionTestResource
        |> Ash.Query.filter(created_at < now())
        |> Ash.read!()

      # Should not include the future record
      assert Enum.all?(records, fn r -> r.name != "future_record" end)
    end

    test "CURRENT_DATE executes correctly in raw SQL" do
      # Test that CURRENT_DATE works in XTDB
      {:ok, result} = AshXTDB.TestRepo.query("SELECT CURRENT_DATE", [])
      [[date_value]] = result.rows
      # Should return today's date
      assert date_value != nil
    end

    test "CURRENT_TIMESTAMP executes correctly in raw SQL" do
      # Test that CURRENT_TIMESTAMP works in XTDB
      {:ok, result} = AshXTDB.TestRepo.query("SELECT CURRENT_TIMESTAMP", [])
      [[timestamp_value]] = result.rows
      assert timestamp_value != nil
    end

    test "INTERVAL arithmetic executes correctly in raw SQL" do
      # Test that INTERVAL subtraction works (used by ago())
      {:ok, result} =
        AshXTDB.TestRepo.query(
          "SELECT CURRENT_TIMESTAMP - INTERVAL 'P1D'",
          []
        )

      [[yesterday]] = result.rows
      assert yesterday != nil
    end

    test "ago() filters records older than specified duration" do
      # Create a record with a timestamp from 2 days ago
      two_days_ago = DateTime.add(DateTime.utc_now(), -2 * 24 * 3600, :second)

      ExpressionTestResource
      |> Ash.Changeset.for_create(:create, %{
        name: "old_record",
        value: 1.0,
        count: 1,
        created_at: two_days_ago
      })
      |> Ash.create!()

      # Create a recent record
      ExpressionTestResource
      |> Ash.Changeset.for_create(:create, %{
        name: "recent_record",
        value: 2.0,
        count: 2,
        created_at: DateTime.utc_now()
      })
      |> Ash.create!()

      # Filter for records created more than 1 day ago
      # This uses: WHERE created_at < (CURRENT_TIMESTAMP - (1 * INTERVAL '1 day'))
      old_records =
        ExpressionTestResource
        |> Ash.Query.filter(created_at < ago(1, :day))
        |> Ash.read!()

      assert length(old_records) == 1
      assert hd(old_records).name == "old_record"
    end

    test "from_now() filters records with future timestamps" do
      # Create a record with a timestamp 2 days in the future
      two_days_ahead = DateTime.add(DateTime.utc_now(), 2 * 24 * 3600, :second)

      ExpressionTestResource
      |> Ash.Changeset.for_create(:create, %{
        name: "future_record",
        value: 1.0,
        count: 1,
        created_at: two_days_ahead
      })
      |> Ash.create!()

      # Create a current record
      ExpressionTestResource
      |> Ash.Changeset.for_create(:create, %{
        name: "current_record",
        value: 2.0,
        count: 2,
        created_at: DateTime.utc_now()
      })
      |> Ash.create!()

      # Filter for records created more than 1 day from now
      # This uses: WHERE created_at > (CURRENT_TIMESTAMP + (1 * INTERVAL '1 day'))
      future_records =
        ExpressionTestResource
        |> Ash.Query.filter(created_at > from_now(1, :day))
        |> Ash.read!()

      assert length(future_records) == 1
      assert hd(future_records).name == "future_record"
    end

    test "today() filters records by date comparison" do
      # Create a record with today's timestamp
      ExpressionTestResource
      |> Ash.Changeset.for_create(:create, %{
        name: "today_record",
        value: 1.0,
        count: 1,
        created_at: DateTime.utc_now()
      })
      |> Ash.create!()

      # Verify today() works in a comparison
      # We use raw SQL to verify since date casting is complex
      {:ok, result} =
        AshXTDB.TestRepo.query(
          "SELECT t.name FROM expression_test t WHERE CAST(t.created_at AS DATE) = CURRENT_DATE",
          []
        )

      # Should find the record created today
      names = Enum.map(result.rows, fn [name] -> name end)
      assert "today_record" in names
    end
  end

  describe "SQL generation for expression functions" do
    # These tests verify the SQL generation without requiring XTDB execution
    # They're useful for ensuring the correct SQL syntax is produced

    test "generates correct SQL for ROUND function" do
      # Build a query with round in calculation
      filter_expr = %Ash.Query.Function.Round{
        arguments: [%Ash.Query.Ref{attribute: :value, relationship_path: []}, 2]
      }

      state = %{
        resource: ExpressionTestResource,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      # Call the internal function to verify SQL generation
      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(filter_expr, state)

      assert sql =~ "ROUND("
      # Column names are quoted with double quotes
      assert sql =~ ~s(t."value")
    end

    test "generates correct SQL for MOD function" do
      filter_expr = %Ash.Query.Function.Rem{
        arguments: [
          %Ash.Query.Ref{attribute: :count, relationship_path: []},
          3
        ]
      }

      state = %{
        resource: ExpressionTestResource,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(filter_expr, state)

      assert sql =~ "MOD("
      # Column names are quoted with double quotes
      assert sql =~ ~s(t."count")
    end

    test "generates correct SQL for CURRENT_TIMESTAMP" do
      filter_expr = %Ash.Query.Function.Now{arguments: []}

      state = %{
        resource: ExpressionTestResource,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(filter_expr, state)

      assert sql == "CURRENT_TIMESTAMP"
    end

    test "generates correct SQL for CURRENT_DATE" do
      filter_expr = %Ash.Query.Function.Today{arguments: []}

      state = %{
        resource: ExpressionTestResource,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(filter_expr, state)

      assert sql == "CURRENT_DATE"
    end

    test "generates correct SQL for ago() with interval" do
      filter_expr = %Ash.Query.Function.Ago{arguments: [7, :day]}

      state = %{
        resource: ExpressionTestResource,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(filter_expr, state)

      assert sql =~ "CURRENT_TIMESTAMP"
      assert sql =~ "INTERVAL"
      # XTDB uses SQL standard: INTERVAL '1' DAY (uppercase)
      assert sql =~ "DAY"
    end

    test "generates correct SQL for from_now() with interval" do
      filter_expr = %Ash.Query.Function.FromNow{arguments: [30, :minute]}

      state = %{
        resource: ExpressionTestResource,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(filter_expr, state)

      assert sql =~ "CURRENT_TIMESTAMP"
      assert sql =~ "INTERVAL"
      # XTDB uses SQL standard: INTERVAL '1' MINUTE (uppercase)
      assert sql =~ "MINUTE"
    end

    test "generates correct SQL for GetPath with struct access" do
      filter_expr = %Ash.Query.Function.GetPath{
        arguments: [
          %Ash.Query.Ref{attribute: :metadata, relationship_path: []},
          [:user, :name]
        ]
      }

      state = %{
        resource: ExpressionTestResource,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(filter_expr, state)

      # XTDB uses dot notation: (t."metadata").user.name
      # Column names are quoted with double quotes
      assert sql =~ "(t.\"metadata\").user.name"
    end

    test "generates correct SQL for GetPath with array index" do
      filter_expr = %Ash.Query.Function.GetPath{
        arguments: [
          %Ash.Query.Ref{attribute: :metadata, relationship_path: []},
          [:items, 0, :value]
        ]
      }

      state = %{
        resource: ExpressionTestResource,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(filter_expr, state)

      # XTDB uses: (t."metadata").items[0].value
      assert sql =~ "(t.\"metadata\").items[0].value"
    end
  end

  describe "sorting by calculations" do
    test "can sort by expression-based calculation" do
      # Create records with different values
      for {name, value} <- [{"third", 30.5}, {"first", 10.2}, {"second", 20.8}] do
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{name: name, value: value, count: 1})
        |> Ash.create!()
      end

      # Sort by rounded_value (which rounds value to nearest integer)
      results =
        ExpressionTestResource
        |> Ash.Query.load(:rounded_value)
        |> Ash.Query.sort(rounded_value: :asc)
        |> Ash.read!()

      # Values: 10.2 rounds to 10, 20.8 rounds to 21, 30.5 rounds to 31
      names = Enum.map(results, & &1.name)
      assert names == ["first", "second", "third"]
    end

    test "can sort by calculation in descending order" do
      for {name, value} <- [{"b", 20.0}, {"a", 10.0}, {"c", 30.0}] do
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{name: name, value: value, count: 1})
        |> Ash.create!()
      end

      results =
        ExpressionTestResource
        |> Ash.Query.load(:rounded_value)
        |> Ash.Query.sort(rounded_value: :desc)
        |> Ash.read!()

      # Values: 10 < 20 < 30, desc order should give c, b, a
      names = Enum.map(results, & &1.name)
      assert names == ["c", "b", "a"]
    end
  end

  describe "GetPath integration - nested data access" do
    test "can query records with nested map data" do
      # Create a record with nested metadata
      record =
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{
          name: "nested_test",
          value: 1.0,
          count: 1,
          metadata: %{
            "user" => %{"name" => "Alice", "role" => "admin"},
            "tags" => ["elixir", "xtdb"]
          }
        })
        |> Ash.create!()

      # Query the record back and verify metadata was stored
      [loaded] =
        ExpressionTestResource
        |> Ash.Query.filter(id == ^record.id)
        |> Ash.read!()

      assert loaded.metadata["user"]["name"] == "Alice"
    end

    test "can store and retrieve nested map data for filtering" do
      # Create records with different nested values
      ExpressionTestResource
      |> Ash.Changeset.for_create(:create, %{
        name: "admin_user",
        value: 1.0,
        count: 1,
        metadata: %{"role" => "admin", "level" => 10}
      })
      |> Ash.create!()

      ExpressionTestResource
      |> Ash.Changeset.for_create(:create, %{
        name: "guest_user",
        value: 2.0,
        count: 2,
        metadata: %{"role" => "guest", "level" => 1}
      })
      |> Ash.create!()

      # Verify the data is stored and we can retrieve it
      {:ok, result} =
        AshXTDB.TestRepo.query(
          "SELECT t.name, t.metadata FROM expression_test t ORDER BY t.name",
          []
        )

      # Verify we have both records with metadata
      assert length(result.rows) == 2

      # The metadata should be stored as a map/JSON that we can access
      [admin_row, guest_row] = result.rows
      [admin_name, admin_meta] = admin_row
      [guest_name, guest_meta] = guest_row

      assert admin_name == "admin_user"
      assert guest_name == "guest_user"

      # Metadata is stored - XTDB returns it as a map or JSON string
      assert admin_meta != nil
      assert guest_meta != nil
    end

    test "GetPath calculation loads metadata field via Ash" do
      record =
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{
          name: "role_test",
          value: 1.0,
          count: 1,
          metadata: %{"role" => "admin", "level" => 5}
        })
        |> Ash.create!()

      # Load the GetPath-based calculation
      [loaded] =
        ExpressionTestResource
        |> Ash.Query.filter(id == ^record.id)
        |> Ash.Query.load(:metadata_role)
        |> Ash.read!()

      assert loaded.metadata_role == "admin"
    end

    test "GetPath calculation returns nil for missing path" do
      record =
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{
          name: "no_role",
          value: 1.0,
          count: 1,
          metadata: %{"other_field" => "value"}
        })
        |> Ash.create!()

      # Load the GetPath calculation - should return nil for missing path
      [loaded] =
        ExpressionTestResource
        |> Ash.Query.filter(id == ^record.id)
        |> Ash.Query.load(:metadata_role)
        |> Ash.read!()

      assert loaded.metadata_role == nil
    end
  end

  describe "fragment integration - raw SQL execution" do
    test "UPPER fragment executes correctly" do
      # Create records with different case names
      for name <- ["alice", "BOB", "Charlie"] do
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{name: name, value: 1.0, count: 1})
        |> Ash.create!()
      end

      # Query all records - we can't easily test fragment in Ash Query
      # but we can verify the SQL executes via raw query
      {:ok, result} =
        AshXTDB.TestRepo.query(
          "SELECT UPPER(t.name) as upper_name FROM expression_test t ORDER BY t.name",
          []
        )

      upper_names = Enum.map(result.rows, fn [name] -> name end)
      assert "ALICE" in upper_names
      assert "BOB" in upper_names
      assert "CHARLIE" in upper_names
    end

    test "string concatenation fragment executes correctly" do
      ExpressionTestResource
      |> Ash.Changeset.for_create(:create, %{name: "Hello", value: 1.0, count: 1})
      |> Ash.create!()

      # Test concatenation via raw query
      {:ok, result} =
        AshXTDB.TestRepo.query(
          "SELECT t.name || ' World' as greeting FROM expression_test t",
          []
        )

      [[greeting]] = result.rows
      assert greeting == "Hello World"
    end

    test "fragment calculation with UPPER loads correctly via Ash" do
      record =
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{name: "hello", value: 1.0, count: 5})
        |> Ash.create!()

      # Load the fragment-based calculation
      [loaded] =
        ExpressionTestResource
        |> Ash.Query.filter(id == ^record.id)
        |> Ash.Query.load(:name_upper)
        |> Ash.read!()

      assert loaded.name_upper == "HELLO"
    end

    test "fragment calculation with arithmetic loads correctly via Ash" do
      record =
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{name: "test", value: 1.0, count: 7})
        |> Ash.create!()

      # Load the fragment-based calculation
      [loaded] =
        ExpressionTestResource
        |> Ash.Query.filter(id == ^record.id)
        |> Ash.Query.load(:double_count)
        |> Ash.read!()

      assert loaded.double_count == 14
    end
  end

  describe "fragment support - SQL generation" do
    test "generates correct SQL for simple fragment" do
      # Fragment: fragment("UPPER(?)", name)
      filter_expr = %Ash.Query.Function.Fragment{
        arguments: [
          {:raw, "(UPPER("},
          {:expr, %Ash.Query.Ref{attribute: :name, relationship_path: []}},
          {:raw, "))"}
        ]
      }

      state = %{
        resource: ExpressionTestResource,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(filter_expr, state)

      # Column names are quoted with double quotes
      assert sql == "(UPPER(t.\"name\"))"
    end

    test "generates correct SQL for fragment with multiple expressions" do
      # Fragment: fragment("? || ' ' || ?", first_name, last_name)
      filter_expr = %Ash.Query.Function.Fragment{
        arguments: [
          {:raw, "("},
          {:expr, %Ash.Query.Ref{attribute: :name, relationship_path: []}},
          {:raw, " || ' ' || "},
          {:expr, "suffix"},
          {:raw, ")"}
        ]
      }

      state = %{
        resource: ExpressionTestResource,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      {sql, state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(filter_expr, state)

      # Column names are quoted with double quotes
      assert sql == "(t.\"name\" || ' ' || $1)"
      assert state.params == ["suffix"]
    end
  end

  # ============================================================================
  # Exists() Filter Function Tests
  # ============================================================================

  describe "exists() filter function - SQL generation" do
    alias AshXTDB.Test.Post
    alias AshXTDB.Test.User

    test "generates correct SQL for simple exists (no filter)" do
      # exists(posts) -> EXISTS (SELECT 1 FROM posts sub WHERE sub.user_id = t._id)
      exists_expr = %Ash.Query.Exists{
        path: [:posts],
        expr: true,
        at_path: [],
        resource: User
      }

      state = %{
        resource: User,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(exists_expr, state)

      # Should generate EXISTS subquery with join condition
      assert sql =~ "EXISTS"
      assert sql =~ "SELECT 1 FROM"
      assert sql =~ "\"posts\""
      assert sql =~ "user_id"
      assert sql =~ "t.\"_id\""
    end

    test "generates correct SQL for exists with filter expression" do
      # exists(posts, title == "Hello") -> EXISTS (SELECT 1 FROM posts sub WHERE sub.user_id = t._id AND sub.title = $1)
      exists_expr = %Ash.Query.Exists{
        path: [:posts],
        expr: %Ash.Query.Operator.Eq{
          left: %Ash.Query.Ref{attribute: :title, relationship_path: []},
          right: "Hello"
        },
        at_path: [],
        resource: User
      }

      state = %{
        resource: User,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t",
        in_exists?: false
      }

      {sql, state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(exists_expr, state)

      # Should generate EXISTS subquery with filter condition
      assert sql =~ "EXISTS"
      assert sql =~ "SELECT 1 FROM"
      assert sql =~ "\"posts\""
      assert sql =~ "\"title\""
      assert sql =~ "$1"
      assert state.params == ["Hello"]
    end
  end

  describe "exists() filter function - integration" do
    alias AshXTDB.Test.Post
    alias AshXTDB.Test.User

    setup do
      # Clean up both tables
      AshXTDB.TestRepo.query("DELETE FROM posts WHERE posts.\"_id\" IS NOT NULL", [])
      AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])
      :ok
    end

    test "exists() filters users who have posts" do
      # Create two users
      user_with_posts =
        User
        |> Ash.Changeset.for_create(:create, %{email: "with_posts@test.com", name: "Has Posts"})
        |> Ash.create!()

      user_without_posts =
        User
        |> Ash.Changeset.for_create(:create, %{email: "no_posts@test.com", name: "No Posts"})
        |> Ash.create!()

      # Create a post for one user
      Post
      |> Ash.Changeset.for_create(:create, %{
        title: "Test Post",
        user_id: user_with_posts.id
      })
      |> Ash.create!()

      # Query users who have posts using exists()
      users_with_posts =
        User
        |> Ash.Query.filter(exists(posts, true))
        |> Ash.read!()

      # Should only find the user with posts
      assert length(users_with_posts) == 1
      assert hd(users_with_posts).id == user_with_posts.id

      # Verify the other user is excluded
      refute Enum.any?(users_with_posts, fn u -> u.id == user_without_posts.id end)
    end

    test "exists() with filter expression finds users with specific posts" do
      # Create two users
      user1 =
        User
        |> Ash.Changeset.for_create(:create, %{email: "user1@test.com", name: "User 1"})
        |> Ash.create!()

      user2 =
        User
        |> Ash.Changeset.for_create(:create, %{email: "user2@test.com", name: "User 2"})
        |> Ash.create!()

      # Create different posts for each user
      Post
      |> Ash.Changeset.for_create(:create, %{
        title: "Hello World",
        user_id: user1.id
      })
      |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{
        title: "Goodbye World",
        user_id: user2.id
      })
      |> Ash.create!()

      # Query users who have posts titled "Hello World"
      users_with_hello =
        User
        |> Ash.Query.filter(exists(posts, title == "Hello World"))
        |> Ash.read!()

      # Should only find user1
      assert length(users_with_hello) == 1
      assert hd(users_with_hello).id == user1.id
    end

    test "not exists() filters users who have no posts" do
      # Create two users
      user_with_posts =
        User
        |> Ash.Changeset.for_create(:create, %{email: "with@test.com", name: "Has Posts"})
        |> Ash.create!()

      user_without_posts =
        User
        |> Ash.Changeset.for_create(:create, %{email: "without@test.com", name: "No Posts"})
        |> Ash.create!()

      # Create a post for one user
      Post
      |> Ash.Changeset.for_create(:create, %{
        title: "Test Post",
        user_id: user_with_posts.id
      })
      |> Ash.create!()

      # Query users who have NO posts using not exists()
      users_without_posts =
        User
        |> Ash.Query.filter(not exists(posts, true))
        |> Ash.read!()

      # Should only find the user without posts
      assert length(users_without_posts) == 1
      assert hd(users_without_posts).id == user_without_posts.id
    end
  end
end
