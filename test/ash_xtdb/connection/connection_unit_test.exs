# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.ConnectionUnitTest do
  @moduledoc """
  Unit tests for Connection module message parsing.

  These tests verify the parsing of PostgreSQL wire protocol messages
  without requiring an actual database connection.
  """
  use ExUnit.Case, async: true

  alias AshXTDB.Connection

  describe "parse_row_description" do
    test "parses single column" do
      # Build a RowDescription message with single column "id"
      # Format: 'T' (84) | int32 length | int16 num_fields | field_name\0 | table_oid | col_num | type_oid | type_size | type_mod | format_code
      name = "id"
      name_bytes = name <> <<0>>

      # Field metadata: table_oid(4) + col_num(2) + type_oid(4) + type_size(2) + type_mod(4) + format(2) = 18 bytes
      field_data = name_bytes <> <<0::32, 1::16, 23::32, 4::16, -1::32-signed, 0::16>>

      num_fields = 1
      payload = <<num_fields::16>> <> field_data
      length = byte_size(payload) + 4

      msg = <<?T, length::32, payload::binary>>

      assert {:ok, ["id"]} = Connection.parse_row_description_for_test(msg)
    end

    test "parses multiple columns" do
      # Build a RowDescription message with columns "id", "name", "email"
      column_names = ["id", "name", "email"]

      fields_data =
        Enum.reduce(column_names, <<>>, fn name, acc ->
          name_bytes = name <> <<0>>
          # Field metadata
          field_data = name_bytes <> <<0::32, 1::16, 23::32, 4::16, -1::32-signed, 0::16>>
          acc <> field_data
        end)

      num_fields = length(column_names)
      payload = <<num_fields::16>> <> fields_data
      length = byte_size(payload) + 4

      msg = <<?T, length::32, payload::binary>>

      assert {:ok, ["id", "name", "email"]} = Connection.parse_row_description_for_test(msg)
    end

    test "parses empty row description (zero columns)" do
      # Zero fields - edge case
      num_fields = 0
      payload = <<num_fields::16>>
      length = byte_size(payload) + 4

      msg = <<?T, length::32, payload::binary>>

      assert {:ok, []} = Connection.parse_row_description_for_test(msg)
    end

    test "parses column names with unicode characters" do
      # Column name with unicode
      name = "user_name"
      name_bytes = name <> <<0>>

      field_data = name_bytes <> <<0::32, 1::16, 25::32, -1::16-signed, -1::32-signed, 0::16>>

      num_fields = 1
      payload = <<num_fields::16>> <> field_data
      length = byte_size(payload) + 4

      msg = <<?T, length::32, payload::binary>>

      assert {:ok, ["user_name"]} = Connection.parse_row_description_for_test(msg)
    end

    test "parses columns with underscores and numbers" do
      column_names = ["_id", "col_1", "field_2_value"]

      fields_data =
        Enum.reduce(column_names, <<>>, fn name, acc ->
          name_bytes = name <> <<0>>
          field_data = name_bytes <> <<0::32, 1::16, 23::32, 4::16, -1::32-signed, 0::16>>
          acc <> field_data
        end)

      num_fields = length(column_names)
      payload = <<num_fields::16>> <> fields_data
      length = byte_size(payload) + 4

      msg = <<?T, length::32, payload::binary>>

      assert {:ok, ["_id", "col_1", "field_2_value"]} =
               Connection.parse_row_description_for_test(msg)
    end
  end

  describe "parse_data_row" do
    test "parses row with single string value" do
      # Build a DataRow message with single value "hello"
      value = "hello"
      value_length = byte_size(value)

      num_fields = 1
      fields_data = <<value_length::32-signed, value::binary>>
      payload = <<num_fields::16>> <> fields_data
      length = byte_size(payload) + 4

      msg = <<?D, length::32, payload::binary>>

      assert {:ok, ["hello"]} = Connection.parse_data_row_for_test(msg)
    end

    test "parses row with multiple values" do
      values = ["1", "Alice", "alice@test.com"]

      fields_data =
        Enum.reduce(values, <<>>, fn value, acc ->
          value_length = byte_size(value)
          acc <> <<value_length::32-signed, value::binary>>
        end)

      num_fields = length(values)
      payload = <<num_fields::16>> <> fields_data
      length = byte_size(payload) + 4

      msg = <<?D, length::32, payload::binary>>

      assert {:ok, ["1", "Alice", "alice@test.com"]} = Connection.parse_data_row_for_test(msg)
    end

    test "parses row with NULL value (field_length == -1)" do
      # NULL is represented as field_length = -1
      # First value is "test", second is NULL, third is "value"
      fields_data =
        <<4::32-signed, "test"::binary>> <>
          <<-1::32-signed>> <>
          <<5::32-signed, "value"::binary>>

      num_fields = 3
      payload = <<num_fields::16>> <> fields_data
      length = byte_size(payload) + 4

      msg = <<?D, length::32, payload::binary>>

      assert {:ok, ["test", nil, "value"]} = Connection.parse_data_row_for_test(msg)
    end

    test "parses row with all NULL values" do
      # Three NULL values
      fields_data = <<-1::32-signed, -1::32-signed, -1::32-signed>>

      num_fields = 3
      payload = <<num_fields::16>> <> fields_data
      length = byte_size(payload) + 4

      msg = <<?D, length::32, payload::binary>>

      assert {:ok, [nil, nil, nil]} = Connection.parse_data_row_for_test(msg)
    end

    test "parses row with empty string value" do
      # Empty string has length 0
      fields_data = <<0::32-signed>>

      num_fields = 1
      payload = <<num_fields::16>> <> fields_data
      length = byte_size(payload) + 4

      msg = <<?D, length::32, payload::binary>>

      assert {:ok, [""]} = Connection.parse_data_row_for_test(msg)
    end

    test "parses row with binary data" do
      # Binary value
      binary_value = <<1, 2, 3, 4, 5>>
      fields_data = <<byte_size(binary_value)::32-signed, binary_value::binary>>

      num_fields = 1
      payload = <<num_fields::16>> <> fields_data
      length = byte_size(payload) + 4

      msg = <<?D, length::32, payload::binary>>

      assert {:ok, [<<1, 2, 3, 4, 5>>]} = Connection.parse_data_row_for_test(msg)
    end

    test "parses row with integer as string" do
      # PostgreSQL sends integers as strings in text format
      value = "12345"
      fields_data = <<byte_size(value)::32-signed, value::binary>>

      num_fields = 1
      payload = <<num_fields::16>> <> fields_data
      length = byte_size(payload) + 4

      msg = <<?D, length::32, payload::binary>>

      assert {:ok, ["12345"]} = Connection.parse_data_row_for_test(msg)
    end
  end

  describe "parse_error" do
    test "parses error with code and message" do
      # Error fields: S=severity, C=code, M=message
      error_fields =
        <<?S, "ERROR", 0, ?C, "42P01", 0, ?M, "relation does not exist", 0, 0>>

      payload = error_fields
      length = byte_size(payload) + 4

      msg = <<?E, length::32, payload::binary>>

      error = Connection.parse_error_for_test(msg)

      assert %Postgrex.Error{postgres: postgres} = error
      assert postgres.code == "42P01"
      assert postgres.message == "relation does not exist"
      assert postgres.severity == "ERROR"
    end

    test "parses error with missing fields uses defaults" do
      # Only provide message field
      error_fields = <<?M, "Something went wrong", 0, 0>>

      payload = error_fields
      length = byte_size(payload) + 4

      msg = <<?E, length::32, payload::binary>>

      error = Connection.parse_error_for_test(msg)

      assert %Postgrex.Error{postgres: postgres} = error
      assert postgres.code == ""
      assert postgres.message == "Something went wrong"
      assert postgres.severity == "ERROR"
    end

    test "parses error with empty payload" do
      # Just the null terminator
      error_fields = <<0>>

      payload = error_fields
      length = byte_size(payload) + 4

      msg = <<?E, length::32, payload::binary>>

      error = Connection.parse_error_for_test(msg)

      assert %Postgrex.Error{postgres: postgres} = error
      # Should use defaults
      assert postgres.code == ""
      assert postgres.message == "Unknown error"
      assert postgres.severity == "ERROR"
    end

    test "parses error with all standard fields" do
      # Multiple error fields
      error_fields =
        <<?S, "WARNING", 0, ?C, "01000", 0, ?M, "This is a warning", 0, ?D, "Detail info", 0,
          ?H, "Hint info", 0, 0>>

      payload = error_fields
      length = byte_size(payload) + 4

      msg = <<?E, length::32, payload::binary>>

      error = Connection.parse_error_for_test(msg)

      assert %Postgrex.Error{postgres: postgres} = error
      assert postgres.code == "01000"
      assert postgres.message == "This is a warning"
      assert postgres.severity == "WARNING"
    end
  end

  describe "connection_error" do
    test "handles :econnrefused" do
      error = Connection.connection_error_for_test(:econnrefused, [])

      assert %DBConnection.ConnectionError{message: message} = error
      assert message == "connection refused"
    end

    test "handles :timeout" do
      error = Connection.connection_error_for_test(:timeout, [])

      assert %DBConnection.ConnectionError{message: message} = error
      assert message == "connection timed out"
    end

    test "handles :closed" do
      error = Connection.connection_error_for_test(:closed, [])

      assert %DBConnection.ConnectionError{message: message} = error
      assert message == "connection closed"
    end

    test "handles :nxdomain" do
      error = Connection.connection_error_for_test(:nxdomain, [])

      assert %DBConnection.ConnectionError{message: message} = error
      assert message == "hostname not found"
    end

    test "handles Postgrex.Error with code and message" do
      postgrex_error = %Postgrex.Error{
        postgres: %{
          code: "42P01",
          message: "relation does not exist"
        }
      }

      error = Connection.connection_error_for_test(postgrex_error, [])

      assert %DBConnection.ConnectionError{message: message} = error
      assert message == "[42P01] relation does not exist"
    end

    test "handles Postgrex.Error with only message" do
      postgrex_error = %Postgrex.Error{
        postgres: %{
          message: "some error"
        }
      }

      error = Connection.connection_error_for_test(postgrex_error, [])

      assert %DBConnection.ConnectionError{message: message} = error
      assert message == "some error"
    end

    test "handles unknown reason with inspect" do
      error = Connection.connection_error_for_test({:unknown, :error}, [])

      assert %DBConnection.ConnectionError{message: message} = error
      assert message == "{:unknown, :error}"
    end

    test "includes opts when show_sensitive_data_on_connection_error is true" do
      opts = [hostname: "localhost", port: 5432, show_sensitive_data_on_connection_error: true]
      error = Connection.connection_error_for_test(:econnrefused, opts)

      assert %DBConnection.ConnectionError{message: message} = error
      assert message =~ "connection refused"
      assert message =~ "localhost"
      assert message =~ "5432"
    end

    test "excludes opts when show_sensitive_data_on_connection_error is false" do
      opts = [hostname: "localhost", port: 5432, show_sensitive_data_on_connection_error: false]
      error = Connection.connection_error_for_test(:econnrefused, opts)

      assert %DBConnection.ConnectionError{message: message} = error
      assert message == "connection refused"
      refute message =~ "localhost"
    end
  end

  describe "edge cases in message parsing" do
    test "parse_row_description handles long column names" do
      # Column with a very long name (100 characters)
      name = String.duplicate("a", 100)
      name_bytes = name <> <<0>>

      field_data = name_bytes <> <<0::32, 1::16, 25::32, -1::16-signed, -1::32-signed, 0::16>>

      num_fields = 1
      payload = <<num_fields::16>> <> field_data
      length = byte_size(payload) + 4

      msg = <<?T, length::32, payload::binary>>

      assert {:ok, [^name]} = Connection.parse_row_description_for_test(msg)
    end

    test "parse_data_row handles large value" do
      # Large string value (1000 characters)
      value = String.duplicate("x", 1000)
      fields_data = <<byte_size(value)::32-signed, value::binary>>

      num_fields = 1
      payload = <<num_fields::16>> <> fields_data
      length = byte_size(payload) + 4

      msg = <<?D, length::32, payload::binary>>

      assert {:ok, [^value]} = Connection.parse_data_row_for_test(msg)
    end

    test "parse_data_row handles mixed NULL and non-NULL values" do
      # Pattern: value, NULL, value, NULL, value
      fields_data =
        <<1::32-signed, "a"::binary>> <>
          <<-1::32-signed>> <>
          <<1::32-signed, "b"::binary>> <>
          <<-1::32-signed>> <>
          <<1::32-signed, "c"::binary>>

      num_fields = 5
      payload = <<num_fields::16>> <> fields_data
      length = byte_size(payload) + 4

      msg = <<?D, length::32, payload::binary>>

      assert {:ok, ["a", nil, "b", nil, "c"]} = Connection.parse_data_row_for_test(msg)
    end
  end
end
