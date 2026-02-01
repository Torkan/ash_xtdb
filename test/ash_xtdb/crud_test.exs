# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.CrudTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshXTDB.Test.User

  @moduletag :integration

  setup do
    # Clean up the users table before each test
    AshXTDB.TestRepo.query!("DELETE FROM users WHERE true")
    :ok
  end

  describe "create" do
    test "creates a record with all attributes" do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "test@example.com",
          name: "Test User",
          age: 30
        })
        |> Ash.create!()

      assert user.email == "test@example.com"
      assert user.name == "Test User"
      assert user.age == 30
      assert user.active == true
      assert user.id != nil
    end

    test "creates a record with minimal attributes" do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{email: "minimal@example.com"})
        |> Ash.create!()

      assert user.email == "minimal@example.com"
      assert user.name == nil
      assert user.id != nil
    end
  end

  describe "read" do
    test "reads all records" do
      User
      |> Ash.Changeset.for_create(:create, %{email: "user1@example.com", name: "User 1"})
      |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{email: "user2@example.com", name: "User 2"})
      |> Ash.create!()

      users = User |> Ash.read!()

      assert length(users) == 2
      emails = Enum.map(users, & &1.email) |> Enum.sort()
      assert emails == ["user1@example.com", "user2@example.com"]
    end

    test "reads a record by id" do
      created =
        User
        |> Ash.Changeset.for_create(:create, %{email: "byid@example.com"})
        |> Ash.create!()

      [found] =
        User
        |> Ash.Query.filter(id == ^created.id)
        |> Ash.read!()

      assert found.id == created.id
      assert found.email == "byid@example.com"
    end
  end

  describe "update" do
    test "updates a record" do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{email: "update@example.com", name: "Original"})
        |> Ash.create!()

      updated =
        user
        |> Ash.Changeset.for_update(:update, %{name: "Updated"})
        |> Ash.update!()

      assert updated.id == user.id
      assert updated.email == "update@example.com"
      assert updated.name == "Updated"
    end

    test "updates multiple attributes" do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{email: "multi@example.com", name: "Name", age: 25})
        |> Ash.create!()

      updated =
        user
        |> Ash.Changeset.for_update(:update, %{name: "New Name", age: 26, active: false})
        |> Ash.update!()

      assert updated.name == "New Name"
      assert updated.age == 26
      assert updated.active == false
    end
  end

  describe "destroy" do
    test "destroys a record" do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{email: "delete@example.com"})
        |> Ash.create!()

      :ok = Ash.destroy!(user)

      users =
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.read!()

      assert users == []
    end
  end

  describe "filter" do
    setup do
      User
      |> Ash.Changeset.for_create(:create, %{email: "alice@example.com", name: "Alice", age: 30})
      |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{email: "bob@example.com", name: "Bob", age: 25})
      |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{email: "carol@example.com", name: "Carol", age: 35})
      |> Ash.create!()

      :ok
    end

    test "filters by equality" do
      [user] =
        User
        |> Ash.Query.filter(name == "Alice")
        |> Ash.read!()

      assert user.name == "Alice"
    end

    test "filters by comparison" do
      users =
        User
        |> Ash.Query.filter(age > 25)
        |> Ash.read!()

      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Carol"]
    end

    test "filters with AND" do
      [user] =
        User
        |> Ash.Query.filter(age >= 30 and name == "Alice")
        |> Ash.read!()

      assert user.name == "Alice"
    end

    test "filters with OR" do
      users =
        User
        |> Ash.Query.filter(name == "Alice" or name == "Bob")
        |> Ash.read!()

      assert length(users) == 2
    end
  end

  describe "sort" do
    setup do
      User
      |> Ash.Changeset.for_create(:create, %{email: "z@example.com", name: "Zara", age: 30})
      |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{email: "a@example.com", name: "Alice", age: 25})
      |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{email: "m@example.com", name: "Mike", age: 35})
      |> Ash.create!()

      :ok
    end

    test "sorts ascending" do
      users =
        User
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(users, & &1.name)
      assert names == ["Alice", "Mike", "Zara"]
    end

    test "sorts descending" do
      users =
        User
        |> Ash.Query.sort(age: :desc)
        |> Ash.read!()

      ages = Enum.map(users, & &1.age)
      assert ages == [35, 30, 25]
    end
  end

  describe "limit and offset" do
    setup do
      for i <- 1..5 do
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "user#{i}@example.com",
          name: "User #{i}",
          age: 20 + i
        })
        |> Ash.create!()
      end

      :ok
    end

    test "limits results" do
      users =
        User
        |> Ash.Query.sort(age: :asc)
        |> Ash.Query.limit(2)
        |> Ash.read!()

      assert length(users) == 2
      ages = Enum.map(users, & &1.age)
      assert ages == [21, 22]
    end

    test "offsets results" do
      users =
        User
        |> Ash.Query.sort(age: :asc)
        |> Ash.Query.offset(2)
        |> Ash.Query.limit(2)
        |> Ash.read!()

      assert length(users) == 2
      ages = Enum.map(users, & &1.age)
      assert ages == [23, 24]
    end
  end
end
