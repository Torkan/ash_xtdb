# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.Core do
  @moduledoc """
  Core SQL utilities shared across all SQL generation modules.

  This module provides fundamental operations for SQL generation:
  - Value escaping and formatting
  - Identifier quoting and validation
  - Parameter inlining for XTDB's simple query protocol

  ## XTDB Simple Query Protocol

  XTDB only supports the PostgreSQL simple query protocol, which means
  parameters cannot be bound separately. Instead, all values must be
  inlined directly into the SQL string. The `inline_params/2` function
  handles this by replacing `$1`, `$2`, etc. placeholders with properly
  escaped values.

  ## SQL Injection Prevention

  All identifiers (table names, column names) are quoted using double
  quotes, and all string values are properly escaped. The `validate_identifier!/1`
  function provides additional defense-in-depth validation.
  """

  # Shared table alias used across queries
  @table_alias "t"

  @doc """
  Returns the default table alias used in XTDB queries.
  """
  @spec table_alias() :: String.t()
  def table_alias, do: @table_alias

  # ============================================================================
  # Parameter Inlining
  # ============================================================================

  @doc """
  Inlines parameters into SQL by replacing $1, $2, etc. with actual values.

  XTDB uses the simple query protocol which doesn't support parameterized
  queries, so we need to inline values directly into the SQL string.

  ## Examples

      iex> AshXTDB.SQL.Core.inline_params("SELECT * FROM users WHERE id = $1", ["abc"])
      "SELECT * FROM users WHERE id = 'abc'"

      iex> AshXTDB.SQL.Core.inline_params("SELECT * FROM users WHERE age > $1 AND name = $2", [18, "Alice"])
      "SELECT * FROM users WHERE age > 18 AND name = 'Alice'"
  """
  @spec inline_params(String.t(), list()) :: String.t()
  def inline_params(sql, []), do: sql

  def inline_params(sql, params) do
    # Build a lookup map of placeholder -> escaped value
    # We use a regex to replace all placeholders in a single pass to avoid
    # the bug where a value containing "$N" gets incorrectly replaced
    # when processing placeholder $N later.
    param_map =
      params
      |> Enum.with_index(1)
      |> Map.new(fn {value, idx} ->
        {"$#{idx}", escape_value(value)}
      end)

    # Match $1, $2, ..., $N placeholders and replace each with its escaped value
    # The regex matches $ followed by one or more digits
    Regex.replace(~r/\$(\d+)/, sql, fn full_match, _idx_str ->
      Map.get(param_map, full_match, full_match)
    end)
  end

  # ============================================================================
  # Value Escaping
  # ============================================================================

  @doc """
  Escapes a value for use in XTDB SQL.

  Handles various Elixir types and converts them to their SQL representation.

  ## Supported Types

  - `nil` -> `NULL`
  - `true`/`false` -> `TRUE`/`FALSE`
  - integers, floats -> numeric literals
  - `DateTime`, `Date`, `Time` -> SQL temporal literals
  - `Decimal` -> numeric string
  - strings, atoms -> quoted strings with escaping
  - lists -> `ARRAY[...]`
  - maps, structs -> JSON strings

  ## Examples

      iex> AshXTDB.SQL.Core.escape_value(nil)
      "NULL"

      iex> AshXTDB.SQL.Core.escape_value("O'Brien")
      "'O''Brien'"

      iex> AshXTDB.SQL.Core.escape_value(~U[2024-01-01 00:00:00Z])
      "TIMESTAMP '2024-01-01T00:00:00Z'"
  """
  @spec escape_value(term()) :: String.t()
  def escape_value(nil), do: "NULL"
  def escape_value(true), do: "TRUE"
  def escape_value(false), do: "FALSE"
  def escape_value(value) when is_integer(value), do: Integer.to_string(value)
  def escape_value(value) when is_float(value), do: Float.to_string(value)

  def escape_value(%DateTime{} = dt) do
    "TIMESTAMP '#{DateTime.to_iso8601(dt)}'"
  end

  def escape_value(%Date{} = date) do
    "DATE '#{Date.to_iso8601(date)}'"
  end

  def escape_value(%Time{} = time) do
    "TIME '#{Time.to_iso8601(time)}'"
  end

  def escape_value(%Decimal{} = decimal) do
    Decimal.to_string(decimal)
  end

  # Interval type - XTDB uses DURATION 'P...' syntax
  def escape_value(%AshXTDB.Types.Interval{} = interval) do
    iso = AshXTDB.Types.Interval.to_iso(interval)
    "DURATION '#{iso}'"
  end

  # Period type - XTDB uses PERIOD(TIMESTAMP, TIMESTAMP) syntax
  def escape_value(%AshXTDB.Types.Period{from: from, to: to}) do
    "PERIOD(TIMESTAMP '#{DateTime.to_iso8601(from)}', TIMESTAMP '#{DateTime.to_iso8601(to)}')"
  end

  def escape_value(value) when is_atom(value) do
    escape_value(Atom.to_string(value))
  end

  # Binary/string values - handle last to allow structs to match first
  def escape_value(value) when is_binary(value) do
    # Encode 4-byte UTF-8 characters to escape sequences (XTDB workaround)
    encoded = AshXTDB.UTF8Workaround.encode(value)

    # Escape special characters for SQL string literals
    # We use PostgreSQL's E'' (escape string) syntax for proper handling
    # In E'' strings, use backslash escapes for all special characters
    escaped =
      encoded
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    # Use E'' syntax to enable escape sequences
    "E'#{escaped}'"
  end

  def escape_value(value) when is_list(value) do
    elements = Enum.map_join(value, ", ", &escape_value/1)
    "ARRAY[#{elements}]"
  end

  # Handle structs (custom Ash types, etc.) by converting to plain map
  # This must come before the is_map clause since structs are also maps
  def escape_value(value) when is_struct(value) do
    # Convert struct to plain map, removing the __struct__ key
    plain_map =
      value
      |> Map.from_struct()
      |> convert_nested_structs()

    escape_value(plain_map)
  end

  def escape_value(value) when is_map(value) do
    # Convert maps to JSON for XTDB
    plain_map = convert_nested_structs(value)
    # Encode 4-byte UTF-8 characters in all string values (XTDB workaround)
    encoded_map = AshXTDB.UTF8Workaround.encode_deep(plain_map)
    json = Jason.encode!(encoded_map)

    # Escape special characters for SQL string literals
    # In E'' strings, use backslash escapes for all special characters
    escaped =
      json
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    # Use E'' syntax to enable escape sequences
    "E'#{escaped}'"
  end

  # Recursively convert any nested structs to plain maps
  defp convert_nested_structs(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_struct(value) ->
        {key, value |> Map.from_struct() |> convert_nested_structs()}

      {key, value} when is_map(value) ->
        {key, convert_nested_structs(value)}

      {key, value} when is_list(value) ->
        {key, Enum.map(value, &convert_nested_value/1)}

      {key, value} ->
        {key, value}
    end)
  end

  defp convert_nested_value(value) when is_struct(value) do
    value |> Map.from_struct() |> convert_nested_structs()
  end

  defp convert_nested_value(value) when is_map(value) do
    convert_nested_structs(value)
  end

  defp convert_nested_value(value) when is_list(value) do
    Enum.map(value, &convert_nested_value/1)
  end

  defp convert_nested_value(value), do: value

  # ============================================================================
  # Identifier Quoting
  # ============================================================================

  @doc """
  Quotes a SQL identifier (table name, column name) to prevent SQL injection.

  Identifiers are wrapped in double quotes and any embedded double quotes
  are escaped by doubling them.

  ## Examples

      iex> AshXTDB.SQL.Core.quote_identifier("users")
      "\\"users\\""

      iex> AshXTDB.SQL.Core.quote_identifier("user\\"table")
      "\\"user\\"\\"table\\""
  """
  @spec quote_identifier(String.t() | atom()) :: String.t()
  def quote_identifier(identifier) when is_atom(identifier) do
    quote_identifier(Atom.to_string(identifier))
  end

  def quote_identifier(identifier) when is_binary(identifier) do
    # Escape any embedded double quotes by doubling them
    escaped = String.replace(identifier, "\"", "\"\"")
    "\"#{escaped}\""
  end

  @doc """
  Validates that an identifier contains only safe characters.

  Raises ArgumentError if the identifier contains potentially dangerous characters.
  This is a defense-in-depth measure in addition to quoting.

  Allowed: letters, numbers, underscores, and dots (for schema.table notation)
  """
  @spec validate_identifier!(String.t() | atom()) :: :ok
  def validate_identifier!(identifier) when is_atom(identifier) do
    validate_identifier!(Atom.to_string(identifier))
  end

  def validate_identifier!(identifier) when is_binary(identifier) do
    # Allow alphanumeric, underscores, and dots for schema qualification
    if Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*$/, identifier) do
      :ok
    else
      raise ArgumentError,
            "Invalid SQL identifier: #{inspect(identifier)}. " <>
              "Identifiers must start with a letter or underscore and contain only " <>
              "alphanumeric characters, underscores, and dots."
    end
  end

  @doc """
  Safely quotes an identifier after validation.

  This combines validation and quoting for maximum safety.
  """
  @spec safe_identifier(String.t() | atom()) :: String.t()
  def safe_identifier(identifier) do
    validate_identifier!(identifier)
    quote_identifier(identifier)
  end

  # ============================================================================
  # Column Name Helpers
  # ============================================================================

  @doc """
  Converts an Ash field name to an INSERT column name.

  XTDB uses `"_id"` (quoted) for the primary key in INSERT statements.

  ## Examples

      iex> AshXTDB.SQL.Core.to_insert_column_name(:id)
      "\\"_id\\""

      iex> AshXTDB.SQL.Core.to_insert_column_name(:name)
      "\\"name\\""

      iex> AshXTDB.SQL.Core.to_insert_column_name(:level)
      "\\"level\\""
  """
  @spec to_insert_column_name(atom() | String.t()) :: String.t()
  def to_insert_column_name(:id), do: "\"_id\""
  def to_insert_column_name(:_id), do: "\"_id\""
  def to_insert_column_name(atom) when is_atom(atom), do: quote_identifier(Atom.to_string(atom))
  def to_insert_column_name(string) when is_binary(string), do: quote_identifier(string)

  @doc """
  Converts an Ash field name to a SELECT column name with table alias.

  Uses the standard table alias format with all column names properly quoted.

  ## Examples

      iex> AshXTDB.SQL.Core.to_select_column_name(:id, "t")
      "t.\\"_id\\""

      iex> AshXTDB.SQL.Core.to_select_column_name(:name, "t")
      "t.\\"name\\""

      iex> AshXTDB.SQL.Core.to_select_column_name(:level, "t")
      "t.\\"level\\""
  """
  @spec to_select_column_name(atom() | String.t(), String.t()) :: String.t()
  def to_select_column_name(:id, table_alias), do: "#{table_alias}.\"_id\""
  def to_select_column_name(:_id, table_alias), do: "#{table_alias}.\"_id\""

  def to_select_column_name(atom, table_alias) when is_atom(atom) do
    "#{table_alias}.#{quote_identifier(Atom.to_string(atom))}"
  end

  def to_select_column_name(string, table_alias) when is_binary(string) do
    "#{table_alias}.#{quote_identifier(string)}"
  end

  @doc """
  Converts a field name to a column name in a SQL expression.

  Handles the special case of :id mapping to "_id" and quotes all column names
  to handle reserved words.
  """
  @spec field_to_column(atom() | map()) :: String.t()
  def field_to_column(:id), do: "\"_id\""
  def field_to_column(:_id), do: "\"_id\""
  def field_to_column(field) when is_atom(field), do: quote_identifier(Atom.to_string(field))
  def field_to_column(%{name: name}), do: field_to_column(name)

  @doc """
  Ensures the ID column is present in a column list.

  If neither :id nor :_id is in the list, prepends :_id.
  """
  @spec ensure_id_column(list(atom())) :: list(atom())
  def ensure_id_column(columns) do
    if :id in columns || :_id in columns do
      columns
    else
      [:_id | columns]
    end
  end
end
