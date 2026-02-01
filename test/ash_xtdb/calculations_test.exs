# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.CalculationsTest do
  use ExUnit.Case, async: false

  alias AshXTDB.Test.UserWithCalculations

  require Ash.Query

  setup do
    # Clean up the users_with_calculations table before each test
    AshXTDB.TestRepo.query(
      "DELETE FROM users_with_calculations WHERE users_with_calculations.\"_id\" IS NOT NULL",
      []
    )

    :ok
  end

  describe "expression calculations" do
    test "calculates string concatenation" do
      user =
        UserWithCalculations
        |> Ash.Changeset.for_create(:create, %{
          email: "test@test.com",
          first_name: "John",
          last_name: "Doe"
        })
        |> Ash.create!()

      # Load the calculation
      [loaded_user] =
        UserWithCalculations
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.Query.load(:full_name)
        |> Ash.read!()

      assert loaded_user.full_name == "John Doe"
    end

    test "calculates arithmetic expression" do
      user =
        UserWithCalculations
        |> Ash.Changeset.for_create(:create, %{
          email: "test@test.com",
          first_name: "Jane",
          last_name: "Smith",
          age: 30
        })
        |> Ash.create!()

      # Load the calculation
      [loaded_user] =
        UserWithCalculations
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.Query.load(:age_plus_ten)
        |> Ash.read!()

      assert loaded_user.age_plus_ten == 40
    end

    test "handles nil values in calculations" do
      user =
        UserWithCalculations
        |> Ash.Changeset.for_create(:create, %{
          email: "test@test.com",
          first_name: "Only",
          last_name: nil
        })
        |> Ash.create!()

      # Load the calculation - should handle nil gracefully
      [loaded_user] =
        UserWithCalculations
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.Query.load(:full_name)
        |> Ash.read!()

      # Depending on how concat handles nil, this could be "Only " or nil
      # Most implementations would produce "Only " or similar
      assert loaded_user.full_name == "Only " or loaded_user.full_name == nil
    end

    test "loads multiple calculations" do
      user =
        UserWithCalculations
        |> Ash.Changeset.for_create(:create, %{
          email: "multi@test.com",
          first_name: "Alice",
          last_name: "Wonder",
          age: 25
        })
        |> Ash.create!()

      # Load multiple calculations
      [loaded_user] =
        UserWithCalculations
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.Query.load([:full_name, :age_plus_ten])
        |> Ash.read!()

      assert loaded_user.full_name == "Alice Wonder"
      assert loaded_user.age_plus_ten == 35
    end

    test "calculation works across multiple records" do
      users_data = [
        %{email: "a@test.com", first_name: "Alice", last_name: "A", age: 20},
        %{email: "b@test.com", first_name: "Bob", last_name: "B", age: 30},
        %{email: "c@test.com", first_name: "Charlie", last_name: "C", age: 40}
      ]

      for data <- users_data do
        UserWithCalculations
        |> Ash.Changeset.for_create(:create, data)
        |> Ash.create!()
      end

      # Load calculations for all users
      users =
        UserWithCalculations
        |> Ash.Query.load([:full_name, :age_plus_ten])
        |> Ash.Query.sort(age: :asc)
        |> Ash.read!()

      assert length(users) == 3
      assert Enum.map(users, & &1.full_name) == ["Alice A", "Bob B", "Charlie C"]
      assert Enum.map(users, & &1.age_plus_ten) == [30, 40, 50]
    end
  end
end
