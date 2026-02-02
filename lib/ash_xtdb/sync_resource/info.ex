# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SyncResource.Info do
  @moduledoc """
  Introspection helpers for the AshXTDB.SyncResource extension.
  """

  @doc """
  Returns the configured history resource.

  If not explicitly configured, defaults to `<Resource>.History`.
  """
  @spec history_resource(Ash.Resource.t()) :: module()
  def history_resource(resource) do
    case Spark.Dsl.Extension.fetch_opt(resource, [:xtdb_sync], :history_resource) do
      {:ok, history} -> history
      :error -> Module.concat(resource, History)
    end
  end

  @doc """
  Returns the configured sync function, if any.
  """
  @spec sync_function(Ash.Resource.t()) :: {:ok, function() | mfa()} | :error
  def sync_function(resource) do
    Spark.Dsl.Extension.fetch_opt(resource, [:xtdb_sync], :sync_function)
  end

  @doc """
  Returns the list of actions to skip syncing for.
  """
  @spec skip_actions(Ash.Resource.t()) :: list(atom())
  def skip_actions(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:xtdb_sync], :skip_actions, [])
  end

  @doc """
  Returns whether an action should be synced.
  """
  @spec sync_action?(Ash.Resource.t(), atom()) :: boolean()
  def sync_action?(resource, action_name) do
    action_name not in skip_actions(resource)
  end
end
