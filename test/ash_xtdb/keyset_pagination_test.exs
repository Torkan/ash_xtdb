# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.KeysetPaginationTest do
  use ExUnit.Case, async: false

  alias AshXTDB.Test.User

  require Ash.Query

  setup do
    # Clean up the users table before each test
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])
    :ok
  end

  describe "keyset pagination" do
    test "paginates through records with after cursor" do
      # Create 10 users with different ages for sorting
      for i <- 1..10 do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "user#{String.pad_leading(Integer.to_string(i), 2, "0")}@test.com",
          name: "User #{i}",
          age: i * 10
        })
        |> Ash.create!()
      end

      # First page - get first 3 records sorted by age
      first_page =
        User
        |> Ash.Query.sort(age: :asc)
        |> Ash.read!(page: [limit: 3])

      assert length(first_page.results) == 3
      assert Enum.map(first_page.results, & &1.age) == [10, 20, 30]
      assert first_page.more? == true

      # Get the keyset from the last record of the first page
      last_record = List.last(first_page.results)
      after_cursor = last_record.__metadata__.keyset

      # Second page - use after cursor
      second_page =
        User
        |> Ash.Query.sort(age: :asc)
        |> Ash.read!(page: [limit: 3, after: after_cursor])

      assert length(second_page.results) == 3
      assert Enum.map(second_page.results, & &1.age) == [40, 50, 60]
      assert second_page.more? == true

      # Third page
      third_cursor = List.last(second_page.results).__metadata__.keyset

      third_page =
        User
        |> Ash.Query.sort(age: :asc)
        |> Ash.read!(page: [limit: 3, after: third_cursor])

      assert length(third_page.results) == 3
      assert Enum.map(third_page.results, & &1.age) == [70, 80, 90]

      # Fourth page - only 1 record left
      fourth_cursor = List.last(third_page.results).__metadata__.keyset

      fourth_page =
        User
        |> Ash.Query.sort(age: :asc)
        |> Ash.read!(page: [limit: 3, after: fourth_cursor])

      assert length(fourth_page.results) == 1
      assert Enum.map(fourth_page.results, & &1.age) == [100]
      # No more records after this
      assert fourth_page.more? == false
    end

    test "paginates backwards with before cursor" do
      # Create 10 users
      for i <- 1..10 do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "user#{String.pad_leading(Integer.to_string(i), 2, "0")}@test.com",
          name: "User #{i}",
          age: i * 10
        })
        |> Ash.create!()
      end

      # Get the last page first by sorting descending
      last_page =
        User
        |> Ash.Query.sort(age: :asc)
        |> Ash.read!(page: [limit: 3])

      assert Enum.map(last_page.results, & &1.age) == [10, 20, 30]

      # Get the keyset of the first record to use as "before" cursor
      first_record = hd(last_page.results)
      before_cursor = first_record.__metadata__.keyset

      # Try to get records before the first one (should be empty)
      previous_page =
        User
        |> Ash.Query.sort(age: :asc)
        |> Ash.read!(page: [limit: 3, before: before_cursor])

      # Should be empty since there are no records before age=10
      assert previous_page.results == []
    end

    test "handles descending sort order" do
      # Create 5 users
      for i <- 1..5 do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "user#{i}@test.com",
          name: "User #{i}",
          age: i * 10
        })
        |> Ash.create!()
      end

      # First page - descending order
      first_page =
        User
        |> Ash.Query.sort(age: :desc)
        |> Ash.read!(page: [limit: 2])

      assert length(first_page.results) == 2
      assert Enum.map(first_page.results, & &1.age) == [50, 40]

      # Second page
      after_cursor = List.last(first_page.results).__metadata__.keyset

      second_page =
        User
        |> Ash.Query.sort(age: :desc)
        |> Ash.read!(page: [limit: 2, after: after_cursor])

      assert length(second_page.results) == 2
      assert Enum.map(second_page.results, & &1.age) == [30, 20]
    end

    test "handles composite sort keys" do
      # Create users with same age but different names
      users_data = [
        %{email: "alice@test.com", name: "Alice", age: 30},
        %{email: "bob@test.com", name: "Bob", age: 30},
        %{email: "charlie@test.com", name: "Charlie", age: 25},
        %{email: "dave@test.com", name: "Dave", age: 30},
        %{email: "eve@test.com", name: "Eve", age: 25}
      ]

      for data <- users_data do
        User
        |> Ash.Changeset.for_create(:create, data)
        |> Ash.create!()
      end

      # Sort by age (asc) then name (asc)
      first_page =
        User
        |> Ash.Query.sort(age: :asc, name: :asc)
        |> Ash.read!(page: [limit: 2])

      assert length(first_page.results) == 2
      # Should get Charlie (25) and Eve (25) first, sorted by name
      assert Enum.map(first_page.results, & &1.name) == ["Charlie", "Eve"]

      # Second page
      after_cursor = List.last(first_page.results).__metadata__.keyset

      second_page =
        User
        |> Ash.Query.sort(age: :asc, name: :asc)
        |> Ash.read!(page: [limit: 2, after: after_cursor])

      assert length(second_page.results) == 2
      # Should get Alice (30) and Bob (30)
      assert Enum.map(second_page.results, & &1.name) == ["Alice", "Bob"]

      # Third page
      third_cursor = List.last(second_page.results).__metadata__.keyset

      third_page =
        User
        |> Ash.Query.sort(age: :asc, name: :asc)
        |> Ash.read!(page: [limit: 2, after: third_cursor])

      assert length(third_page.results) == 1
      # Should get Dave (30)
      assert Enum.map(third_page.results, & &1.name) == ["Dave"]
    end

    test "handles empty result set" do
      result =
        User
        |> Ash.Query.sort(age: :asc)
        |> Ash.read!(page: [limit: 10])

      assert result.results == []
      assert result.more? == false
    end

    test "works with filters combined with pagination" do
      # Create users
      for i <- 1..10 do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "user#{i}@test.com",
          name: "User #{i}",
          age: i * 10,
          active: rem(i, 2) == 0
        })
        |> Ash.create!()
      end

      # Paginate only active users
      first_page =
        User
        |> Ash.Query.filter(active == true)
        |> Ash.Query.sort(age: :asc)
        |> Ash.read!(page: [limit: 2])

      assert length(first_page.results) == 2
      # Active users have ages 20, 40, 60, 80, 100
      assert Enum.map(first_page.results, & &1.age) == [20, 40]

      # Second page of active users
      after_cursor = List.last(first_page.results).__metadata__.keyset

      second_page =
        User
        |> Ash.Query.filter(active == true)
        |> Ash.Query.sort(age: :asc)
        |> Ash.read!(page: [limit: 2, after: after_cursor])

      assert length(second_page.results) == 2
      assert Enum.map(second_page.results, & &1.age) == [60, 80]
    end
  end
end
