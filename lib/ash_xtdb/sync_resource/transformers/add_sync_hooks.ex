# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SyncResource.Transformers.AddSyncHooks do
  @moduledoc """
  Adds after_action hooks to create, update, and destroy actions for XTDB sync.

  The hooks sync data to a History resource within the same transaction,
  ensuring consistency between the primary data store and XTDB.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def after?(Ash.Resource.Transformers.SetTypes), do: true
  def after?(_), do: false

  def transform(dsl) do
    module = Transformer.get_persisted(dsl, :module)

    history_resource =
      Transformer.get_option(dsl, [:xtdb_sync], :history_resource) ||
        default_history_resource(module)

    sync_function = Transformer.get_option(dsl, [:xtdb_sync], :sync_function)
    skip_actions = Transformer.get_option(dsl, [:xtdb_sync], :skip_actions, [])

    actions = Transformer.get_entities(dsl, [:actions])

    dsl =
      Enum.reduce(actions, dsl, fn action, dsl ->
        if should_add_hook?(action, skip_actions) do
          add_sync_hook(dsl, action, history_resource, sync_function)
        else
          dsl
        end
      end)

    {:ok, dsl}
  end

  defp default_history_resource(module) do
    Module.concat(module, History)
  end

  defp should_add_hook?(action, skip_actions) do
    action.type in [:create, :update, :destroy] and
      action.name not in skip_actions
  end

  defp add_sync_hook(dsl, action, history_resource, sync_function) do
    hook_change = build_hook_change(action.type, history_resource, sync_function)

    Transformer.replace_entity(
      dsl,
      [:actions],
      %{action | changes: action.changes ++ [hook_change]},
      &(&1.name == action.name)
    )
  end

  defp build_hook_change(action_type, history_resource, sync_function) do
    opts = [
      action_type: action_type,
      history_resource: history_resource
    ]

    opts = if sync_function, do: Keyword.put(opts, :sync_function, sync_function), else: opts

    %Ash.Resource.Change{
      change: {AshXTDB.SyncResource.Changes.SyncHook, opts},
      on: nil,
      only_when_valid?: true,
      description: "Sync to XTDB",
      always_atomic?: false,
      where: []
    }
  end
end
