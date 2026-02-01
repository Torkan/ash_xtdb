# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.BulkOperationsTest do
  use ExUnit.Case, async: false

  alias AshXTDB.Test.User

  require Ash.Query

  setup do
    # Clean up the users table before each test
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])
    :ok
  end

  describe "bulk_create" do
    test "creates multiple records" do
      users_data = [
        %{email: "bulk1@test.com", name: "Bulk User 1", age: 25},
        %{email: "bulk2@test.com", name: "Bulk User 2", age: 30},
        %{email: "bulk3@test.com", name: "Bulk User 3", age: 35}
      ]

      result =
        Ash.bulk_create(users_data, User, :create,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 3

      # Verify records were persisted
      users = Ash.read!(User)
      assert length(users) == 3

      emails = Enum.map(users, & &1.email) |> Enum.sort()
      assert emails == ["bulk1@test.com", "bulk2@test.com", "bulk3@test.com"]
    end

    test "creates records without returning them" do
      users_data = [
        %{email: "noreturn1@test.com", name: "No Return 1"},
        %{email: "noreturn2@test.com", name: "No Return 2"}
      ]

      result =
        Ash.bulk_create(users_data, User, :create,
          return_records?: false,
          return_errors?: true
        )

      assert result.status == :success

      # Verify records were persisted
      users = Ash.read!(User)
      assert length(users) == 2
    end

    test "handles empty list" do
      result =
        Ash.bulk_create([], User, :create,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert result.records == []
    end

    test "creates many records efficiently" do
      users_data =
        for i <- 1..100 do
          %{email: "user#{i}@test.com", name: "User #{i}", age: rem(i, 50) + 20}
        end

      result =
        Ash.bulk_create(users_data, User, :create,
          return_records?: false,
          return_errors?: true
        )

      assert result.status == :success

      # Verify all records were created
      users = Ash.read!(User)
      assert length(users) == 100
    end
  end

  describe "Ash.bulk_update (update_query)" do
    test "updates records matching filter" do
      # Create some users
      for {name, age} <- [{"Alice", 25}, {"Bob", 30}, {"Charlie", 35}] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: age
        })
        |> Ash.create!()
      end

      # Update users over 28 years old
      result =
        User
        |> Ash.Query.filter(age > 28)
        |> Ash.bulk_update(:update, %{name: "Updated"},
          return_records?: true,
          strategy: :atomic
        )

      assert result.status == :success

      # Verify updates
      users = Ash.read!(User) |> Enum.sort_by(& &1.age)

      # Alice (25) should be unchanged
      alice = Enum.find(users, &(&1.email == "alice@test.com"))
      assert alice.name == "Alice"

      # Bob (30) and Charlie (35) should be updated
      bob = Enum.find(users, &(&1.email == "bob@test.com"))
      assert bob.name == "Updated"

      charlie = Enum.find(users, &(&1.email == "charlie@test.com"))
      assert charlie.name == "Updated"
    end

    test "updates all records when no filter" do
      # Create users
      for name <- ["Alice", "Bob"] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: 25
        })
        |> Ash.create!()
      end

      # Update all users
      result =
        User
        |> Ash.bulk_update(:update, %{age: 99},
          return_records?: false,
          strategy: :atomic
        )

      assert result.status == :success

      # Verify all ages updated
      users = Ash.read!(User)
      assert Enum.all?(users, &(&1.age == 99))
    end
  end

  describe "Ash.bulk_destroy (destroy_query)" do
    test "destroys records matching filter" do
      # Create users
      for {name, age} <- [{"Alice", 25}, {"Bob", 30}, {"Charlie", 35}] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: age
        })
        |> Ash.create!()
      end

      # Get users matching filter and destroy them
      users_to_delete =
        User
        |> Ash.Query.filter(age > 28)
        |> Ash.read!()

      result =
        Ash.bulk_destroy(users_to_delete, :destroy, %{},
          resource: User,
          return_errors?: true,
          strategy: [:stream],
          authorize?: false
        )

      assert result.status == :success

      # Only Alice should remain
      users = Ash.read!(User)
      assert length(users) == 1
      assert hd(users).name == "Alice"
    end

    test "destroys all records when no filter" do
      # Create users
      for name <- ["Alice", "Bob", "Charlie"] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name
        })
        |> Ash.create!()
      end

      # Verify users exist
      assert length(Ash.read!(User)) == 3

      # Get all users and delete them
      all_users = Ash.read!(User)

      result =
        Ash.bulk_destroy(all_users, :destroy, %{},
          resource: User,
          return_errors?: true,
          strategy: [:stream],
          authorize?: false
        )

      assert result.status == :success

      # No users should remain
      users = Ash.read!(User)
      assert users == []
    end

    test "handles destroy with complex filter" do
      # Create users
      for {name, age} <- [{"Alice", 25}, {"Bob", 30}, {"Charlie", 35}, {"Dave", 25}] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}@test.com",
          name: name,
          age: age
        })
        |> Ash.create!()
      end

      # Get users matching complex filter and delete them
      users_to_delete =
        User
        |> Ash.Query.filter(age == 25 or age > 32)
        |> Ash.read!()

      result =
        Ash.bulk_destroy(users_to_delete, :destroy, %{},
          resource: User,
          return_errors?: true,
          strategy: [:stream],
          authorize?: false
        )

      assert result.status == :success

      # Only Bob (30) should remain
      users = Ash.read!(User)
      assert length(users) == 1
      assert hd(users).name == "Bob"
    end
  end
end
