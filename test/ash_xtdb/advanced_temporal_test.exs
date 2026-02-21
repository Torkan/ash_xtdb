# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.AdvancedTemporalTest do
  @moduledoc """
  Integration tests for advanced temporal features:
  - FOR PORTION OF VALID_TIME
  - SETTING VALID_TIME clauses
  - PATCH statement
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Changeset
  alias AshXTDB.Query
  alias AshXTDB.SQL
  alias AshXTDB.SQL.DML.Patch
  alias AshXTDB.Test.User

  @moduletag :integration

  setup do
    # Use ERASE to fully remove records from all history
    AshXTDB.TestRepo.query("ERASE FROM users WHERE users.\"_id\" IS NOT NULL", [])
    :ok
  end

  describe "FOR PORTION OF VALID_TIME execution" do
    test "executes UPDATE FOR PORTION OF VALID_TIME" do
      # First create a user
      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "portion@test.com",
          name: "Original Name",
          age: 30
        })
        |> Ash.create!()

      # Build and execute UPDATE FOR PORTION OF VALID_TIME
      from = ~U[2024-01-01 00:00:00Z]
      to = ~U[2024-06-30 23:59:59Z]

      {sql, params} =
        SQL.build_update_for_portion(
          "users",
          %{id: user.id},
          %{name: "Updated Name"},
          User,
          from,
          to
        )

      inlined_sql = SQL.inline_params(sql, params)

      case AshXTDB.TestRepo.query(inlined_sql, []) do
        {:ok, _} ->
          # Verify the update worked by querying at different times
          # Current time should still show the user
          users = Ash.read!(User)
          assert users != []

        {:error, error} ->
          flunk("UPDATE FOR PORTION OF failed: #{inspect(error)}")
      end
    end

    test "executes DELETE FOR PORTION OF VALID_TIME" do
      # First create a user
      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "delete_portion@test.com",
          name: "To Delete",
          age: 25
        })
        |> Ash.create!()

      # Build and execute DELETE FOR PORTION OF VALID_TIME
      from = ~U[2024-01-01 00:00:00Z]
      to = ~U[2024-06-30 23:59:59Z]

      {sql, params} =
        SQL.build_delete_for_portion(
          "users",
          %{id: user.id},
          User,
          from,
          to
        )

      inlined_sql = SQL.inline_params(sql, params)

      case AshXTDB.TestRepo.query(inlined_sql, []) do
        {:ok, _} ->
          assert true

        {:error, error} ->
          flunk("DELETE FOR PORTION OF failed: #{inspect(error)}")
      end
    end
  end

  describe "INSERT with valid time columns" do
    test "executes INSERT with _valid_from and _valid_to columns" do
      from = ~U[2023-01-01 00:00:00Z]
      to = ~U[2023-12-31 23:59:59Z]

      {sql, params} =
        SQL.build_insert_with_valid_time(
          "users",
          %{_id: Ash.UUID.generate(), email: "setting@test.com", name: "Setting User"},
          User,
          from,
          to
        )

      inlined_sql = SQL.inline_params(sql, params)

      case AshXTDB.TestRepo.query(inlined_sql, []) do
        {:ok, _} ->
          # User was inserted with specific valid time
          # Query with FOR ALL VALID_TIME to see all versions
          all_users =
            User
            |> Query.for_all_valid_time()
            |> Ash.read!()

          assert Enum.any?(all_users, fn u -> u.email == "setting@test.com" end)

        {:error, error} ->
          flunk("INSERT with valid time columns failed: #{inspect(error)}")
      end
    end

    test "executes INSERT with _valid_from column" do
      from = ~U[2024-06-01 00:00:00Z]

      {sql, params} =
        SQL.build_insert_with_valid_from(
          "users",
          %{_id: Ash.UUID.generate(), email: "valid_from@test.com", name: "Valid From User"},
          User,
          from
        )

      inlined_sql = SQL.inline_params(sql, params)

      case AshXTDB.TestRepo.query(inlined_sql, []) do
        {:ok, _} ->
          # Query with FOR ALL VALID_TIME
          all_users =
            User
            |> Query.for_all_valid_time()
            |> Ash.read!()

          assert Enum.any?(all_users, fn u -> u.email == "valid_from@test.com" end)

        {:error, error} ->
          flunk("INSERT with _valid_from column failed: #{inspect(error)}")
      end
    end
  end

  describe "Temporal module helpers" do
    test "for_portion_of_valid_time sets context on changeset" do
      from = ~U[2024-01-01 00:00:00Z]
      to = ~U[2024-06-30 23:59:59Z]

      # Create a user first
      user =
        User
        |> Ash.Changeset.for_create(:create, %{email: "context@test.com", name: "Test"})
        |> Ash.create!()

      changeset =
        user
        |> Ash.Changeset.for_update(:update, %{name: "Updated"})
        |> Changeset.for_portion_of_valid_time(from, to)

      temporal = changeset.context[:temporal]
      assert temporal[:portion_of_valid_time] == {from, to}
    end

    test "setting_valid_time sets context on changeset" do
      from = ~U[2024-01-01 00:00:00Z]
      to = ~U[2024-12-31 23:59:59Z]

      changeset =
        User
        |> Ash.Changeset.for_create(:create, %{email: "setting_ctx@test.com"})
        |> Changeset.setting_valid_time(from, to)

      temporal = changeset.context[:temporal]
      assert temporal[:setting_valid_time] == {from, to}
    end

    test "setting_valid_from sets context on changeset" do
      from = ~U[2024-06-01 00:00:00Z]

      changeset =
        User
        |> Ash.Changeset.for_create(:create, %{email: "from_ctx@test.com"})
        |> Changeset.setting_valid_from(from)

      temporal = changeset.context[:temporal]
      assert temporal[:setting_valid_from] == from
    end
  end

  describe "PATCH statement execution" do
    test "executes PATCH for upsert using RECORDS syntax" do
      # First create a user
      existing_user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "existing@test.com",
          name: "Original",
          age: 30
        })
        |> Ash.create!()

      new_user_id = Ash.UUID.generate()

      # Build PATCH SQL using XTDB v2 RECORDS syntax
      sql =
        Patch.build_patch_sql(
          "users",
          [
            # Update existing user (by _id)
            %{id: existing_user.id, email: "existing@test.com", name: "Updated"},
            # Insert new user
            %{id: new_user_id, email: "new@test.com", name: "New User"}
          ],
          nil,
          nil
        )

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, _} ->
          # Verify results
          users = Ash.read!(User)
          emails = Enum.map(users, & &1.email) |> Enum.sort()
          assert "existing@test.com" in emails
          assert "new@test.com" in emails

          # Verify update worked
          updated_user = Enum.find(users, fn u -> u.id == existing_user.id end)
          assert updated_user.name == "Updated"

        {:error, error} ->
          flunk("PATCH upsert failed: #{inspect(error)}")
      end
    end

    test "executes PATCH to insert new record" do
      new_user_id = Ash.UUID.generate()

      # Build PATCH SQL for inserting a new record
      sql =
        Patch.build_patch_sql(
          "users",
          [%{id: new_user_id, email: "patch_insert@test.com", name: "Patch Insert User"}],
          nil,
          nil
        )

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, _} ->
          users = Ash.read!(User)
          new_user = Enum.find(users, fn u -> u.email == "patch_insert@test.com" end)
          assert new_user != nil
          assert new_user.name == "Patch Insert User"

        {:error, error} ->
          flunk("PATCH insert failed: #{inspect(error)}")
      end
    end
  end

  describe "Query SQL generation for temporal features" do
    test "generates UPDATE FOR PORTION OF VALID_TIME SQL correctly" do
      from = ~U[2024-01-01 00:00:00Z]
      to = ~U[2024-06-30 23:59:59Z]

      {sql, params} =
        SQL.build_update_for_portion(
          "users",
          %{id: "test-id"},
          %{name: "New Name"},
          User,
          from,
          to
        )

      assert sql =~ "UPDATE \"users\" FOR PORTION OF VALID_TIME"
      assert sql =~ "FROM TIMESTAMP '2024-01-01T00:00:00Z'"
      assert sql =~ "TO TIMESTAMP '2024-06-30T23:59:59Z'"
      assert sql =~ "SET \"name\" = $1"
      assert params == ["New Name", "test-id"]
    end

    test "generates DELETE FOR PORTION OF VALID_TIME SQL correctly" do
      from = ~U[2024-01-01 00:00:00Z]
      to = ~U[2024-06-30 23:59:59Z]

      {sql, params} =
        SQL.build_delete_for_portion(
          "users",
          %{id: "test-id"},
          User,
          from,
          to
        )

      assert sql =~ "DELETE FROM \"users\" FOR PORTION OF VALID_TIME"
      assert sql =~ "FROM TIMESTAMP '2024-01-01T00:00:00Z'"
      assert sql =~ "TO TIMESTAMP '2024-06-30T23:59:59Z'"
      assert params == ["test-id"]
    end

    test "generates INSERT with valid time columns SQL correctly" do
      from = ~U[2024-01-01 00:00:00Z]
      to = ~U[2024-12-31 23:59:59Z]

      {sql, params} =
        SQL.build_insert_with_valid_time(
          "users",
          %{_id: "test-id", name: "Test"},
          User,
          from,
          to
        )

      assert sql =~ "INSERT INTO \"users\""
      assert sql =~ "_valid_from"
      assert sql =~ "_valid_to"
      # Verify the timestamps are in the params
      assert Enum.any?(params, fn p -> p == from end)
      assert Enum.any?(params, fn p -> p == to end)
    end
  end

  describe "Patch module SQL generation" do
    test "builds PATCH SQL with RECORDS syntax" do
      sql =
        Patch.build_patch_sql(
          "users",
          [%{id: "1", email: "a@test.com", name: "A"}],
          nil,
          nil
        )

      assert sql =~ "PATCH INTO \"users\""
      assert sql =~ "RECORDS"
      assert sql =~ "_id: E'1'"
      assert sql =~ "email: E'a@test.com'"
      assert sql =~ "name: E'A'"
    end

    test "builds PATCH SQL with multiple records" do
      sql =
        Patch.build_patch_sql(
          "users",
          [
            %{id: "1", email: "a@test.com", name: "A"},
            %{id: "2", email: "b@test.com", name: "B"}
          ],
          nil,
          nil
        )

      assert sql =~ "PATCH INTO \"users\" RECORDS"
      # Should have two record objects separated by comma
      assert sql =~ "}, {"
    end

    test "builds PATCH SQL with valid time clause" do
      from = ~U[2024-01-01 00:00:00Z]
      to = ~U[2024-06-30 23:59:59Z]

      sql =
        Patch.build_patch_sql(
          "users",
          [%{id: "1", name: "Test"}],
          from,
          to
        )

      assert sql =~ "PATCH INTO \"users\""
      assert sql =~ "FOR PORTION OF VALID_TIME"
      assert sql =~ "FROM TIMESTAMP '2024-01-01T00:00:00Z'"
      assert sql =~ "TO TIMESTAMP '2024-06-30T23:59:59Z'"
      assert sql =~ "RECORDS"
    end
  end
end
