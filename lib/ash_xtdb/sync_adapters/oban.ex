# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SyncAdapters.Oban do
  @moduledoc """
  Oban-based async sync adapter for XTDB.

  Inserts an Oban job into `oban_jobs` inside the same PostgreSQL transaction
  as the Ash action. If the transaction rolls back, the job disappears.
  XTDB only receives synced data for committed records.

  ## Configuration

      config :ash_xtdb,
        sync_adapter: {AshXTDB.SyncAdapters.Oban, oban: MyApp.Oban, queue: :xtdb_sync}

  ## Options

  - `:oban` - The Oban instance name (default: `Oban`)
  - `:queue` - The Oban queue name (default: `:xtdb_sync`)

  ## Queue Requirements

  The host application must configure the queue with `max_concurrency: 1`
  to guarantee ordered processing:

      config :my_app, Oban,
        queues: [xtdb_sync: 1]
  """

  @behaviour AshXTDB.SyncAdapter

  @impl true
  def enqueue_sync(history_resource, action_type, data, context, opts) do
    oban_name = Keyword.get(opts, :oban, Oban)
    queue = Keyword.get(opts, :queue, :xtdb_sync)

    job_args = build_job_args(history_resource, action_type, data, context)

    changeset =
      AshXTDB.SyncWorker.new(job_args, queue: queue)

    try do
      case Oban.insert(oban_name, changeset) do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, reason}
      end
    rescue
      e in [ArgumentError, RuntimeError] ->
        {:error, "Oban not running: #{Exception.message(e)}"}
    end
  end

  defp build_job_args(history_resource, action_type, data, context) do
    record_data = serialize_data(data)
    valid_from = extract_valid_from(action_type, data, context)

    args = %{
      "sync_type" => to_string(action_type),
      "history_resource" => to_string(history_resource),
      "record_data" => record_data,
      "valid_from" => serialize_datetime(valid_from),
      "tenant" => context.tenant
    }

    if context.valid_to do
      Map.put(args, "valid_to", serialize_datetime(context.valid_to))
    else
      args
    end
  end

  defp extract_valid_from(action_type, data, context) do
    # Use explicit context override first
    cond do
      context.valid_from ->
        context.valid_from

      action_type == :create && is_map(data) ->
        get_timestamp(data, :inserted_at) || DateTime.utc_now()

      action_type == :update && is_map(data) ->
        get_timestamp(data, :updated_at) || DateTime.utc_now()

      action_type == :destroy ->
        DateTime.utc_now()

      true ->
        DateTime.utc_now()
    end
  end

  defp get_timestamp(data, field) when is_map(data) do
    case Map.get(data, field) || Map.get(data, to_string(field)) do
      %DateTime{} = dt -> dt
      %NaiveDateTime{} = ndt -> DateTime.from_naive!(ndt, "Etc/UTC")
      _ -> nil
    end
  end

  defp serialize_data(data) when is_struct(data) do
    data
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__metadata__])
    |> serialize_data()
  end

  defp serialize_data(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {to_string(k), serialize_value(v)} end)
  end

  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp serialize_value(%Date{} = d), do: Date.to_iso8601(d)
  defp serialize_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp serialize_value(value) when is_struct(value), do: to_string(value)
  defp serialize_value(value), do: value

  defp serialize_datetime(nil), do: nil
  defp serialize_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_datetime(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
end
