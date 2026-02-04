# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SyncResource.Changes.SyncHook do
  @moduledoc """
  A change that adds an after_action hook to sync data to XTDB.

  This change is automatically added by the `AshXTDB.SyncResource` transformer.
  It can also be used manually for fine-grained control over syncing behavior.

  ## Options

  - `:action_type` - The type of action (`:create`, `:update`, or `:destroy`)
  - `:history_resource` - The XTDB History resource to sync to
  - `:sync_function` - Optional custom function for syncing (overrides default behavior)
  - `:valid_from` - Optional override for valid_from timestamp
  - `:valid_to` - Optional override for valid_to timestamp

  ## Default Sync Behavior

  When no `sync_function` is provided, the change performs direct sync:

  - `:create` / `:update` → Calls the `:sync` action on the history resource (upsert)
  - `:destroy` → Calls the `:delete_sync` action on the history resource

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
    # This change adds an after_action hook, so we call change/3 from atomic/3
    # to ensure the hook is registered regardless of atomic vs non-atomic execution
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
            default_sync(history_resource, action_type, sync_data, sync_context)
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
    # Get valid_from/valid_to from options (for manual usage with arg())
    # or from changeset context (for programmatic override)
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
    # For destroy, return a map with just the primary key field(s)
    pkey_fields = Ash.Resource.Info.primary_key(changeset.resource)

    Map.new(pkey_fields, fn field ->
      {field, Map.get(result, field)}
    end)
  end

  defp build_sync_data(_action_type, result, _changeset) do
    # For create/update, return the full record
    result
  end

  # ============================================================================
  # Default Direct Sync
  # ============================================================================

  defp default_sync(history_resource, :destroy, data, context) do
    # For destroy, delete the record from XTDB
    # This sets _valid_to to now, preserving history
    pkey_fields = Ash.Resource.Info.primary_key(history_resource)

    # Build a filter for the primary key
    pkey_filter =
      Enum.map(pkey_fields, fn field ->
        {field, Map.get(data, field)}
      end)

    # Build options from context (tenant, actor)
    opts =
      [return_errors?: true]
      |> then(fn opts ->
        if context.tenant, do: Keyword.put(opts, :tenant, context.tenant), else: opts
      end)
      |> then(fn opts ->
        if context.actor, do: Keyword.put(opts, :actor, context.actor), else: opts
      end)

    case history_resource
         |> Ash.Query.filter(^pkey_filter)
         |> Ash.bulk_destroy(:delete_sync, %{}, opts) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: errors} ->
        Logger.error("XTDB sync delete failed: #{inspect(errors)}")
        {:error, "XTDB sync failed: #{inspect(errors)}"}
    end
  end

  defp default_sync(history_resource, _action_type, record, context) do
    # For create/update, upsert the record using the :sync action
    # Extract attribute values from the source record
    attrs = extract_syncable_attributes(record, history_resource)

    # Build options from context (tenant, actor)
    opts =
      []
      |> then(fn opts ->
        if context.tenant, do: Keyword.put(opts, :tenant, context.tenant), else: opts
      end)
      |> then(fn opts ->
        if context.actor, do: Keyword.put(opts, :actor, context.actor), else: opts
      end)

    case history_resource
         |> Ash.Changeset.for_create(:sync, attrs, opts)
         |> Ash.create(opts) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("XTDB sync failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp extract_syncable_attributes(record, history_resource) do
    # Get the attributes that the history resource accepts for sync
    history_attrs =
      history_resource
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    # Extract matching attributes from the source record
    # Filter out Ash.NotLoaded values - these occur when the record wasn't fully loaded
    record
    |> Map.from_struct()
    |> Map.take(history_attrs)
  end

  # ============================================================================
  # Custom Sync Function
  # ============================================================================

  defp call_sync_function({mod, fun, args}, resource, action_type, data, context) do
    apply(mod, fun, args ++ [resource, action_type, data, context])
  end

  defp call_sync_function(fun, resource, action_type, data, context) when is_function(fun, 4) do
    fun.(resource, action_type, data, context)
  end
end
