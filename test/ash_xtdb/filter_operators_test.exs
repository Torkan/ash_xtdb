# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.FilterOperatorsTest do
  use ExUnit.Case, async: false

  alias AshXTDB.Test.User

  require Ash.Query

  @moduletag :integration

  setup do
    # Clean up the users table before each test
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])
    :ok
  end

  describe "range queries (simulating BETWEEN)" do
    setup do
      # Create users with different ages
      for {name, age} <- [{"Young", 18}, {"Adult", 30}, {"Senior", 65}, {"Elder", 80}] do
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

    test "filters records within integer range using compound comparison" do
      # Filter users between ages 25 and 70 (Ash uses >= and <= operators)
      users =
        User
        |> Ash.Query.filter(age >= 25 and age <= 70)
        |> Ash.read!()

      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Adult", "Senior"]
    end

    test "filters records within range including boundaries" do
      # Filter users between ages 18 and 30 (inclusive)
      users =
        User
        |> Ash.Query.filter(age >= 18 and age <= 30)
        |> Ash.read!()

      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Adult", "Young"]
    end
  end

  describe "LIKE operator with contains" do
    setup do
      for name <- ["Alice Johnson", "Bob Smith", "Carol Jones", "David Johnson-Smith"] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(String.replace(name, " ", "."))}@test.com",
          name: name
        })
        |> Ash.create!()
      end

      :ok
    end

    test "filters records containing a substring using contains" do
      users =
        User
        |> Ash.Query.filter(contains(name, "Johnson"))
        |> Ash.read!()

      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Alice Johnson", "David Johnson-Smith"]
    end

    test "filters records containing case-sensitive substring" do
      users =
        User
        |> Ash.Query.filter(contains(name, "smith"))
        |> Ash.read!()

      # Should find none - case sensitive
      assert length(users) == 0
    end

    test "filters records containing partial match" do
      users =
        User
        |> Ash.Query.filter(contains(name, "Jones"))
        |> Ash.read!()

      assert length(users) == 1
      assert hd(users).name == "Carol Jones"
    end
  end

  # Note: Ash's built-in string functions are limited.
  # contains() is the primary string matching function available.
  # For more advanced pattern matching (starts_with, ends_with, regex),
  # applications would need to use fragment() or custom predicates.
end
