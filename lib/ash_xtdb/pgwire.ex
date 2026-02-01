# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.PgWire do
  @moduledoc """
  A minimal PostgreSQL wire protocol client for XTDB.

  XTDB doesn't support PostgreSQL's pg_catalog type discovery queries,
  so we use a custom client that works with the simple query protocol only.
  """

  use GenServer

  require Logger

  defstruct [:socket, :buffer, :opts]

  # PostgreSQL message types
  @auth_ok <<?R, 0, 0, 0, 8, 0, 0, 0, 0>>
  @ready_for_query <<?Z, 0, 0, 0, 5, ?I>>
  @ready_for_query_transaction <<?Z, 0, 0, 0, 5, ?T>>
  @ready_for_query_failed <<?Z, 0, 0, 0, 5, ?E>>

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  def query(server, sql, _params \\ [], _opts \\ []) do
    GenServer.call(server, {:query, sql}, 30_000)
  end

  def query!(server, sql, params \\ [], opts \\ []) do
    case query(server, sql, params, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    hostname = Keyword.get(opts, :hostname, "localhost")
    port = Keyword.get(opts, :port, 5432)
    username = Keyword.get(opts, :username, "xtdb")
    database = Keyword.get(opts, :database, "xtdb")

    case :gen_tcp.connect(to_charlist(hostname), port, [
           :binary,
           {:active, false},
           {:packet, :raw}
         ]) do
      {:ok, socket} ->
        state = %__MODULE__{socket: socket, buffer: <<>>, opts: opts}

        with :ok <- send_startup(state, username, database),
             {:ok, state} <- handle_auth(state),
             {:ok, state} <- wait_for_ready(state) do
          {:ok, state}
        else
          {:error, reason} ->
            :gen_tcp.close(socket)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:query, sql}, _from, state) do
    case do_query(state, sql) do
      {:ok, result, state} ->
        {:reply, {:ok, result}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, %{socket: socket}) when socket != nil do
    # Send Terminate message
    :gen_tcp.send(socket, <<?X, 0, 0, 0, 4>>)
    :gen_tcp.close(socket)
  end

  def terminate(_reason, _state), do: :ok

  # ============================================================================
  # Connection Handshake
  # ============================================================================

  defp send_startup(state, username, database) do
    # Build startup message
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

    :gen_tcp.send(state.socket, <<length::32, message::binary>>)
  end

  defp handle_auth(state) do
    case recv_message(state) do
      {:ok, @auth_ok, state} ->
        {:ok, state}

      {:ok, <<?R, _length::32, 3::32>>, _state} ->
        # CleartextPassword - not typical for XTDB
        {:error, :cleartext_password_required}

      {:ok, <<?R, _length::32, 5::32, salt::binary-4>>, _state} ->
        # MD5Password - not typical for XTDB
        {:error, {:md5_password_required, salt}}

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
      {:ok, @ready_for_query, state} ->
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

  defp do_query(state, sql) do
    # Simple query message: 'Q' + length + query + null
    msg = <<?Q, byte_size(sql) + 5::32, sql::binary, 0>>

    case :gen_tcp.send(state.socket, msg) do
      :ok ->
        recv_query_response(state, nil, [])

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp recv_query_response(state, columns, rows) do
    case recv_message(state) do
      {:ok, <<?T, _::binary>> = msg, state} ->
        # RowDescription
        {:ok, cols} = parse_row_description(msg)
        recv_query_response(state, cols, rows)

      {:ok, <<?D, _::binary>> = msg, state} ->
        # DataRow
        {:ok, row} = parse_data_row(msg)
        recv_query_response(state, columns, [row | rows])

      {:ok, <<?C, _::binary>>, state} ->
        # CommandComplete
        recv_query_response(state, columns, rows)

      {:ok, @ready_for_query, state} ->
        result = %Postgrex.Result{
          columns: columns || [],
          rows: Enum.reverse(rows),
          num_rows: length(rows)
        }

        {:ok, result, state}

      {:ok, @ready_for_query_transaction, state} ->
        result = %Postgrex.Result{
          columns: columns || [],
          rows: Enum.reverse(rows),
          num_rows: length(rows)
        }

        {:ok, result, state}

      {:ok, @ready_for_query_failed, state} ->
        result = %Postgrex.Result{
          columns: columns || [],
          rows: Enum.reverse(rows),
          num_rows: length(rows)
        }

        {:ok, result, state}

      {:ok, <<?E, _rest::binary>> = msg, state} ->
        error = parse_error(msg)
        # Need to continue reading until ReadyForQuery
        drain_until_ready(state, {:error, error})

      {:ok, <<?N, _rest::binary>>, state} ->
        # NoticeResponse - skip
        recv_query_response(state, columns, rows)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp drain_until_ready(state, result) do
    case recv_message(state) do
      {:ok, <<?Z, _::binary>>, state} ->
        case result do
          {:error, error} -> {:error, error, state}
          _ -> result
        end

      {:ok, _, state} ->
        drain_until_ready(state, result)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # ============================================================================
  # Message Parsing
  # ============================================================================

  defp recv_message(%{socket: socket, buffer: buffer} = state) do
    case buffer do
      <<type::8, length::32, rest::binary>> when byte_size(rest) >= length - 4 ->
        payload_length = length - 4
        <<payload::binary-size(payload_length), new_buffer::binary>> = rest
        {:ok, <<type, length::32, payload::binary>>, %{state | buffer: new_buffer}}

      _ ->
        case :gen_tcp.recv(socket, 0, 10_000) do
          {:ok, data} ->
            recv_message(%{state | buffer: buffer <> data})

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
      Enum.reduce(1..num_fields, {[], fields_data}, fn _, {cols, data} ->
        {name, rest} = parse_string(data)

        <<_table_oid::32, _col_num::16, _type_oid::32, _type_size::16, _type_mod::32, _format::16,
          remaining::binary>> = rest

        {[name | cols], remaining}
      end)

    {:ok, Enum.reverse(columns)}
  end

  defp parse_data_row(<<?D, length::32, rest::binary>>) do
    payload_length = length - 4
    <<payload::binary-size(payload_length), _::binary>> = rest
    <<num_fields::16, fields_data::binary>> = payload

    {values, _} =
      Enum.reduce(1..num_fields, {[], fields_data}, fn _, {vals, data} ->
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
end
