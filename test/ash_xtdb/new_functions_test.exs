# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.NewFunctionsTest do
  @moduledoc """
  Tests for newly implemented functions:
  - string_position/2
  - date_add/3
  - start_of_day/1
  - floor/1, ceil/1, abs/1 (if Ash supports them)
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Test.User

  require Ash.Query

  @moduletag :integration

  setup do
    # Clean up the users table before each test
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])
    :ok
  end

  describe "string_position/2" do
    setup do
      for {name, email} <- [
            {"Hello World", "hello@test.com"},
            {"FooBar", "foobar@test.com"},
            {"NoMatch", "nomatch@test.com"}
          ] do
        User
        |> Ash.Changeset.for_create(:create, %{email: email, name: name})
        |> Ash.create!()
      end

      :ok
    end

    test "finds substring at beginning (position 0)" do
      # "Hello" starts at position 0 in "Hello World"
      results =
        User
        |> Ash.Query.filter(string_position(name, "Hello") == 0)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).name == "Hello World"
    end

    test "finds substring in middle" do
      # "Bar" starts at position 3 in "FooBar"
      results =
        User
        |> Ash.Query.filter(string_position(name, "Bar") == 3)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).name == "FooBar"
    end

    test "returns nil for non-matching substring" do
      # "XYZ" is not in any name, string_position returns nil
      results =
        User
        |> Ash.Query.filter(is_nil(string_position(name, "XYZ")))
        |> Ash.read!()

      assert length(results) == 3
    end

    test "filters by position greater than" do
      # Find names where "o" appears after position 2
      # "Hello World" has 'o' at 4, "FooBar" has 'o' at 1 and 2
      results =
        User
        |> Ash.Query.filter(string_position(name, "o") > 2)
        |> Ash.read!()

      # Only "Hello World" has first 'o' at position 4
      assert length(results) == 1
      assert hd(results).name == "Hello World"
    end
  end

  describe "date_add/3" do
    test "filters by date addition with days" do
      # Create a user
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "dated@test.com",
        name: "Dated User"
      })
      |> Ash.create!()

      # Filter where today + 7 days is in the future (always true)
      results =
        User
        |> Ash.Query.filter(date_add(today(), 7, :day) > today())
        |> Ash.read!()

      assert length(results) == 1
    end

    test "filters by date addition with negative value" do
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "dated2@test.com",
        name: "Dated User 2"
      })
      |> Ash.create!()

      # Filter where today - 7 days is in the past (always true)
      results =
        User
        |> Ash.Query.filter(date_add(today(), -7, :day) < today())
        |> Ash.read!()

      assert length(results) == 1
    end

    test "date_add with hours" do
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "hourly@test.com",
        name: "Hourly User"
      })
      |> Ash.create!()

      # now + 1 hour should be greater than now
      results =
        User
        |> Ash.Query.filter(date_add(now(), 1, :hour) > now())
        |> Ash.read!()

      assert length(results) == 1
    end
  end

  describe "start_of_day/1" do
    test "truncates datetime to start of day" do
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "startday@test.com",
        name: "Start Day User"
      })
      |> Ash.create!()

      # start_of_day(now()) should be <= now()
      results =
        User
        |> Ash.Query.filter(start_of_day(now()) <= now())
        |> Ash.read!()

      assert length(results) == 1
    end

    test "start_of_day equals today when comparing dates" do
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "startday2@test.com",
        name: "Start Day User 2"
      })
      |> Ash.create!()

      # start_of_day(now()) should have same date as today()
      # Note: Direct comparison may fail due to type differences, so we use >= and <
      results =
        User
        |> Ash.Query.filter(
          start_of_day(now()) >= date_add(today(), 0, :day) and
            start_of_day(now()) < date_add(today(), 1, :day)
        )
        |> Ash.read!()

      assert length(results) == 1
    end
  end

  describe "SQL generation verification" do
    test "string_position generates correct SQL" do
      state = %{
        resource: AshXTDB.Test.User,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      # Test with direct function struct
      expr = %Ash.Query.Function.StringPosition{
        arguments: [
          %Ash.Query.Ref{attribute: :name, relationship_path: []},
          "test"
        ]
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql(expr, state)

      assert sql =~ "POSITION"
      assert sql =~ "CASE WHEN"
      assert sql =~ "- 1"
    end

    test "date_add generates correct SQL" do
      state = %{
        resource: AshXTDB.Test.User,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      expr = %Ash.Query.Function.DateAdd{
        arguments: [
          %Ash.Query.Function.Today{arguments: []},
          7,
          :day
        ]
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql(expr, state)

      assert sql =~ "CURRENT_DATE"
      assert sql =~ "INTERVAL"
      assert sql =~ "DAY"
    end

    test "start_of_day generates correct SQL" do
      state = %{
        resource: AshXTDB.Test.User,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      expr = %Ash.Query.Function.StartOfDay{
        arguments: [
          %Ash.Query.Function.Now{arguments: []}
        ]
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql(expr, state)

      assert sql =~ "DATE_TRUNC"
      # XTDB uses unquoted DAY keyword, not 'day'
      assert sql =~ "DAY"
      assert sql =~ "CURRENT_TIMESTAMP"
    end
  end
end
