# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Connection.Protocol do
  @moduledoc """
  Pure parsing of PostgreSQL wire protocol messages.

  These functions transform raw binary messages from the simple query protocol
  into structured Elixir values. They have no side effects and no dependency on
  connection state, so they can be tested directly.
  """

  @doc """
  Parses a RowDescription (`T`) message into a list of `{column_name, type_oid}` tuples.
  """
  @spec parse_row_description(binary()) :: {:ok, [{binary(), non_neg_integer()}]}
  def parse_row_description(<<?T, length::32, rest::binary>>) do
    payload_length = length - 4
    <<payload::binary-size(^payload_length), _::binary>> = rest
    <<num_fields::16, fields_data::binary>> = payload

    {columns, _} =
      Enum.reduce(1..num_fields//1, {[], fields_data}, fn _, {cols, data} ->
        {name, rest} = parse_string(data)

        <<_table_oid::32, _col_num::16, type_oid::32, _type_size::16, _type_mod::32, _format::16,
          remaining::binary>> = rest

        {[{name, type_oid} | cols], remaining}
      end)

    {:ok, Enum.reverse(columns)}
  end

  @doc """
  Parses a DataRow (`D`) message into a list of raw field values (or `nil` for NULL).
  """
  @spec parse_data_row(binary()) :: {:ok, [binary() | nil]}
  def parse_data_row(<<?D, length::32, rest::binary>>) do
    payload_length = length - 4
    <<payload::binary-size(^payload_length), _::binary>> = rest
    <<num_fields::16, fields_data::binary>> = payload

    {values, _} =
      Enum.reduce(1..num_fields//1, {[], fields_data}, fn _, {vals, data} ->
        <<field_length::32-signed, remaining::binary>> = data

        if field_length == -1 do
          {[nil | vals], remaining}
        else
          <<value::binary-size(^field_length), rest::binary>> = remaining
          {[value | vals], rest}
        end
      end)

    {:ok, Enum.reverse(values)}
  end

  @doc """
  Parses an ErrorResponse (`E`) message into a `Postgrex.Error`.
  """
  @spec parse_error(binary()) :: Postgrex.Error.t()
  def parse_error(<<?E, length::32, rest::binary>>) do
    payload_length = length - 4
    <<payload::binary-size(^payload_length), _::binary>> = rest
    fields = parse_error_fields(payload, %{})

    %Postgrex.Error{
      postgres: %{
        code: Map.get(fields, ?C, ""),
        message: Map.get(fields, ?M, "Unknown error"),
        severity: Map.get(fields, ?S, "ERROR")
      }
    }
  end

  @doc """
  Builds a `DBConnection.ConnectionError` from a low-level reason (atom, Postgrex.Error, etc.).

  When `:show_sensitive_data_on_connection_error` is truthy in `opts`, the full
  options keyword list is appended to the message — useful for debugging but
  can leak credentials, so it's off by default.
  """
  @spec connection_error(term(), keyword()) :: DBConnection.ConnectionError.t()
  def connection_error(reason, opts) do
    message =
      case reason do
        :econnrefused ->
          "connection refused"

        :timeout ->
          "connection timed out"

        :closed ->
          "connection closed"

        :nxdomain ->
          "hostname not found"

        %Postgrex.Error{postgres: %{message: msg, code: code}} ->
          # Build our own message since Postgrex.Error.message/1 expects pg_code to be an atom
          "[#{code}] #{msg}"

        %Postgrex.Error{postgres: %{message: msg}} ->
          msg

        %Postgrex.Error{} = err ->
          inspect(err)

        other ->
          inspect(other)
      end

    if Keyword.get(opts, :show_sensitive_data_on_connection_error, false) do
      DBConnection.ConnectionError.exception("#{message} (#{inspect(opts)})")
    else
      DBConnection.ConnectionError.exception(message)
    end
  end

  defp parse_error_fields(<<0, _::binary>>, acc), do: acc
  defp parse_error_fields(<<>>, acc), do: acc

  defp parse_error_fields(<<type::8, rest::binary>>, acc) do
    {value, remaining} = parse_string(rest)
    parse_error_fields(remaining, Map.put(acc, type, value))
  end

  defp parse_string(data) do
    case :binary.split(data, <<0>>) do
      [str, rest] -> {str, rest}
      [str] -> {str, <<>>}
    end
  end
end
