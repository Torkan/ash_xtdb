# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SyncResource do
  @moduledoc """
  An Ash extension that automatically syncs resource changes to XTDB.

  This extension adds after_action hooks to create, update, and destroy actions
  that dispatch sync operations through a configured `AshXTDB.SyncAdapter`.
  By default, this uses the Oban adapter which inserts a job inside the same
  PostgreSQL transaction — ensuring the job only exists for committed data.

  ## Basic Usage

      defmodule MyApp.User do
        use Ash.Resource,
          domain: MyApp.Domain,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshXTDB.SyncResource]

        xtdb_sync do
          # Syncs to MyApp.User.History by default
        end
      end

  ## Sync Adapter Configuration

  Configure which adapter handles the sync dispatch:

      # Default: Oban adapter (async, eventual consistency)
      config :ash_xtdb,
        sync_adapter: {AshXTDB.SyncAdapters.Oban, oban: MyApp.Oban, queue: :xtdb_sync}

  See `AshXTDB.SyncAdapter` for implementing custom adapters.

  ## Custom History Resource

      xtdb_sync do
        history_resource MyApp.UserHistory
      end

  ## Custom Sync Function (escape hatch)

  For full control, provide a custom sync function that bypasses the adapter:

      xtdb_sync do
        sync_function &MyApp.XTDBSync.run_sync/4
      end

  ## Escape Hatches

  ### Skip specific actions via DSL

      xtdb_sync do
        skip_actions [:backfill, :import]
      end

  ### Skip programmatically via context

      changeset
      |> Ash.Changeset.set_context(%{skip_xtdb_sync: true})

  ### Custom temporal values via context

      changeset
      |> Ash.Changeset.set_context(%{
        xtdb_valid_from: ~U[2024-01-01 00:00:00Z],
        xtdb_valid_to: ~U[2024-12-31 23:59:59Z]
      })
  """

  @xtdb_sync %Spark.Dsl.Section{
    name: :xtdb_sync,
    describe: "Configuration for syncing resource changes to XTDB",
    schema: [
      history_resource: [
        type: :atom,
        required: false,
        doc: """
        The XTDB History resource to sync to.
        Defaults to `<Resource>.History`.
        """
      ],
      sync_function: [
        type: {:mfa_or_fun, 4},
        required: false,
        doc: """
        Custom function to call when syncing changes.
        Receives `(resource, action_type, result, context)`.
        Must return `:ok` or `{:error, reason}`.
        If not provided, uses the default direct sync to history_resource.
        """
      ],
      skip_actions: [
        type: {:list, :atom},
        default: [],
        doc: "List of action names to skip syncing for"
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@xtdb_sync],
    transformers: [AshXTDB.SyncResource.Transformers.AddSyncHooks]
end
