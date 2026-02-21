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
      assert users == []
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

  describe "is_nil operator" do
    setup do
      # Create users with and without names
      User
      |> Ash.Changeset.for_create(:create, %{email: "with_name@test.com", name: "Alice"})
      |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{email: "no_name@test.com", name: nil})
      |> Ash.create!()

      :ok
    end

    test "filters records where field is nil" do
      users =
        User
        |> Ash.Query.filter(is_nil(name))
        |> Ash.read!()

      assert length(users) == 1
      assert hd(users).email == "no_name@test.com"
    end

    test "filters records where field is not nil" do
      users =
        User
        |> Ash.Query.filter(not is_nil(name))
        |> Ash.read!()

      assert length(users) == 1
      assert hd(users).email == "with_name@test.com"
    end
  end

  describe "not equal operator (!=)" do
    setup do
      for name <- ["Alice", "Bob", "Carol"] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name
        })
        |> Ash.create!()
      end

      :ok
    end

    test "filters records not equal to value" do
      users =
        User
        |> Ash.Query.filter(name != "Alice")
        |> Ash.read!()

      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Bob", "Carol"]
    end
  end

  describe "In operator" do
    setup do
      for name <- ["Alice", "Bob", "Carol", "David"] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name
        })
        |> Ash.create!()
      end

      :ok
    end

    test "filters records in a list of values" do
      users =
        User
        |> Ash.Query.filter(name in ["Alice", "Carol"])
        |> Ash.read!()

      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Carol"]
    end

    test "filters records in a list with single value" do
      users =
        User
        |> Ash.Query.filter(name in ["Bob"])
        |> Ash.read!()

      assert length(users) == 1
      assert hd(users).name == "Bob"
    end
  end

  describe "less than / greater than operators" do
    setup do
      for {name, age} <- [{"Alice", 20}, {"Bob", 30}, {"Carol", 40}] do
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

    test "filters with less than (<)" do
      users =
        User
        |> Ash.Query.filter(age < 35)
        |> Ash.read!()

      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob"]
    end

    test "filters with greater than (>)" do
      users =
        User
        |> Ash.Query.filter(age > 25)
        |> Ash.read!()

      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Bob", "Carol"]
    end

    test "filters with less than or equal (<=)" do
      users =
        User
        |> Ash.Query.filter(age <= 30)
        |> Ash.read!()

      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob"]
    end

    test "filters with greater than or equal (>=)" do
      users =
        User
        |> Ash.Query.filter(age >= 30)
        |> Ash.read!()

      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Bob", "Carol"]
    end
  end

  describe "Boolean AND/OR operators" do
    setup do
      for {name, age, active} <- [
            {"Alice", 20, true},
            {"Bob", 30, false},
            {"Carol", 40, true},
            {"David", 50, false}
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

    test "filters with AND (implicit in compound filter)" do
      users =
        User
        |> Ash.Query.filter(age > 25 and active == true)
        |> Ash.read!()

      assert length(users) == 1
      assert hd(users).name == "Carol"
    end

    test "filters with OR" do
      users =
        User
        |> Ash.Query.filter(age < 25 or age > 45)
        |> Ash.read!()

      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Alice", "David"]
    end

    test "filters with complex AND/OR combination" do
      users =
        User
        |> Ash.Query.filter((age < 25 or age > 35) and active == true)
        |> Ash.read!()

      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Carol"]
    end
  end
end
