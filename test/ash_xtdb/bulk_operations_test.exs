# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.BulkOperationsTest do
  use ExUnit.Case, async: false

  alias AshXTDB.Test.User

  require Ash.Query
  require Ash.Expr

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

  describe "bulk_create error handling" do
    test "handles changeset with missing required field" do
      # Email is required (allow_nil? false)
      users_data = [
        %{name: "No Email User"}
      ]

      result =
        Ash.bulk_create(users_data, User, :create,
          return_records?: true,
          return_errors?: true
        )

      # Should have errors for the invalid record
      assert result.status in [:error, :partial_success]
      assert length(result.errors) > 0
    end

    test "handles mix of valid and invalid records" do
      users_data = [
        %{email: "valid1@test.com", name: "Valid 1"},
        # Missing required email
        %{name: "Invalid - No Email"},
        %{email: "valid2@test.com", name: "Valid 2"}
      ]

      result =
        Ash.bulk_create(users_data, User, :create,
          return_records?: false,
          return_errors?: true
        )

      # Should report some errors
      assert length(result.errors) > 0
    end
  end

  describe "bulk_create edge cases" do
    test "handles nil values in optional attributes" do
      users_data = [
        %{email: "nil_name@test.com", name: nil, age: nil},
        %{email: "nil_age@test.com", name: "Has Name", age: nil}
      ]

      result =
        Ash.bulk_create(users_data, User, :create,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 2

      # Verify records were created with nil values
      users = Ash.read!(User)
      assert length(users) == 2

      nil_name_user = Enum.find(users, &(&1.email == "nil_name@test.com"))
      assert nil_name_user.name == nil
      assert nil_name_user.age == nil

      has_name_user = Enum.find(users, &(&1.email == "nil_age@test.com"))
      assert has_name_user.name == "Has Name"
      assert has_name_user.age == nil
    end

    test "handles single record batch" do
      users_data = [
        %{email: "single@test.com", name: "Single User", age: 25}
      ]

      result =
        Ash.bulk_create(users_data, User, :create,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 1

      [user] = Ash.read!(User)
      assert user.email == "single@test.com"
    end

    test "handles large batch efficiently" do
      users_data =
        for i <- 1..500 do
          %{
            email: "large_batch_#{i}@test.com",
            name: "User #{i}",
            age: rem(i, 80) + 18
          }
        end

      result =
        Ash.bulk_create(users_data, User, :create,
          return_records?: false,
          return_errors?: true
        )

      assert result.status == :success

      # Verify all records were created
      users = Ash.read!(User)
      assert length(users) == 500
    end
  end

  describe "update_query with atomic expressions" do
    test "increments age using atomic expression" do
      # Create users with various ages
      for {name, age} <- [{"Alice", 25}, {"Bob", 30}, {"Charlie", 35}] do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "#{String.downcase(name)}_atomic@test.com",
          name: name,
          age: age
        })
        |> Ash.create!()
      end

      # Atomic update: increment age by 5 for all users
      result =
        User
        |> Ash.bulk_update(:update, %{},
          return_records?: false,
          strategy: :atomic,
          atomic_update: %{age: Ash.Expr.expr(age + 5)}
        )

      assert result.status == :success

      # Verify ages were incremented
      users = Ash.read!(User) |> Enum.sort_by(& &1.name)

      alice = Enum.find(users, &(&1.name == "Alice"))
      assert alice.age == 30

      bob = Enum.find(users, &(&1.name == "Bob"))
      assert bob.age == 35

      charlie = Enum.find(users, &(&1.name == "Charlie"))
      assert charlie.age == 40
    end

    test "updates with both regular changes and atomic expressions" do
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "combined@test.com",
        name: "Original",
        age: 25
      })
      |> Ash.create!()

      result =
        User
        |> Ash.Query.filter(email == "combined@test.com")
        |> Ash.bulk_update(:update, %{name: "Updated"},
          return_records?: false,
          strategy: :atomic,
          atomic_update: %{age: Ash.Expr.expr(age * 2)}
        )

      assert result.status == :success

      [user] = Ash.read!(User)
      assert user.name == "Updated"
      assert user.age == 50
    end
  end

  describe "update_query early return" do
    test "update with no changes returns early successfully" do
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "nochange@test.com",
        name: "No Change",
        age: 25
      })
      |> Ash.create!()

      # Update with empty changes - should hit early return path
      result =
        User
        |> Ash.Query.filter(email == "nochange@test.com")
        |> Ash.bulk_update(:update, %{},
          return_records?: false,
          strategy: :atomic
        )

      assert result.status == :success

      # User should be unchanged
      [user] = Ash.read!(User)
      assert user.name == "No Change"
      assert user.age == 25
    end

    test "update with return_records true and no changes" do
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "nochange_return@test.com",
        name: "No Change Return",
        age: 30
      })
      |> Ash.create!()

      result =
        User
        |> Ash.Query.filter(email == "nochange_return@test.com")
        |> Ash.bulk_update(:update, %{},
          return_records?: true,
          strategy: :atomic
        )

      assert result.status == :success
    end
  end

  describe "destroy_query edge cases" do
    test "destroy with return_records option" do
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "destroy_return@test.com",
        name: "To Destroy"
      })
      |> Ash.create!()

      users_to_delete = Ash.read!(User)

      result =
        Ash.bulk_destroy(users_to_delete, :destroy, %{},
          resource: User,
          return_records?: true,
          return_errors?: true,
          strategy: [:stream],
          authorize?: false
        )

      assert result.status == :success

      # XTDB doesn't support RETURNING, so records list will be empty or
      # contain the pre-delete records depending on implementation
      users = Ash.read!(User)
      assert users == []
    end

    test "destroy empty list returns success" do
      result =
        Ash.bulk_destroy([], :destroy, %{},
          resource: User,
          return_records?: false,
          return_errors?: true,
          strategy: [:stream],
          authorize?: false
        )

      assert result.status == :success
    end

    test "destroy non-matching filter affects no records" do
      # Create a user
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "keep@test.com",
        name: "Keep Me",
        age: 25
      })
      |> Ash.create!()

      # Try to delete users matching impossible filter
      users_to_delete =
        User
        |> Ash.Query.filter(age > 1000)
        |> Ash.read!()

      result =
        Ash.bulk_destroy(users_to_delete, :destroy, %{},
          resource: User,
          return_errors?: true,
          strategy: [:stream],
          authorize?: false
        )

      assert result.status == :success

      # User should still exist
      users = Ash.read!(User)
      assert length(users) == 1
      assert hd(users).email == "keep@test.com"
    end
  end

  describe "bulk operations with boolean attribute" do
    test "bulk create with boolean active field" do
      users_data = [
        %{email: "active1@test.com", name: "Active", active: true},
        %{email: "inactive@test.com", name: "Inactive", active: false}
      ]

      result =
        Ash.bulk_create(users_data, User, :create,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert length(result.records) == 2

      users = Ash.read!(User)
      active_user = Enum.find(users, &(&1.email == "active1@test.com"))
      inactive_user = Enum.find(users, &(&1.email == "inactive@test.com"))

      assert active_user.active == true
      assert inactive_user.active == false
    end

    test "bulk update boolean field" do
      # Create an active user
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "toggle@test.com",
        name: "Toggle",
        active: true
      })
      |> Ash.create!()

      # Bulk update to deactivate
      result =
        User
        |> Ash.Query.filter(email == "toggle@test.com")
        |> Ash.bulk_update(:update, %{active: false},
          return_records?: false,
          strategy: :atomic
        )

      assert result.status == :success

      [user] = Ash.read!(User)
      assert user.active == false
    end
  end
end
