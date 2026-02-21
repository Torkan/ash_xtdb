# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Connection do
  @moduledoc """
  DBConnection implementation for XTDB using PostgreSQL simple query protocol.

  This module provides connection pooling, automatic reconnection, and health checks
  for XTDB connections. XTDB only supports the simple query protocol (no prepared
  statements), so parameters are inlined into SQL strings before execution.

  ## Configuration

      config :my_app, MyApp.XTDBRepo,
        hostname: "localhost",
        port: 5432,
        database: "xtdb",
        username: "xtdb",
        pool_size: 10,
        connect_timeout: 15_000,
        timeout: 15_000
  """

  use DBConnection

  require Logger

  @type t :: %__MODULE__{
          socket: :gen_tcp.socket() | nil,
          buffer: binary(),
          status: :idle | :transaction | :error | nil
        }

  defstruct [:socket, :buffer, :status]

  # PostgreSQL message types
  @auth_ok <<?R, 0, 0, 0, 8, 0, 0, 0, 0>>
  @ready_for_query_idle <<?Z, 0, 0, 0, 5, ?I>>
  @ready_for_query_transaction <<?Z, 0, 0, 0, 5, ?T>>
  @ready_for_query_failed <<?Z, 0, 0, 0, 5, ?E>>

  # ============================================================================
  # DBConnection Callbacks
  # ============================================================================

  @impl DBConnection
  def connect(opts) do
    hostname = Keyword.get(opts, :hostname, "localhost")
    port = Keyword.get(opts, :port, 5432)
    username = Keyword.get(opts, :username, "xtdb")
    database = Keyword.get(opts, :database, "xtdb")
    connect_timeout = Keyword.get(opts, :connect_timeout, 15_000)
    user_socket_opts = Keyword.get(opts, :socket_options, [])

    socket_opts =
      [
        :binary,
        active: false,
        packet: :raw,
        send_timeout: connect_timeout
      ] ++ user_socket_opts

    hostname_charlist = if is_binary(hostname), do: to_charlist(hostname), else: hostname

    case :gen_tcp.connect(hostname_charlist, port, socket_opts, connect_timeout) do
      {:ok, socket} ->
        state = %__MODULE__{socket: socket, buffer: <<>>, status: :idle}

        with :ok <- send_startup(state, username, database),
             {:ok, state} <- handle_auth(state),
             {:ok, state} <- wait_for_ready(state) do
          {:ok, state}
        else
          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, connection_error(reason, opts)}
        end

      {:error, reason} ->
        {:error, connection_error(reason, opts)}
    end
  end

  @impl DBConnection
  def disconnect(_err, %__MODULE__{socket: socket}) when socket != nil do
    # Send Terminate message
    _ = :gen_tcp.send(socket, <<?X, 0, 0, 0, 4>>)
    :gen_tcp.close(socket)
    :ok
  end

  def disconnect(_err, _state), do: :ok

  @impl DBConnection
  def checkout(state) do
    {:ok, state}
  end

  @impl DBConnection
  def ping(%__MODULE__{} = state) do
    case do_simple_query(state, "SELECT 1") do
      {:ok, _result, state} -> {:ok, state}
      {:error, _reason, state} -> {:disconnect, ping_error(), state}
    end
  end

  @impl DBConnection
  def handle_status(_opts, %__MODULE__{status: status} = state) do
    {status, state}
  end

  @impl DBConnection
  def handle_prepare(%AshXTDB.SimpleQuery{} = query, _opts, state) do
    # No-op for simple query protocol - query passes through as-is
    {:ok, query, state}
  end

  @impl DBConnection
  def handle_execute(%AshXTDB.SimpleQuery{statement: sql_template}, params, opts, state) do
    # Inline parameters since XTDB doesn't support parameterized queries
    sql = AshXTDB.SQL.inline_params(sql_template, params)
    timeout = Keyword.get(opts, :timeout, 15_000)

    case do_simple_query(state, sql, timeout) do
      {:ok, result, state} ->
        {:ok, %AshXTDB.SimpleQuery{statement: sql}, result, state}

      {:error, %Postgrex.Error{} = err, state} ->
        {:error, err, state}

      {:error, reason, state} ->
        {:disconnect, connection_error(reason, []), state}
    end
  end

  @impl DBConnection
  def handle_begin(_opts, %__MODULE__{status: :idle} = state) do
    case do_simple_query(state, "START TRANSACTION READ WRITE") do
      {:ok, result, state} ->
        {:ok, result, %{state | status: :transaction}}

      {:error, reason, state} ->
        {:disconnect, connection_error(reason, []), state}
    end
  end

  def handle_begin(_opts, %__MODULE__{status: status} = state) do
    {status, state}
  end

  @impl DBConnection
  def handle_commit(_opts, %__MODULE__{status: :transaction} = state) do
    case do_simple_query(state, "COMMIT") do
      {:ok, result, state} ->
        {:ok, result, %{state | status: :idle}}

      {:error, reason, state} ->
        {:disconnect, connection_error(reason, []), state}
    end
  end

  def handle_commit(_opts, %__MODULE__{status: status} = state) do
    {status, state}
  end

  @impl DBConnection
  def handle_rollback(_opts, %__MODULE__{status: status} = state)
      when status in [:transaction, :error] do
    case do_simple_query(state, "ROLLBACK") do
      {:ok, result, state} ->
        {:ok, result, %{state | status: :idle}}

      {:error, reason, state} ->
        {:disconnect, connection_error(reason, []), state}
    end
  end

  def handle_rollback(_opts, %__MODULE__{status: status} = state) do
    {status, state}
  end

  @impl DBConnection
  def handle_close(_query, _opts, state) do
    # No-op for simple query protocol
    {:ok, nil, state}
  end

  # Cursor operations - not supported by XTDB simple query protocol
  @impl DBConnection
  def handle_declare(_query, _params, _opts, state) do
    {:error, %RuntimeError{message: "XTDB does not support cursors"}, state}
  end

  @impl DBConnection
  def handle_fetch(_query, _cursor, _opts, state) do
    {:error, %RuntimeError{message: "XTDB does not support cursors"}, state}
  end

  @impl DBConnection
  def handle_deallocate(_query, _cursor, _opts, state) do
    {:error, %RuntimeError{message: "XTDB does not support cursors"}, state}
  end

  # ============================================================================
  # Connection Handshake
  # ============================================================================

  defp send_startup(%__MODULE__{socket: socket}, username, database) do
    params =
      [
        "user",
        username,
        "database",
        database,
        "client_encoding",
        "UTF8"
      ]
      |> Enum.map(&(&1 <> <<0>>))
      |> IO.iodata_to_binary()

    # Protocol version 3.0
    version = <<0, 3, 0, 0>>
    message = version <> params <> <<0>>
    length = byte_size(message) + 4

    :gen_tcp.send(socket, <<length::32, message::binary>>)
  end

  defp handle_auth(state) do
    case recv_message(state) do
      {:ok, @auth_ok, state} ->
        {:ok, state}

      {:ok, <<?R, _length::32, 3::32>>, _state} ->
        {:error, :cleartext_password_required}

      {:ok, <<?R, _length::32, 5::32, _salt::binary-4>>, _state} ->
        {:error, :md5_password_required}

      {:ok, <<?E, _rest::binary>> = msg, _state} ->
        {:error, parse_error(msg)}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_auth_response, other}}
    end
  end

  defp wait_for_ready(state) do
    case recv_message(state) do
      {:ok, @ready_for_query_idle, state} ->
        {:ok, state}

      {:ok, @ready_for_query_transaction, state} ->
        {:ok, state}

      {:ok, <<?S, _rest::binary>>, state} ->
        # ParameterStatus message - skip and continue waiting
        wait_for_ready(state)

      {:ok, <<?K, _rest::binary>>, state} ->
        # BackendKeyData message - skip and continue waiting
        wait_for_ready(state)

      {:ok, <<?E, _rest::binary>> = msg, _state} ->
        {:error, parse_error(msg)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Query Execution
  # ============================================================================

  defp do_simple_query(state, sql, timeout \\ 15_000) do
    msg = <<?Q, byte_size(sql) + 5::32, sql::binary, 0>>

    case :gen_tcp.send(state.socket, msg) do
      :ok ->
        recv_query_response(state, nil, [], timeout)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp recv_query_response(state, columns, rows, timeout) do
    case recv_message(state, timeout) do
      {:ok, <<?T, _::binary>> = msg, state} ->
        # RowDescription
        {:ok, cols} = parse_row_description(msg)
        recv_query_response(state, cols, rows, timeout)

      {:ok, <<?D, _::binary>> = msg, state} ->
        # DataRow
        {:ok, row} = parse_data_row(msg)
        recv_query_response(state, columns, [row | rows], timeout)

      {:ok, <<?C, _::binary>>, state} ->
        # CommandComplete
        recv_query_response(state, columns, rows, timeout)

      {:ok, @ready_for_query_idle, state} ->
        result = build_result(columns, rows)
        {:ok, result, %{state | status: :idle}}

      {:ok, @ready_for_query_transaction, state} ->
        result = build_result(columns, rows)
        {:ok, result, %{state | status: :transaction}}

      {:ok, @ready_for_query_failed, state} ->
        result = build_result(columns, rows)
        {:ok, result, %{state | status: :error}}

      {:ok, <<?E, _rest::binary>> = msg, state} ->
        error = parse_error(msg)
        drain_until_ready(state, {:error, error}, timeout)

      {:ok, <<?N, _rest::binary>>, state} ->
        # NoticeResponse - skip
        recv_query_response(state, columns, rows, timeout)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp build_result(nil, rows) do
    %Postgrex.Result{
      columns: [],
      rows: Enum.reverse(rows),
      num_rows: length(rows)
    }
  end

  defp build_result(columns_with_oids, rows) do
    {names, type_oids} = Enum.unzip(columns_with_oids)
    reversed_rows = Enum.reverse(rows)

    cast_rows =
      Enum.map(reversed_rows, fn row ->
        row
        |> Enum.zip(type_oids)
        |> Enum.map(fn {val, oid} -> cast_by_oid(val, oid) end)
      end)

    %Postgrex.Result{
      columns: names,
      rows: cast_rows,
      num_rows: length(cast_rows)
    }
  end

  # Cast text-format values from the simple query protocol using type OIDs
  # from the RowDescription message. XTDB sends real PostgreSQL type OIDs,
  # so we can parse values at the connection level, delivering already-typed
  # data to downstream code.
  defp cast_by_oid(nil, _oid), do: nil
  defp cast_by_oid(val, 16), do: val in ["t", "true"]
  defp cast_by_oid(val, oid) when oid in [20, 21, 23, 26], do: String.to_integer(val)
  defp cast_by_oid(val, oid) when oid in [700, 701], do: parse_float(val)
  defp cast_by_oid(val, 1082), do: Date.from_iso8601!(val)
  defp cast_by_oid(val, 1114), do: NaiveDateTime.from_iso8601!(val)
  defp cast_by_oid(val, 1184), do: parse_timestamptz(val)
  defp cast_by_oid(val, 114), do: parse_json(val)
  defp cast_by_oid(val, 25), do: AshXTDB.UTF8Workaround.decode(val)
  defp cast_by_oid(val, _oid), do: val

  defp parse_float(val) do
    case Float.parse(val) do
      {f, ""} -> f
      _ -> val
    end
  end

  # XTDB uses space separator ("2024-01-15 10:30:00+00:00") instead of ISO 8601 "T"
  defp parse_timestamptz(val) do
    # Replace first space with T to make it ISO 8601 compliant
    normalized = String.replace(val, " ", "T", global: false)

    case DateTime.from_iso8601(normalized) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> val
    end
  end

  defp parse_json(val) when is_binary(val) do
    case Jason.decode(val, keys: :atoms) do
      {:ok, decoded} -> decoded
      {:error, _} -> val
    end
  end

  defp drain_until_ready(state, result, timeout) do
    case recv_message(state, timeout) do
      {:ok, <<?Z, _::binary>>, state} ->
        {:error, error} = result
        {:error, error, state}

      {:ok, _, state} ->
        drain_until_ready(state, result, timeout)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # ============================================================================
  # Message Parsing
  # ============================================================================

  defp recv_message(%__MODULE__{socket: socket, buffer: buffer} = state, timeout \\ 10_000) do
    case buffer do
      <<type::8, length::32, rest::binary>> when byte_size(rest) >= length - 4 ->
        payload_length = length - 4
        <<payload::binary-size(payload_length), new_buffer::binary>> = rest
        {:ok, <<type, length::32, payload::binary>>, %{state | buffer: new_buffer}}

      _ ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, data} ->
            recv_message(%{state | buffer: buffer <> data}, timeout)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp parse_row_description(<<?T, length::32, rest::binary>>) do
    payload_length = length - 4
    <<payload::binary-size(payload_length), _::binary>> = rest
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

  defp parse_data_row(<<?D, length::32, rest::binary>>) do
    payload_length = length - 4
    <<payload::binary-size(payload_length), _::binary>> = rest
    <<num_fields::16, fields_data::binary>> = payload

    {values, _} =
      Enum.reduce(1..num_fields//1, {[], fields_data}, fn _, {vals, data} ->
        <<field_length::32-signed, remaining::binary>> = data

        if field_length == -1 do
          {[nil | vals], remaining}
        else
          <<value::binary-size(field_length), rest::binary>> = remaining
          {[value | vals], rest}
        end
      end)

    {:ok, Enum.reverse(values)}
  end

  defp parse_error(<<?E, length::32, rest::binary>>) do
    payload_length = length - 4
    <<payload::binary-size(payload_length), _::binary>> = rest
    fields = parse_error_fields(payload, %{})

    %Postgrex.Error{
      postgres: %{
        code: Map.get(fields, ?C, ""),
        message: Map.get(fields, ?M, "Unknown error"),
        severity: Map.get(fields, ?S, "ERROR")
      }
    }
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

  # ============================================================================
  # Error Helpers
  # ============================================================================

  defp connection_error(reason, opts) do
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

  defp ping_error do
    DBConnection.ConnectionError.exception("ping failed")
  end
end
