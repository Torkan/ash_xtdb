# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SyncResource do
  @moduledoc """
  An Ash extension that automatically syncs resource changes to XTDB.

  This extension adds after_action hooks to create, update, and destroy actions
  that sync data to a corresponding XTDB History resource. The sync runs within
  the same transaction as the action, ensuring consistency.

  ## Basic Usage

  By default, the extension syncs to `<Resource>.History`:

      defmodule MyApp.User do
        use Ash.Resource,
          domain: MyApp.Domain,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshXTDB.SyncResource]

        xtdb_sync do
          # Syncs to MyApp.User.History by default
        end
      end

  ## Custom History Resource

      xtdb_sync do
        history_resource MyApp.UserHistory
      end

  ## Custom Sync Function

  For advanced use cases (e.g., Oban jobs), provide a custom sync function:

      xtdb_sync do
        sync_function &MyApp.XTDBSync.run_sync/4
      end

  The sync function receives four arguments:

      @spec run_sync(
        resource :: module(),
        action_type :: :create | :update | :destroy,
        result :: Ash.Resource.record() | map(),
        context :: map()
      ) :: :ok | {:error, term()}

  ## How Syncing Works

  - `:create` / `:update` → Upserts a record into the History resource
  - `:destroy` → Deletes the record from XTDB (sets `_valid_to` to now, preserving history)

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
