# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.TransactionsTest do
  use ExUnit.Case, async: false

  alias AshXTDB.Test.User

  require Ash.Query

  setup do
    # Clean up the users table before each test
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])
    :ok
  end

  describe "transaction/3" do
    test "commits successful transaction" do
      result =
        Ash.transaction([User], fn ->
          user1 =
            User
            |> Ash.Changeset.for_create(:create, %{email: "tx1@test.com", name: "TX User 1"})
            |> Ash.create!()

          user2 =
            User
            |> Ash.Changeset.for_create(:create, %{email: "tx2@test.com", name: "TX User 2"})
            |> Ash.create!()

          {user1, user2}
        end)

      assert {:ok, {user1, user2}} = result
      assert user1.email == "tx1@test.com"
      assert user2.email == "tx2@test.com"

      # Verify both users were persisted
      users = Ash.read!(User)
      assert length(users) == 2
    end

    test "returns error on exception but does not roll back XTDB operations" do
      # XTDB doesn't support multi-statement transactions via pgwire.
      # We use repo.run() instead of repo.transaction(), so each DML statement
      # executes immediately. Errors return {:error, ...} but operations
      # already executed are NOT rolled back.
      User
      |> Ash.Changeset.for_create(:create, %{email: "before@test.com", name: "Before"})
      |> Ash.create!()

      result =
        Ash.transaction([User], fn ->
          User
          |> Ash.Changeset.for_create(:create, %{email: "in_tx@test.com", name: "In TX"})
          |> Ash.create!()

          raise "Transaction error!"
        end)

      assert {:error, _} = result

      # Both users persist — XTDB has no transaction rollback
      users = Ash.read!(User)
      assert length(users) == 2
    end

    test "nested transactions work" do
      result =
        Ash.transaction([User], fn ->
          user1 =
            User
            |> Ash.Changeset.for_create(:create, %{email: "outer@test.com", name: "Outer"})
            |> Ash.create!()

          # Nested transaction (should use the same transaction)
          {:ok, user2} =
            Ash.transaction([User], fn ->
              User
              |> Ash.Changeset.for_create(:create, %{email: "inner@test.com", name: "Inner"})
              |> Ash.create!()
            end)

          {user1, user2}
        end)

      assert {:ok, {user1, user2}} = result
      assert user1.email == "outer@test.com"
      assert user2.email == "inner@test.com"

      users = Ash.read!(User)
      assert length(users) == 2
    end
  end

  describe "in_transaction?/1" do
    test "returns false outside transaction" do
      refute AshXTDB.DataLayer.in_transaction?(User)
    end

    test "returns true inside transaction" do
      Ash.transaction([User], fn ->
        assert AshXTDB.DataLayer.in_transaction?(User)
      end)
    end
  end

  describe "update within transaction" do
    test "updates are visible within same transaction" do
      result =
        Ash.transaction([User], fn ->
          # Create user
          user =
            User
            |> Ash.Changeset.for_create(:create, %{
              email: "update@test.com",
              name: "Original",
              age: 25
            })
            |> Ash.create!()

          # Update user in same transaction
          updated =
            user
            |> Ash.Changeset.for_update(:update, %{name: "Updated", age: 30})
            |> Ash.update!()

          updated
        end)

      assert {:ok, user} = result
      assert user.name == "Updated"
      assert user.age == 30

      # Verify the update persisted
      [persisted] = Ash.read!(User)
      assert persisted.name == "Updated"
      assert persisted.age == 30
    end
  end

  describe "destroy within transaction" do
    test "destroys are committed with transaction" do
      result =
        Ash.transaction([User], fn ->
          # Create user
          user =
            User
            |> Ash.Changeset.for_create(:create, %{email: "destroy@test.com", name: "ToDestroy"})
            |> Ash.create!()

          # Destroy in same transaction
          Ash.destroy!(user)

          :destroyed
        end)

      assert {:ok, :destroyed} = result

      # Verify user was destroyed
      users = Ash.read!(User)
      assert users == []
    end
  end

  describe "explicit rollback" do
    test "rollback causes transaction to fail and rolls back changes" do
      result =
        Ash.transaction([User], fn ->
          User
          |> Ash.Changeset.for_create(:create, %{email: "rollback@test.com", name: "ToRollback"})
          |> Ash.create!()

          # Explicitly rollback - the value gets wrapped through error conversion
          AshXTDB.TestRepo.rollback({:custom, "reason"})
        end)

      # The transaction returns an error (wrapped through error handling)
      assert {:error, _} = result

      # Most importantly - verify the user was not persisted (rollback worked)
      users = Ash.read!(User)
      assert length(users) == 0
    end

    test "rollback with atom value causes rollback" do
      result =
        Ash.transaction([User], fn ->
          User
          |> Ash.Changeset.for_create(:create, %{email: "rollback2@test.com", name: "ToRollback2"})
          |> Ash.create!()

          AshXTDB.TestRepo.rollback(:validation_failed)
        end)

      # Verify error returned
      assert {:error, _} = result

      # Verify the user was not persisted
      users = Ash.read!(User)
      assert length(users) == 0
    end

    test "rollback with string value causes rollback" do
      result =
        Ash.transaction([User], fn ->
          User
          |> Ash.Changeset.for_create(:create, %{email: "rollback3@test.com", name: "ToRollback3"})
          |> Ash.create!()

          AshXTDB.TestRepo.rollback("custom error message")
        end)

      assert {:error, _} = result

      users = Ash.read!(User)
      assert length(users) == 0
    end

    test "ash_rollback throw mechanism rolls back transaction" do
      # Test the data layer's :ash_rollback throw mechanism
      result =
        Ash.transaction([User], fn ->
          User
          |> Ash.Changeset.for_create(:create, %{email: "datalayer@test.com", name: "DataLayer"})
          |> Ash.create!()

          # Use throw with :ash_rollback tuple
          # Note: The value goes through Ash.Error conversion
          throw({:ash_rollback, {:my_error, "clean value"}})
        end)

      # The transaction returns an error
      assert {:error, _error} = result

      # Most importantly - verify the rollback worked
      users = Ash.read!(User)
      assert length(users) == 0
    end
  end

  describe "nested transaction error handling" do
    test "error in inner transaction rolls back everything" do
      # Create a user before transaction to verify rollback scope
      User
      |> Ash.Changeset.for_create(:create, %{email: "before_nested@test.com", name: "Before"})
      |> Ash.create!()

      result =
        Ash.transaction([User], fn ->
          # Create user in outer transaction
          User
          |> Ash.Changeset.for_create(:create, %{email: "outer_nested@test.com", name: "Outer"})
          |> Ash.create!()

          # Nested transaction that raises
          Ash.transaction([User], fn ->
            User
            |> Ash.Changeset.for_create(:create, %{email: "inner_nested@test.com", name: "Inner"})
            |> Ash.create!()

            raise "Inner transaction error!"
          end)
        end)

      assert {:error, _} = result

      # Only the user created before all transactions should exist
      users = Ash.read!(User)
      assert length(users) == 1
      assert hd(users).email == "before_nested@test.com"
    end

    test "deeply nested transactions all roll back on error" do
      User
      |> Ash.Changeset.for_create(:create, %{email: "before_deep@test.com", name: "Before"})
      |> Ash.create!()

      result =
        Ash.transaction([User], fn ->
          User
          |> Ash.Changeset.for_create(:create, %{email: "level1@test.com", name: "Level1"})
          |> Ash.create!()

          Ash.transaction([User], fn ->
            User
            |> Ash.Changeset.for_create(:create, %{email: "level2@test.com", name: "Level2"})
            |> Ash.create!()

            Ash.transaction([User], fn ->
              User
              |> Ash.Changeset.for_create(:create, %{
                email: "level3@test.com",
                name: "Level3"
              })
              |> Ash.create!()

              raise "Deep error!"
            end)
          end)
        end)

      assert {:error, _} = result

      # Only the initial user should exist
      users = Ash.read!(User)
      assert length(users) == 1
      assert hd(users).email == "before_deep@test.com"
    end
  end

  describe "return value variations" do
    test "transaction returns ok tuple value" do
      result =
        Ash.transaction([User], fn ->
          user =
            User
            |> Ash.Changeset.for_create(:create, %{email: "ok_tuple@test.com", name: "OK"})
            |> Ash.create!()

          {:ok, user}
        end)

      assert {:ok, {:ok, user}} = result
      assert user.email == "ok_tuple@test.com"
    end

    test "transaction returns error tuple value" do
      result =
        Ash.transaction([User], fn ->
          User
          |> Ash.Changeset.for_create(:create, %{email: "err_tuple@test.com", name: "Error"})
          |> Ash.create!()

          {:error, "business logic error"}
        end)

      # The transaction wraps the returned value in {:ok, ...}
      # because the transaction itself succeeded
      assert {:ok, {:error, "business logic error"}} = result

      # The user should still be persisted since the transaction didn't rollback
      users = Ash.read!(User)
      assert length(users) == 1
    end

    test "transaction returns plain value" do
      result =
        Ash.transaction([User], fn ->
          User
          |> Ash.Changeset.for_create(:create, %{email: "plain@test.com", name: "Plain"})
          |> Ash.create!()

          42
        end)

      assert {:ok, 42} = result
    end

    test "transaction returns nil" do
      result =
        Ash.transaction([User], fn ->
          User
          |> Ash.Changeset.for_create(:create, %{email: "nil_result@test.com", name: "Nil"})
          |> Ash.create!()

          nil
        end)

      assert {:ok, nil} = result

      # User should be persisted
      users = Ash.read!(User)
      assert length(users) == 1
    end

    test "transaction returns list" do
      result =
        Ash.transaction([User], fn ->
          users =
            for i <- 1..3 do
              User
              |> Ash.Changeset.for_create(:create, %{
                email: "list#{i}@test.com",
                name: "List#{i}"
              })
              |> Ash.create!()
            end

          users
        end)

      assert {:ok, users} = result
      assert length(users) == 3

      # Verify all were persisted
      persisted = Ash.read!(User)
      assert length(persisted) == 3
    end

    test "transaction returns map" do
      result =
        Ash.transaction([User], fn ->
          user =
            User
            |> Ash.Changeset.for_create(:create, %{email: "map@test.com", name: "Map"})
            |> Ash.create!()

          %{user: user, status: :created, count: 1}
        end)

      assert {:ok, %{user: user, status: :created, count: 1}} = result
      assert user.email == "map@test.com"
    end
  end

  describe "exception handling" do
    test "RuntimeError is caught and converted to error" do
      result =
        Ash.transaction([User], fn ->
          User
          |> Ash.Changeset.for_create(:create, %{email: "runtime@test.com", name: "Runtime"})
          |> Ash.create!()

          raise RuntimeError, message: "Something went wrong"
        end)

      assert {:error, error} = result
      # The error should be an Ash error wrapping the RuntimeError
      assert is_struct(error) or is_exception(error)

      # User should not be persisted
      users = Ash.read!(User)
      assert length(users) == 0
    end

    test "ArgumentError is caught and converted to error" do
      result =
        Ash.transaction([User], fn ->
          User
          |> Ash.Changeset.for_create(:create, %{email: "argument@test.com", name: "Argument"})
          |> Ash.create!()

          raise ArgumentError, message: "Invalid argument"
        end)

      assert {:error, error} = result
      assert is_struct(error) or is_exception(error)

      users = Ash.read!(User)
      assert length(users) == 0
    end

    test "custom exception is caught and converted to error" do
      defmodule CustomError do
        defexception [:message]
      end

      result =
        Ash.transaction([User], fn ->
          User
          |> Ash.Changeset.for_create(:create, %{email: "custom@test.com", name: "Custom"})
          |> Ash.create!()

          raise CustomError, message: "Custom error occurred"
        end)

      assert {:error, error} = result
      assert is_struct(error) or is_exception(error)

      users = Ash.read!(User)
      assert length(users) == 0
    end
  end
end
