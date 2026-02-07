# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SyncAdapter do
  @moduledoc """
  Behaviour for XTDB sync adapters.

  AshXTDB ships with a built-in Oban adapter (`AshXTDB.SyncAdapters.Oban`).
  Implement this behaviour for custom sync strategies (e.g., Broadway,
  GenStage, or direct HTTP).

  ## Configuration

      # Default: Built-in Oban adapter
      config :ash_xtdb,
        sync_adapter: {AshXTDB.SyncAdapters.Oban, oban: MyApp.Oban, queue: :xtdb_sync}

      # Custom adapter
      config :ash_xtdb,
        sync_adapter: {MyApp.CustomXTDBSync, []}

  ## Callback

  The `enqueue_sync/5` callback is called from the after_action hook, which
  runs inside the PostgreSQL transaction. For the Oban adapter, this means
  the Oban job is inserted in the same transaction — if the transaction
  rolls back, the job disappears.
  """

  @type action_type :: :create | :update | :destroy
  @type sync_context :: %{
          action_name: atom(),
          actor: term(),
          tenant: term(),
          valid_from: DateTime.t() | nil,
          valid_to: DateTime.t() | nil
        }

  @callback enqueue_sync(
              history_resource :: module(),
              action_type :: action_type(),
              data :: map(),
              context :: sync_context(),
              opts :: keyword()
            ) :: :ok | {:error, term()}
end
