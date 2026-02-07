# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SyncWorker do
  @moduledoc """
  Oban worker that syncs data to XTDB.

  Processes jobs enqueued by `AshXTDB.SyncAdapters.Oban`. Each job contains
  the action type, serialized record data, and temporal metadata.

  ## Algorithm (single-concurrency queue)

  Since jobs process in insertion order with a single worker:

  - **CREATE / UPDATE**: Unbounded INSERT with `_valid_from` — safe because
    ordering is guaranteed.
  - **DESTROY**: Open-ended temporal DELETE — truncates history at the event time.

  ## Retry Safety

  - CREATE/UPDATE retry: Duplicate INSERT creates a new system-time version
    but the current view is identical. Safe.
  - DESTROY retry: DELETE on already-deleted time range is a no-op. Safe.
  """

  use Oban.Worker,
    queue: :xtdb_sync,
    max_attempts: 10,
    priority: 0

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "sync_type" => sync_type,
      "history_resource" => history_resource_string,
      "record_data" => record_data,
      "valid_from" => valid_from_string,
      "tenant" => tenant
    } = args

    history_resource = String.to_existing_atom(history_resource_string)
    valid_from = parse_datetime(valid_from_string)
    valid_to = parse_datetime(args["valid_to"])

    case sync_type do
      type when type in ["create", "update"] ->
        upsert_to_xtdb(history_resource, record_data, valid_from, valid_to, tenant)

      "destroy" ->
        delete_from_xtdb(history_resource, record_data, valid_from, tenant)
    end
  end

  # ============================================================================
  # XTDB Operations
  # ============================================================================

  defp upsert_to_xtdb(history_resource, data, valid_from, valid_to, tenant) do
    repo = get_repo(history_resource)
    table = get_table(history_resource)
    {columns, values, params} = build_insert_params(history_resource, data)

    sql =
      if valid_to do
        # Bounded INSERT — splices into [valid_from, valid_to)
        param_idx = length(params) + 1

        "INSERT INTO #{quote_table(table)} (#{columns}, _valid_from, _valid_to) " <>
          "VALUES (#{values}, $#{param_idx}, $#{param_idx + 1})"
      else
        # Unbounded INSERT — safe with single-concurrency queue
        param_idx = length(params) + 1

        "INSERT INTO #{quote_table(table)} (#{columns}, _valid_from) " <>
          "VALUES (#{values}, $#{param_idx})"
      end

    time_params =
      if valid_to do
        [valid_from, valid_to]
      else
        [valid_from]
      end

    opts = if tenant, do: [tenant: tenant], else: []

    case repo.query(sql, params ++ time_params, opts) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        Logger.error("XTDB sync INSERT failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp delete_from_xtdb(history_resource, data, valid_from, tenant) do
    repo = get_repo(history_resource)
    table = get_table(history_resource)
    {id_column, id_value} = get_primary_key(history_resource, data)

    sql =
      "DELETE FROM #{quote_table(table)} " <>
        "FOR PORTION OF VALID_TIME FROM $1 TO NULL " <>
        "WHERE #{quote_column(id_column)} = $2"

    opts = if tenant, do: [tenant: tenant], else: []

    case repo.query(sql, [valid_from, id_value], opts) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        Logger.error("XTDB sync DELETE failed: #{inspect(error)}")
        {:error, error}
    end
  end

  # ============================================================================
  # SQL Helpers
  # ============================================================================

  defp build_insert_params(history_resource, data) do
    attrs =
      history_resource
      |> Ash.Resource.Info.attributes()
      |> Enum.reject(&(&1.name in [:_valid_from, :_valid_to]))

    {columns, values, params, _idx} =
      Enum.reduce(attrs, {[], [], [], 1}, fn attr, {cols, vals, params, idx} ->
        attr_name = to_string(attr.name)

        case Map.get(data, attr_name) do
          nil ->
            {cols, vals, params, idx}

          value ->
            col = quote_column(attr_name)
            val = "$#{idx}"
            param = deserialize_value(value, attr.type)
            {cols ++ [col], vals ++ [val], params ++ [param], idx + 1}
        end
      end)

    {Enum.join(columns, ", "), Enum.join(values, ", "), params}
  end

  defp get_primary_key(history_resource, data) do
    [pkey_field | _] = Ash.Resource.Info.primary_key(history_resource)
    pkey_name = to_string(pkey_field)
    {pkey_name, Map.get(data, pkey_name)}
  end

  defp get_repo(history_resource) do
    AshXTDB.DataLayer.Info.repo!(history_resource)
  end

  defp get_table(history_resource) do
    AshXTDB.DataLayer.Info.table!(history_resource)
  end

  defp quote_table(table), do: "\"#{table}\""
  defp quote_column(col), do: "\"#{col}\""

  # ============================================================================
  # Deserialization
  # ============================================================================

  defp deserialize_value(value, _type) when is_nil(value), do: nil

  defp deserialize_value(value, type) when is_binary(value) do
    cond do
      type in [Ash.Type.UtcDatetime, Ash.Type.UtcDatetimeUsec, :utc_datetime, :utc_datetime_usec] ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> dt
          _ -> value
        end

      type in [Ash.Type.NaiveDatetime, :naive_datetime, :naive_datetime_usec] ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> ndt
          _ -> value
        end

      type in [Ash.Type.Date, :date] ->
        case Date.from_iso8601(value) do
          {:ok, d} -> d
          _ -> value
        end

      type in [Ash.Type.Decimal, :decimal] ->
        Decimal.new(value)

      type in [Ash.Type.UUID, :uuid] ->
        value

      true ->
        value
    end
  end

  defp deserialize_value(value, _type), do: value

  defp parse_datetime(nil), do: nil

  defp parse_datetime(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
