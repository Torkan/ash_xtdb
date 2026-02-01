# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.AggregatesTest do
  use ExUnit.Case, async: false

  alias AshXTDB.Test.User

  require Ash.Query

  setup do
    # Clean up the users table before each test
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])
    :ok
  end

  describe "count aggregate" do
    test "counts all records" do
      # Create some users
      for i <- 1..5 do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "user#{i}@test.com",
          name: "User #{i}",
          age: 20 + i
        })
        |> Ash.create!()
      end

      # Count all users
      assert {:ok, %{count: 5}} = Ash.aggregate(User, {:count, :count})
    end

    test "counts with filter" do
      # Create users with different ages
      for {name, age} <- [{"Alice", 25}, {"Bob", 30}, {"Charlie", 35}] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: age
        })
        |> Ash.create!()
      end

      # Count users over 28
      query = User |> Ash.Query.filter(age > 28)
      assert {:ok, %{count: 2}} = Ash.aggregate(query, {:count, :count})
    end
  end

  describe "sum aggregate" do
    test "sums a field" do
      # Create users with different ages
      for {name, age} <- [{"Alice", 25}, {"Bob", 30}, {"Charlie", 35}] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: age
        })
        |> Ash.create!()
      end

      # Sum all ages
      assert {:ok, %{total_age: 90}} = Ash.aggregate(User, {:total_age, :sum, field: :age})
    end
  end

  describe "avg aggregate" do
    test "averages a field" do
      # Create users with different ages
      for {name, age} <- [{"Alice", 20}, {"Bob", 30}, {"Charlie", 40}] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: age
        })
        |> Ash.create!()
      end

      # Average all ages
      assert {:ok, %{avg_age: avg}} = Ash.aggregate(User, {:avg_age, :avg, field: :age})
      assert_in_delta avg, 30.0, 0.01
    end
  end

  describe "min/max aggregates" do
    test "finds minimum value" do
      for {name, age} <- [{"Alice", 25}, {"Bob", 30}, {"Charlie", 35}] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: age
        })
        |> Ash.create!()
      end

      assert {:ok, %{min_age: 25}} = Ash.aggregate(User, {:min_age, :min, field: :age})
    end

    test "finds maximum value" do
      for {name, age} <- [{"Alice", 25}, {"Bob", 30}, {"Charlie", 35}] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: age
        })
        |> Ash.create!()
      end

      assert {:ok, %{max_age: 35}} = Ash.aggregate(User, {:max_age, :max, field: :age})
    end
  end

  describe "exists aggregate" do
    test "returns true when records exist" do
      User
      |> Ash.Changeset.for_create(:create, %{email: "exists@test.com", name: "Test"})
      |> Ash.create!()

      assert Ash.exists?(User) == true
    end

    test "returns false when no records exist" do
      assert Ash.exists?(User) == false
    end

    test "returns true/false based on filter" do
      User
      |> Ash.Changeset.for_create(:create, %{email: "young@test.com", name: "Young", age: 20})
      |> Ash.create!()

      # Should exist
      assert User |> Ash.Query.filter(age < 30) |> Ash.exists?() == true

      # Should not exist
      assert User |> Ash.Query.filter(age > 50) |> Ash.exists?() == false
    end
  end

  describe "multiple aggregates" do
    test "computes multiple aggregates in one query" do
      for {name, age} <- [{"Alice", 25}, {"Bob", 30}, {"Charlie", 35}] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: age
        })
        |> Ash.create!()
      end

      {:ok, result} =
        Ash.aggregate(User, [
          {:count, :count},
          {:sum_age, :sum, field: :age},
          {:min_age, :min, field: :age},
          {:max_age, :max, field: :age}
        ])

      assert result.count == 3
      assert result.sum_age == 90
      assert result.min_age == 25
      assert result.max_age == 35
    end
  end
end
