# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.ErrorsUnitTest do
  @moduledoc """
  Unit tests for error conversion in the data layer.

  Tests verify that database errors (Postgrex, DBConnection) are
  properly converted to Ash error types.
  """
  use ExUnit.Case, async: true

  alias AshXTDB.DataLayer.Errors

  # Define custom exception at module level for testing
  defmodule TestCustomError do
    defexception [:message]
  end

  describe "to_ash_error with Postgrex errors" do
    test "converts connection error 08000" do
      error = %Postgrex.Error{
        postgres: %{
          code: "08000",
          message: "connection exception"
        }
      }

      result = Errors.to_ash_error(error)

      assert %Ash.Error.Unknown{} = result
      assert length(result.errors) > 0
      [inner_error | _] = result.errors
      assert inner_error =~ "XTDB connection error"
      assert inner_error =~ "connection exception"
    end

    test "converts connection does not exist error 08003" do
      error = %Postgrex.Error{
        postgres: %{
          code: "08003",
          message: "connection does not exist"
        }
      }

      result = Errors.to_ash_error(error)

      assert %Ash.Error.Unknown{} = result
      assert length(result.errors) > 0
      [inner_error | _] = result.errors
      assert inner_error =~ "XTDB connection does not exist"
    end

    test "converts syntax error 42601" do
      error = %Postgrex.Error{
        postgres: %{
          code: "42601",
          message: "syntax error at or near 'SELECT'"
        }
      }

      result = Errors.to_ash_error(error)

      assert %Ash.Error.Invalid{} = result
      assert length(result.errors) > 0

      [inner_error | _] = result.errors
      assert inner_error.message =~ "SQL syntax error"
    end

    test "converts undefined table error 42P01" do
      error = %Postgrex.Error{
        postgres: %{
          code: "42P01",
          message: "relation \"users\" does not exist"
        }
      }

      result = Errors.to_ash_error(error)

      assert %Ash.Error.Invalid{} = result
      assert length(result.errors) > 0

      [inner_error | _] = result.errors
      assert inner_error.message =~ "Table does not exist"
    end

    test "converts undefined column error 42703" do
      error = %Postgrex.Error{
        postgres: %{
          code: "42703",
          message: "column \"nonexistent\" does not exist"
        }
      }

      result = Errors.to_ash_error(error)

      assert %Ash.Error.Invalid{} = result
      assert length(result.errors) > 0

      [inner_error | _] = result.errors
      assert inner_error.message =~ "Column does not exist"
    end

    test "converts data type mismatch error 42804" do
      error = %Postgrex.Error{
        postgres: %{
          code: "42804",
          message: "column \"age\" is of type integer but expression is of type text"
        }
      }

      result = Errors.to_ash_error(error)

      assert %Ash.Error.Invalid{} = result
      assert length(result.errors) > 0

      [inner_error | _] = result.errors
      assert inner_error.message =~ "Data type mismatch"
    end

    test "converts unknown error code using Ash.Error.to_ash_error" do
      error = %Postgrex.Error{
        postgres: %{
          code: "99999",
          message: "unknown error"
        }
      }

      result = Errors.to_ash_error(error)

      # Should be converted by Ash.Error.to_ash_error
      assert is_struct(result)
    end

    test "handles Postgrex error without postgres field" do
      error = %Postgrex.Error{
        postgres: nil,
        message: "generic error"
      }

      result = Errors.to_ash_error(error)

      # Should be converted by Ash.Error.to_ash_error
      assert is_struct(result)
    end
  end

  describe "to_ash_error with DBConnection errors" do
    test "converts DBConnection.ConnectionError" do
      error = %DBConnection.ConnectionError{
        message: "connection refused"
      }

      result = Errors.to_ash_error(error)

      assert %Ash.Error.Unknown{} = result
      assert length(result.errors) > 0
      [inner_error | _] = result.errors
      assert inner_error =~ "Database connection error"
      assert inner_error =~ "connection refused"
    end

    test "converts DBConnection.ConnectionError with timeout" do
      error = %DBConnection.ConnectionError{
        message: "connection timed out"
      }

      result = Errors.to_ash_error(error)

      assert %Ash.Error.Unknown{} = result
      assert length(result.errors) > 0
      [inner_error | _] = result.errors
      assert inner_error =~ "connection timed out"
    end
  end

  describe "to_ash_error with Ash errors (pass-through)" do
    test "returns Ash.Error.Unknown as-is" do
      original = Ash.Error.Unknown.exception(errors: ["original error"])

      result = Errors.to_ash_error(original)

      # Should return the same type and errors without double-wrapping
      assert %Ash.Error.Unknown{} = result
      assert result.errors == original.errors
    end

    test "returns Ash.Error.Invalid as-is" do
      original =
        Ash.Error.Invalid.exception(
          errors: [
            %Ash.Error.Query.InvalidQuery{message: "test"}
          ]
        )

      result = Errors.to_ash_error(original)

      # Should return the same type and error content without double-wrapping
      assert %Ash.Error.Invalid{} = result
      assert length(result.errors) == length(original.errors)
    end
  end

  describe "to_ash_error with generic exceptions" do
    test "converts RuntimeError" do
      error = %RuntimeError{message: "something went wrong"}

      result = Errors.to_ash_error(error)

      assert is_struct(result)
    end

    test "converts ArgumentError" do
      error = %ArgumentError{message: "invalid argument"}

      result = Errors.to_ash_error(error)

      assert is_struct(result)
    end

    test "converts custom exception" do
      error = %__MODULE__.TestCustomError{message: "custom error"}

      result = Errors.to_ash_error(error)

      assert is_struct(result)
    end
  end

  describe "to_ash_error with non-exception values" do
    test "converts plain string" do
      result = Errors.to_ash_error("plain string error")

      assert %Ash.Error.Unknown{} = result
      assert length(result.errors) > 0
      [inner_error | _] = result.errors
      assert inner_error =~ "plain string error"
    end

    test "converts atom" do
      result = Errors.to_ash_error(:some_error)

      assert %Ash.Error.Unknown{} = result
      assert length(result.errors) > 0
      [inner_error | _] = result.errors
      assert inner_error =~ ":some_error"
    end

    test "converts tuple" do
      result = Errors.to_ash_error({:error, :not_found})

      assert %Ash.Error.Unknown{} = result
      assert length(result.errors) > 0
      [inner_error | _] = result.errors
      assert inner_error =~ "{:error, :not_found}"
    end

    test "converts map" do
      result = Errors.to_ash_error(%{reason: :failed})

      assert %Ash.Error.Unknown{} = result
      assert length(result.errors) > 0
      [inner_error | _] = result.errors
      assert inner_error =~ "reason"
    end

    test "converts integer" do
      result = Errors.to_ash_error(500)

      assert %Ash.Error.Unknown{} = result
      assert length(result.errors) > 0
      [inner_error | _] = result.errors
      assert inner_error =~ "500"
    end
  end

  describe "to_ash_error with struct that is not an exception" do
    test "converts non-exception struct" do
      # A struct that is not an exception
      struct = %URI{host: "localhost", port: 5432}

      result = Errors.to_ash_error(struct)

      assert %Ash.Error.Unknown{} = result
      assert length(result.errors) > 0
      [inner_error | _] = result.errors
      assert inner_error =~ "localhost"
    end
  end

  describe "error code edge cases" do
    test "handles error with empty message" do
      error = %Postgrex.Error{
        postgres: %{
          code: "42P01",
          message: ""
        }
      }

      result = Errors.to_ash_error(error)

      assert %Ash.Error.Invalid{} = result
    end

    test "handles error with nil values in postgres map" do
      error = %Postgrex.Error{
        postgres: %{
          code: nil,
          message: nil
        }
      }

      # This might raise or convert, depending on implementation
      # The important thing is it doesn't crash
      result = Errors.to_ash_error(error)
      assert is_struct(result)
    end
  end
end
