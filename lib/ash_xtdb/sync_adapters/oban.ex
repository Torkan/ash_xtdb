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
    record_data = serialize_data(data, context.resource)

    args = %{
      "sync_type" => to_string(action_type),
      "history_resource" => to_string(history_resource),
      "record_data" => record_data,
      "valid_from" => serialize_json(context.valid_from),
      "tenant" => context.tenant
    }

    if context.valid_to do
      Map.put(args, "valid_to", serialize_json(context.valid_to))
    else
      args
    end
  end

  # ============================================================================
  # Type-aware serialization
  # ============================================================================

  defp serialize_data(data, resource) when is_map(data) do
    attributes_by_name =
      resource
      |> Ash.Resource.Info.attributes()
      |> Map.new(&{&1.name, &1})

    Map.new(data, fn {k, v} ->
      case Map.get(attributes_by_name, k) do
        %{type: type, constraints: constraints} ->
          {to_string(k), dump_and_serialize(type, v, constraints)}

        nil ->
          {to_string(k), serialize_json(v)}
      end
    end)
  end

  defp dump_and_serialize(_type, nil, _constraints), do: nil

  defp dump_and_serialize(type, value, constraints) do
    case Ash.Type.dump_to_embedded(type, value, constraints) do
      {:ok, dumped} -> serialize_json(dumped)
      :error -> serialize_json(value)
    end
  end

  # Recursively ensures all values are JSON-safe for Oban job args.
  defp serialize_json(nil), do: nil
  defp serialize_json(value) when is_boolean(value), do: value
  defp serialize_json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_json(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp serialize_json(%Date{} = d), do: Date.to_iso8601(d)
  defp serialize_json(%Time{} = t), do: Time.to_iso8601(t)
  defp serialize_json(%Decimal{} = d), do: Decimal.to_string(d)

  defp serialize_json(value) when is_struct(value) do
    value |> Map.from_struct() |> Map.drop([:__meta__, :__metadata__]) |> serialize_json()
  end

  defp serialize_json(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), serialize_json(v)} end)
  end

  defp serialize_json(value) when is_list(value), do: Enum.map(value, &serialize_json/1)
  defp serialize_json(value) when is_atom(value), do: to_string(value)
  defp serialize_json(value), do: value
end
