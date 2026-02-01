# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB do
  @moduledoc """
  An Ash DataLayer for XTDB v2 with first-class bitemporal query support.

  AshXTDB provides a direct Ash data layer implementation for XTDB, enabling
  Ash resources to use XTDB as their persistence layer. It communicates with
  XTDB via the pgwire protocol using Postgrex.

  ## Key Features

  - **CRUD Operations**: Create, read, update, destroy with full Ash integration
  - **Query Features**: Filtering, sorting, pagination (offset & keyset), distinct, select
  - **Relationships**: JOINs for belongs_to and has_many relationships
  - **Aggregates**: count, sum, avg, min, max, exists, first, list
  - **Transactions**: Full transaction support with commit/rollback
  - **Bitemporal Queries**: Query across valid time and system time dimensions
  - **Calculations**: Expression-based calculations
  - **Multitenancy**: Attribute-based tenant isolation
  - **Bulk Operations**: Efficient batch inserts and query-based updates
  - **GDPR Compliance**: ERASE operations to permanently remove data from all history

  ## Quick Start

      # 1. Define a Repo
      defmodule MyApp.XTDBRepo do
        use AshXTDB.Repo, otp_app: :my_app
      end

      # 2. Configure connection (config/config.exs)
      config :my_app, MyApp.XTDBRepo,
        hostname: "localhost",
        port: 5432,
        database: "xtdb"

      # 3. Define a Resource
      defmodule MyApp.User do
        use Ash.Resource,
          domain: MyApp.Domain,
          data_layer: AshXTDB.DataLayer

        xtdb do
          repo MyApp.XTDBRepo
          table "users"
        end

        attributes do
          uuid_primary_key :id
          attribute :email, :string, allow_nil?: false
          attribute :name, :string
        end

        actions do
          defaults [:read, :create, :update, :destroy]
        end
      end

      # 4. Use with Ash
      User
      |> Ash.Changeset.for_create(:create, %{email: "user@example.com", name: "Alice"})
      |> Ash.create!()

  ## Bitemporal Queries

  XTDB's unique bitemporal capabilities are exposed via `AshXTDB.Temporal`:

      # Query data as it was at a specific point in time
      User
      |> AshXTDB.Temporal.as_of_valid_time(~U[2024-01-01 00:00:00Z])
      |> Ash.read!()

      # Query the full history
      User
      |> AshXTDB.Temporal.for_all_valid_time()
      |> Ash.read!()

      # GDPR: Permanently erase a record from all history
      AshXTDB.Temporal.erase!(user)

  ## XTDB-Specific Considerations

  - **Primary Key**: XTDB requires an `_id` column. Ash primary keys are automatically mapped.
  - **INSERT behavior**: XTDB INSERT acts as upsert by default.
  - **UPDATE**: The `_id` column cannot be updated.
  - **Schemaless**: No DDL migrations needed - XTDB is schemaless.
  - **Transactions**: Mid-transaction writes are not visible to reads.
  - **No Constraints**: Database constraints aren't enforced. Use Ash validations.
  """

  @doc """
  Returns the configured repo for a resource.
  """
  @spec repo(Ash.Resource.t()) :: module()
  def repo(resource) do
    AshXTDB.DataLayer.Info.repo!(resource)
  end

  @doc """
  Returns the configured table name for a resource.
  """
  @spec table(Ash.Resource.t()) :: String.t()
  def table(resource) do
    AshXTDB.DataLayer.Info.table!(resource)
  end
end
