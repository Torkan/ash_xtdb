# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SortNullsTest do
  @moduledoc """
  Integration tests for NULLS FIRST/LAST sort options.

  Tests verify that:
  - :asc_nils_first places NULL values before non-NULL values (ascending)
  - :asc_nils_last places NULL values after non-NULL values (ascending)
  - :desc_nils_first places NULL values before non-NULL values (descending)
  - :desc_nils_last places NULL values after non-NULL values (descending)

  NOTE: XTDB has a quirk where DESC reverses NULLS FIRST/LAST behavior.
  AshXTDB works around this by swapping the SQL keywords for DESC sorts.
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Test.User

  require Ash.Query

  @moduletag :integration

  setup do
    # Clean up the users table before each test
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])

    # Create users with mix of NULL and non-NULL ages
    users = [
      %{email: "alice@test.com", name: "Alice", age: 30},
      %{email: "bob@test.com", name: "Bob", age: nil},
      %{email: "carol@test.com", name: "Carol", age: 25},
      %{email: "david@test.com", name: "David", age: nil},
      %{email: "eve@test.com", name: "Eve", age: 40}
    ]

    created =
      for user <- users do
        User
        |> Ash.Changeset.for_create(:create, user)
        |> Ash.create!()
      end

    {:ok, users: created}
  end

  describe "NULLS FIRST with ascending sort" do
    test "places NULL values first when sorting ascending" do
      results =
        User
        |> Ash.Query.sort(age: :asc_nils_first)
        |> Ash.read!()

      names = Enum.map(results, & &1.name)

      # First two should be the ones with NULL age (Bob and David)
      # Order between NULLs is undefined, so check they're in first two positions
      assert Enum.take(names, 2) |> Enum.sort() == ["Bob", "David"]

      # Last three should be non-NULL values in ascending order: 25, 30, 40
      assert Enum.drop(names, 2) == ["Carol", "Alice", "Eve"]
    end
  end

  describe "NULLS LAST with ascending sort" do
    test "places NULL values last when sorting ascending" do
      results =
        User
        |> Ash.Query.sort(age: :asc_nils_last)
        |> Ash.read!()

      names = Enum.map(results, & &1.name)

      # First three should be non-NULL values in ascending order: 25, 30, 40
      assert Enum.take(names, 3) == ["Carol", "Alice", "Eve"]

      # Last two should be the ones with NULL age
      assert Enum.drop(names, 3) |> Enum.sort() == ["Bob", "David"]
    end
  end

  describe "NULLS FIRST with descending sort" do
    test "places NULL values first when sorting descending" do
      results =
        User
        |> Ash.Query.sort(age: :desc_nils_first)
        |> Ash.read!()

      names = Enum.map(results, & &1.name)

      # First two should be the ones with NULL age
      assert Enum.take(names, 2) |> Enum.sort() == ["Bob", "David"]

      # Last three should be non-NULL values in descending order: 40, 30, 25
      assert Enum.drop(names, 2) == ["Eve", "Alice", "Carol"]
    end
  end

  describe "NULLS LAST with descending sort" do
    test "places NULL values last when sorting descending" do
      results =
        User
        |> Ash.Query.sort(age: :desc_nils_last)
        |> Ash.read!()

      names = Enum.map(results, & &1.name)

      # First three should be non-NULL values in descending order: 40, 30, 25
      assert Enum.take(names, 3) == ["Eve", "Alice", "Carol"]

      # Last two should be the ones with NULL age
      assert Enum.drop(names, 3) |> Enum.sort() == ["Bob", "David"]
    end
  end

  describe "NULLS options with multiple sort fields" do
    setup do
      # Clean and recreate with more complex data
      AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])

      users = [
        %{email: "a@test.com", name: "A", age: 30, active: true},
        %{email: "b@test.com", name: "B", age: nil, active: true},
        %{email: "c@test.com", name: "C", age: 30, active: false},
        %{email: "d@test.com", name: "D", age: nil, active: false}
      ]

      for user <- users do
        User
        |> Ash.Changeset.for_create(:create, user)
        |> Ash.create!()
      end

      :ok
    end

    test "NULLS LAST works with secondary sort" do
      results =
        User
        |> Ash.Query.sort(age: :asc_nils_last, name: :asc)
        |> Ash.read!()

      names = Enum.map(results, & &1.name)

      # Age 30 first (A and C), then NULLs (B and D)
      # Within same age, sorted by name ascending
      assert names == ["A", "C", "B", "D"]
    end
  end

  describe "SQL generation verification" do
    test "generates correct SQL for asc_nils_first" do
      query = %AshXTDB.Query{
        resource: AshXTDB.Test.User,
        table: "users",
        sort: [{:age, :asc_nils_first}]
      }

      {sql, _params} = AshXTDB.Query.to_sql(query, :select)

      assert sql =~ "ORDER BY"
      assert sql =~ "ASC NULLS FIRST"
    end

    test "generates swapped SQL for desc_nils_first due to XTDB quirk" do
      # XTDB reverses NULLS FIRST/LAST for DESC, so we swap to compensate
      query = %AshXTDB.Query{
        resource: AshXTDB.Test.User,
        table: "users",
        sort: [{:age, :desc_nils_first}]
      }

      {sql, _params} = AshXTDB.Query.to_sql(query, :select)

      assert sql =~ "ORDER BY"
      # We generate "DESC NULLS LAST" to get "nulls first" behavior in XTDB
      assert sql =~ "DESC NULLS LAST"
    end

    test "generates swapped SQL for desc_nils_last due to XTDB quirk" do
      query = %AshXTDB.Query{
        resource: AshXTDB.Test.User,
        table: "users",
        sort: [{:age, :desc_nils_last}]
      }

      {sql, _params} = AshXTDB.Query.to_sql(query, :select)

      assert sql =~ "ORDER BY"
      # We generate "DESC NULLS FIRST" to get "nulls last" behavior in XTDB
      assert sql =~ "DESC NULLS FIRST"
    end
  end
end
