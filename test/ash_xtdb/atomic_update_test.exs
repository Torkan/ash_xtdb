# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.AtomicUpdateTest do
  @moduledoc """
  Integration tests for atomic update functionality.

  Tests verify that:
  - Atomic increments work (counter = counter + 1)
  - Atomic expressions are evaluated in SQL
  - Multiple atomic updates work together
  - Atomic updates can be combined with regular updates
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Test.User

  require Ash.Query
  require Ash.Expr

  @moduletag :integration

  setup do
    # Clean up table before each test
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])

    # Create a user with initial age
    user =
      User
      |> Ash.Changeset.for_create(:create, %{email: "test@test.com", name: "Test User", age: 25})
      |> Ash.create!()

    {:ok, user: user}
  end

  describe "atomic increment" do
    test "can increment age atomically", %{user: user} do
      # Update using atomic expression
      {:ok, updated} =
        user
        |> Ash.Changeset.for_update(:update)
        |> Ash.Changeset.atomic_update(:age, Ash.Expr.expr(age + 1))
        |> Ash.update()

      # Reload to verify the update
      [reloaded] =
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.read!()

      assert reloaded.age == 26
    end

    test "can decrement age atomically", %{user: user} do
      {:ok, _updated} =
        user
        |> Ash.Changeset.for_update(:update)
        |> Ash.Changeset.atomic_update(:age, Ash.Expr.expr(age - 5))
        |> Ash.update()

      [reloaded] =
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.read!()

      assert reloaded.age == 20
    end

    test "can multiply age atomically", %{user: user} do
      {:ok, _updated} =
        user
        |> Ash.Changeset.for_update(:update)
        |> Ash.Changeset.atomic_update(:age, Ash.Expr.expr(age * 2))
        |> Ash.update()

      [reloaded] =
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.read!()

      assert reloaded.age == 50
    end
  end

  describe "atomic with regular updates" do
    test "can combine atomic and regular updates", %{user: user} do
      {:ok, _updated} =
        user
        |> Ash.Changeset.for_update(:update, %{name: "Updated Name"})
        |> Ash.Changeset.atomic_update(:age, Ash.Expr.expr(age + 10))
        |> Ash.update()

      [reloaded] =
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.read!()

      assert reloaded.name == "Updated Name"
      assert reloaded.age == 35
    end
  end

  describe "atomic conditional updates" do
    test "can use conditional expression", %{user: user} do
      # If age >= 25, set to 30, else keep current
      {:ok, _updated} =
        user
        |> Ash.Changeset.for_update(:update)
        |> Ash.Changeset.atomic_update(:age, Ash.Expr.expr(if(age >= 25, do: 30, else: age)))
        |> Ash.update()

      [reloaded] =
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.read!()

      assert reloaded.age == 30
    end
  end

  describe "bulk atomic update" do
    test "can update multiple records atomically", _context do
      # Create additional users
      User
      |> Ash.Changeset.for_create(:create, %{email: "user2@test.com", name: "User 2", age: 30})
      |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{email: "user3@test.com", name: "User 3", age: 35})
      |> Ash.create!()

      # Update all users atomically
      User
      |> Ash.Query.filter(age >= 25)
      |> Ash.bulk_update!(:update, %{}, [
        atomic_update: %{age: Ash.Expr.expr(age + 5)}
      ])

      # Verify all were updated
      users =
        User
        |> Ash.Query.filter(age >= 30)
        |> Ash.read!()

      # Original: 25->30, 30->35, 35->40, all should be >= 30 now
      assert length(users) == 3
      ages = Enum.map(users, & &1.age) |> Enum.sort()
      assert ages == [30, 35, 40]
    end
  end
end
