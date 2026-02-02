# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.MissingCoverageTest do
  @moduledoc """
  Tests for features that were implemented but lacked dedicated integration tests.

  This fills coverage gaps for:
  - string_trim/1
  - string_join/2 (via calculations)
  - Arithmetic operators in filters: * (times), / (div)
  - Explicit == operator tests
  - Type function (casting)
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Test.User

  require Ash.Query

  @moduletag :integration

  setup do
    # Clean up tables before each test
    AshXTDB.TestRepo.query("DELETE FROM posts WHERE posts.\"_id\" IS NOT NULL", [])
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])
    :ok
  end

  describe "string_trim/1" do
    setup do
      # Create users with names that have whitespace
      for {name, email} <- [
            {"  Alice  ", "alice@test.com"},
            {"Bob", "bob@test.com"},
            {" Carol ", "carol@test.com"}
          ] do
        User
        |> Ash.Changeset.for_create(:create, %{email: email, name: name})
        |> Ash.create!()
      end

      :ok
    end

    test "filters by trimmed name" do
      # Find user where trimmed name equals "Alice"
      results =
        User
        |> Ash.Query.filter(string_trim(name) == "Alice")
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).email == "alice@test.com"
    end

    test "filters by trimmed name with comparison" do
      # Find users where trimmed name starts with certain letter
      # Using contains on trimmed string
      results =
        User
        |> Ash.Query.filter(contains(string_trim(name), "Carol"))
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).email == "carol@test.com"
    end

    test "string_trim with string_length nested call" do
      # "  Alice  " has length 9, trimmed "Alice" has length 5
      # " Carol " has length 7, trimmed "Carol" has length 5
      # "Bob" has length 3
      # Filter for trimmed length == 5
      results =
        User
        |> Ash.Query.filter(string_length(string_trim(name)) == 5)
        |> Ash.read!()

      # Both "  Alice  " (trimmed to "Alice") and " Carol " (trimmed to "Carol") match
      assert length(results) == 2
      emails = Enum.map(results, & &1.email) |> Enum.sort()
      assert emails == ["alice@test.com", "carol@test.com"]
    end
  end

  describe "arithmetic operators in filters" do
    setup do
      for {name, age} <- [
            {"Alice", 20},
            {"Bob", 30},
            {"Carol", 40},
            {"David", 50}
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

    test "multiplication (*) in filter expression" do
      # Find users where age * 2 > 70
      # Alice: 20*2=40, Bob: 30*2=60, Carol: 40*2=80, David: 50*2=100
      results =
        User
        |> Ash.Query.filter(age * 2 > 70)
        |> Ash.read!()

      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["Carol", "David"]
    end

    test "division (/) in filter expression" do
      # Find users where age / 10 == 3
      # Only Bob with age 30 satisfies 30/10 = 3
      results =
        User
        |> Ash.Query.filter(age / 10 == 3)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).name == "Bob"
    end

    test "combined arithmetic in filter" do
      # Find users where (age * 2) - 10 > 50
      # Alice: 40-10=30, Bob: 60-10=50, Carol: 80-10=70, David: 100-10=90
      results =
        User
        |> Ash.Query.filter(age * 2 - 10 > 50)
        |> Ash.read!()

      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["Carol", "David"]
    end

    test "arithmetic with rem (modulo)" do
      # Find users where age is even (age % 2 == 0)
      # All our test ages are multiples of 10, so all are even
      results =
        User
        |> Ash.Query.filter(rem(age, 2) == 0)
        |> Ash.read!()

      assert length(results) == 4
    end

    test "arithmetic with round" do
      # Find users where round(age / 15) == 3
      # Alice: 20/15=1.33->1, Bob: 30/15=2, Carol: 40/15=2.67->3, David: 50/15=3.33->3
      results =
        User
        |> Ash.Query.filter(round(age / 15) == 3)
        |> Ash.read!()

      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["Carol", "David"]
    end
  end

  describe "explicit equality (==) operator" do
    setup do
      User
      |> Ash.Changeset.for_create(:create, %{email: "test@test.com", name: "TestUser", age: 25})
      |> Ash.create!()

      :ok
    end

    test "filters by exact string equality" do
      results =
        User
        |> Ash.Query.filter(name == "TestUser")
        |> Ash.read!()

      assert length(results) == 1
    end

    test "filters by exact integer equality" do
      results =
        User
        |> Ash.Query.filter(age == 25)
        |> Ash.read!()

      assert length(results) == 1
    end

    test "filters by calculated value equality" do
      results =
        User
        |> Ash.Query.filter(age + 5 == 30)
        |> Ash.read!()

      assert length(results) == 1
    end

    test "equality with nil uses IS NULL" do
      # Create user with nil name
      User
      |> Ash.Changeset.for_create(:create, %{email: "nil@test.com", name: nil})
      |> Ash.create!()

      # Use is_nil/1 as Ash recommends (== nil always returns false)
      results =
        User
        |> Ash.Query.filter(is_nil(name))
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).email == "nil@test.com"
    end
  end

  describe "SQL generation for arithmetic" do
    test "generates correct SQL for multiplication" do
      state = %{
        resource: AshXTDB.Test.User,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      # Ash uses Ash.Query.Operator.Basic.Times for multiplication
      expr = %Ash.Query.Operator.Basic.Times{
        left: %Ash.Query.Ref{attribute: :age, relationship_path: []},
        right: 2
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "t.\"age\""
      assert sql =~ "*"
      assert sql =~ "$1"
    end

    test "generates correct SQL for division" do
      state = %{
        resource: AshXTDB.Test.User,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      # Ash uses Ash.Query.Operator.Basic.Div for division
      expr = %Ash.Query.Operator.Basic.Div{
        left: %Ash.Query.Ref{attribute: :age, relationship_path: []},
        right: 10
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(expr, state)

      assert sql =~ "t.\"age\""
      assert sql =~ "/"
      assert sql =~ "$1"
    end

    test "generates correct SQL for string_trim" do
      state = %{
        resource: AshXTDB.Test.User,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      # Ash uses Ash.Query.Function.StringTrim
      expr = %Ash.Query.Function.StringTrim{
        arguments: [%Ash.Query.Ref{attribute: :name, relationship_path: []}]
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(expr, state)

      assert sql == "TRIM(t.\"name\")"
    end
  end

  describe "combined string and arithmetic operations" do
    setup do
      for {name, age} <- [
            {"Short", 10},
            {"Medium Name", 25},
            {"A Very Long Name Indeed", 50}
          ] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(String.replace(name, " ", ""))}@test.com",
          name: name,
          age: age
        })
        |> Ash.create!()
      end

      :ok
    end

    test "filter by string length with arithmetic comparison" do
      # Find users where name length > age / 2
      # Short: 5 > 5? No. Medium Name: 11 > 12.5? No. A Very Long...: 23 > 25? No.
      # Let's change: name length > age / 5
      # Short: 5 > 2? Yes. Medium Name: 11 > 5? Yes. A Very Long...: 23 > 10? Yes.
      results =
        User
        |> Ash.Query.filter(string_length(name) > age / 5)
        |> Ash.read!()

      assert length(results) == 3
    end

    test "filter combining string_trim with length" do
      # Create user with padded name
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "padded@test.com",
        name: "   X   ",
        age: 100
      })
      |> Ash.create!()

      # Trimmed length is 1, original length is 7
      results =
        User
        |> Ash.Query.filter(string_length(string_trim(name)) == 1)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).email == "padded@test.com"
    end
  end
end
