# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SyncResource.Changes.SyncHook do
  @moduledoc """
  A change that adds an after_action hook to enqueue XTDB sync.

  This change is automatically added by the `AshXTDB.SyncResource` transformer.
  It dispatches sync operations through the configured `AshXTDB.SyncAdapter`
  (default: Oban-based async sync).

  ## Options

  - `:action_type` - The type of action (`:create`, `:update`, or `:destroy`)
  - `:history_resource` - The XTDB History resource to sync to
  - `:sync_function` - Optional custom function for syncing (overrides adapter dispatch)
  - `:valid_from` - Optional override for valid_from timestamp
  - `:valid_to` - Optional override for valid_to timestamp

  ## Sync Flow

  1. After-action hook fires (inside the PostgreSQL transaction)
  2. Hook builds sync data and context
  3. If `sync_function` is configured, calls it directly (escape hatch)
  4. Otherwise, dispatches through the configured `AshXTDB.SyncAdapter`
  5. For the Oban adapter, this inserts a job in `oban_jobs` — same PG transaction

  ## Manual Usage

      create :backfill do
        argument :valid_from, :utc_datetime_usec

        change {AshXTDB.SyncResource.Changes.SyncHook, [
          action_type: :create,
          history_resource: MyApp.User.History,
          valid_from: arg(:valid_from)
        ]}
      end
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end

  @impl true
  def change(changeset, opts, context) do
    action_type = Keyword.fetch!(opts, :action_type)
    history_resource = Keyword.fetch!(opts, :history_resource)
    sync_function = Keyword.get(opts, :sync_function)
    valid_from_opt = Keyword.get(opts, :valid_from)
    valid_to_opt = Keyword.get(opts, :valid_to)

    Ash.Changeset.after_action(changeset, fn changeset, result ->
      if skip_sync?(changeset) do
        {:ok, result}
      else
        sync_context = build_sync_context(changeset, context, valid_from_opt, valid_to_opt)
        sync_data = build_sync_data(action_type, result, changeset)

        sync_result =
          if sync_function do
            call_sync_function(
              sync_function,
              changeset.resource,
              action_type,
              sync_data,
              sync_context
            )
          else
            dispatch_to_adapter(history_resource, action_type, sync_data, sync_context)
          end

        case sync_result do
          :ok ->
            {:ok, result}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end)
  end

  defp skip_sync?(changeset) do
    changeset.context[:skip_xtdb_sync] == true
  end

  defp build_sync_context(changeset, context, valid_from_opt, valid_to_opt) do
    valid_from =
      case valid_from_opt do
        {:_arg, arg_name} -> Ash.Changeset.get_argument(changeset, arg_name)
        value -> value
      end || changeset.context[:xtdb_valid_from]

    valid_to =
      case valid_to_opt do
        {:_arg, arg_name} -> Ash.Changeset.get_argument(changeset, arg_name)
        value -> value
      end || changeset.context[:xtdb_valid_to]

    %{
      action_name: changeset.action.name,
      actor: context.actor,
      tenant: changeset.tenant,
      valid_from: valid_from,
      valid_to: valid_to
    }
  end

  defp build_sync_data(:destroy, result, changeset) do
    pkey_fields = Ash.Resource.Info.primary_key(changeset.resource)

    Map.new(pkey_fields, fn field ->
      {field, Map.get(result, field)}
    end)
  end

  defp build_sync_data(_action_type, result, _changeset) do
    result
  end

  # ============================================================================
  # Adapter Dispatch
  # ============================================================================

  defp dispatch_to_adapter(history_resource, action_type, data, context) do
    {adapter, opts} = get_sync_adapter()
    adapter.enqueue_sync(history_resource, action_type, data, context, opts)
  end

  @doc false
  def get_sync_adapter do
    case Application.get_env(:ash_xtdb, :sync_adapter) do
      {module, opts} when is_atom(module) ->
        {module, opts}

      module when is_atom(module) and not is_nil(module) ->
        {module, []}

      nil ->
        {AshXTDB.SyncAdapters.Oban, []}
    end
  end

  # ============================================================================
  # Custom Sync Function (escape hatch, backward compat)
  # ============================================================================

  defp call_sync_function({mod, fun, args}, resource, action_type, data, context) do
    apply(mod, fun, args ++ [resource, action_type, data, context])
  end

  defp call_sync_function(fun, resource, action_type, data, context) when is_function(fun, 4) do
    fun.(resource, action_type, data, context)
  end
end
