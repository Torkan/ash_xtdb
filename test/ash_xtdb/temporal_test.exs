# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.TemporalTest do
  use ExUnit.Case, async: false

  alias AshXTDB.Changeset
  alias AshXTDB.Query
  alias AshXTDB.Test.User

  require Ash.Query

  setup do
    # Use ERASE to fully remove records from all history (not just create tombstones)
    AshXTDB.TestRepo.query("ERASE FROM users WHERE users.\"_id\" IS NOT NULL", [])
    :ok
  end

  describe "valid time queries" do
    test "as_of_valid_time queries at a specific point in time" do
      # Create a user
      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "temporal@test.com",
          name: "Temporal User",
          age: 30
        })
        |> Ash.create!()

      # Query at current time should find the user
      users =
        User
        |> Query.as_of_valid_time(DateTime.utc_now())
        |> Ash.read!()

      assert length(users) == 1
      assert hd(users).email == user.email
    end

    test "as_of_valid_time in the past returns empty when user didn't exist" do
      # Create a user now
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "new@test.com",
        name: "New User"
      })
      |> Ash.create!()

      # Query at a time before the user was created
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      users =
        User
        |> Query.as_of_valid_time(past_time)
        |> Ash.read!()

      assert users == []
    end

    test "for_all_valid_time returns history" do
      # Create a user
      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "history@test.com",
          name: "Original Name",
          age: 25
        })
        |> Ash.create!()

      # Update the user
      user
      |> Ash.Changeset.for_update(:update, %{name: "Updated Name", age: 26})
      |> Ash.update!()

      # Query all valid time history
      users =
        User
        |> Query.for_all_valid_time()
        |> Ash.read!()

      # Should see all versions
      assert users != []
      emails = Enum.map(users, & &1.email)
      assert "history@test.com" in emails
    end

    test "for_valid_time_between returns records in range" do
      # Create a user
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "range@test.com",
        name: "Range User"
      })
      |> Ash.create!()

      # Query with a time range that includes now
      from_time = DateTime.add(DateTime.utc_now(), -3600, :second)
      to_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      users =
        User
        |> Query.for_valid_time_between(from_time, to_time)
        |> Ash.read!()

      assert users != []
    end
  end

  describe "system time queries" do
    test "as_of_system_time queries database state at a point in time" do
      # Create a user
      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "system@test.com",
          name: "System User"
        })
        |> Ash.create!()

      # Query at current time should find the user
      users =
        User
        |> Query.as_of_system_time(DateTime.utc_now())
        |> Ash.read!()

      assert length(users) == 1
      assert hd(users).email == user.email
    end

    test "as_of_system_time in the past returns empty when user didn't exist" do
      # Create a user now
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "recent@test.com",
        name: "Recent User"
      })
      |> Ash.create!()

      # Query at a time before the user was created
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      users =
        User
        |> Query.as_of_system_time(past_time)
        |> Ash.read!()

      assert users == []
    end

    test "for_all_system_time returns audit history" do
      # Create a user
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "audit@test.com",
        name: "Audit User"
      })
      |> Ash.create!()

      # Query all system time history (audit log)
      users =
        User
        |> Query.for_all_system_time()
        |> Ash.read!()

      assert users != []
    end
  end

  describe "combined temporal queries" do
    test "can combine valid time and system time queries" do
      # Create a user
      User
      |> Ash.Changeset.for_create(:create, %{
        email: "combined@test.com",
        name: "Combined User"
      })
      |> Ash.create!()

      now = DateTime.utc_now()

      # Query with both valid time and system time
      users =
        User
        |> Query.as_of_valid_time(now)
        |> Query.as_of_system_time(now)
        |> Ash.read!()

      assert length(users) == 1
    end
  end

  describe "temporal mutations" do
    test "with_valid_from sets valid time start" do
      past_time = DateTime.add(DateTime.utc_now(), -86_400, :second)

      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "valid_from@test.com",
          name: "Valid From User"
        })
        |> Changeset.with_valid_from(past_time)
        |> Ash.create!()

      assert user.email == "valid_from@test.com"

      # User should be visible when querying at a time after valid_from
      users =
        User
        |> Query.as_of_valid_time(DateTime.utc_now())
        |> Ash.Query.filter(email == "valid_from@test.com")
        |> Ash.read!()

      assert length(users) == 1
    end

    test "with_valid_to sets valid time end" do
      future_time = DateTime.add(DateTime.utc_now(), 86_400, :second)

      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "valid_to@test.com",
          name: "Valid To User"
        })
        |> Changeset.with_valid_to(future_time)
        |> Ash.create!()

      assert user.email == "valid_to@test.com"
    end

    test "with_valid_time sets both from and to" do
      past_time = DateTime.add(DateTime.utc_now(), -86_400, :second)
      future_time = DateTime.add(DateTime.utc_now(), 86_400, :second)

      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "valid_range@test.com",
          name: "Valid Range User"
        })
        |> Changeset.with_valid_time(past_time, future_time)
        |> Ash.create!()

      assert user.email == "valid_range@test.com"
    end
  end

  describe "erase (GDPR compliance)" do
    test "erase! removes record from all history" do
      # Create a user
      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "erase@test.com",
          name: "To Be Erased"
        })
        |> Ash.create!()

      # Verify user exists
      users = Ash.read!(User)
      assert length(users) == 1

      # Erase the user
      assert :ok = Changeset.erase!(user)

      # User should be completely gone
      users = Ash.read!(User)
      assert users == []

      # User should also be gone from all history
      history_users =
        User
        |> Query.for_all_valid_time()
        |> Ash.read!()

      refute Enum.any?(history_users, fn u -> u.email == "erase@test.com" end)
    end
  end
end
