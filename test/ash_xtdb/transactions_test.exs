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
      assert length(users) == 0
    end
  end
end
