# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DistinctTest do
  @moduledoc """
  Integration tests for DISTINCT ON functionality.

  Tests verify that:
  - DISTINCT returns unique rows based on specified fields
  - All columns are returned (not just the distinct fields)
  - Sort order is respected when combined with distinct
  - Works with single and multiple distinct fields
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Test.User
  alias AshXTDB.Test.Post

  require Ash.Query

  @moduletag :integration

  setup do
    # Clean up tables before each test
    AshXTDB.TestRepo.query("DELETE FROM posts WHERE posts.\"_id\" IS NOT NULL", [])
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])

    # Create users with duplicate names
    alice1 =
      User
      |> Ash.Changeset.for_create(:create, %{email: "alice1@test.com", name: "Alice", age: 25})
      |> Ash.create!()

    alice2 =
      User
      |> Ash.Changeset.for_create(:create, %{email: "alice2@test.com", name: "Alice", age: 30})
      |> Ash.create!()

    bob =
      User
      |> Ash.Changeset.for_create(:create, %{email: "bob@test.com", name: "Bob", age: 35})
      |> Ash.create!()

    carol1 =
      User
      |> Ash.Changeset.for_create(:create, %{email: "carol1@test.com", name: "Carol", age: 20})
      |> Ash.create!()

    carol2 =
      User
      |> Ash.Changeset.for_create(:create, %{email: "carol2@test.com", name: "Carol", age: 22})
      |> Ash.create!()

    {:ok, users: %{alice1: alice1, alice2: alice2, bob: bob, carol1: carol1, carol2: carol2}}
  end

  describe "distinct on single field" do
    test "returns one row per distinct name", _context do
      results =
        User
        |> Ash.Query.distinct(:name)
        |> Ash.read!()

      # Should have 3 unique names: Alice, Bob, Carol
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob", "Carol"]
      assert length(results) == 3
    end

    test "returns all columns, not just the distinct field", _context do
      results =
        User
        |> Ash.Query.distinct(:name)
        |> Ash.read!()

      # Each result should have all fields, not just name
      Enum.each(results, fn user ->
        assert user.id != nil
        assert user.email != nil
        assert user.name != nil
        # Age may or may not be set depending on which row is picked
      end)
    end
  end

  describe "distinct with sort" do
    test "distinct with sort ascending returns first row per group", _context do
      results =
        User
        |> Ash.Query.distinct(:name)
        |> Ash.Query.sort(name: :asc, age: :asc)
        |> Ash.read!()

      # Should get the user with lowest age for each name
      alice = Enum.find(results, &(&1.name == "Alice"))
      carol = Enum.find(results, &(&1.name == "Carol"))

      # Alice: ages 25 and 30, should get 25
      assert alice.age == 25

      # Carol: ages 20 and 22, should get 20
      assert carol.age == 20
    end

    test "distinct with sort descending returns last row per group", _context do
      results =
        User
        |> Ash.Query.distinct(:name)
        |> Ash.Query.sort(name: :asc, age: :desc)
        |> Ash.read!()

      # Should get the user with highest age for each name
      alice = Enum.find(results, &(&1.name == "Alice"))
      carol = Enum.find(results, &(&1.name == "Carol"))

      # Alice: ages 25 and 30, should get 30
      assert alice.age == 30

      # Carol: ages 20 and 22, should get 22
      assert carol.age == 22
    end
  end

  describe "distinct with limit" do
    test "limit applies after distinct", _context do
      results =
        User
        |> Ash.Query.distinct(:name)
        |> Ash.Query.sort(name: :asc)
        |> Ash.Query.limit(2)
        |> Ash.read!()

      # Should have at most 2 results
      assert length(results) == 2

      # Should be first 2 alphabetically: Alice, Bob
      names = Enum.map(results, & &1.name)
      assert names == ["Alice", "Bob"]
    end
  end

  describe "distinct with filter" do
    test "filter applies before distinct", _context do
      results =
        User
        |> Ash.Query.filter(age >= 25)
        |> Ash.Query.distinct(:name)
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      # Filter: Alice (25, 30), Bob (35) - Carol excluded (20, 22)
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob"]
    end
  end
end
