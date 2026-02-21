# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer do
  @moduledoc """
  An Ash DataLayer for XTDB v2.

  This data layer communicates with XTDB via the pgwire protocol using Postgrex,
  providing full CRUD operations, relationships, aggregates, transactions,
  bitemporal queries, and attribute-based multitenancy.

  ## Features

  - **CRUD Operations**: Create, read, update, and destroy records
  - **Query Features**: Filtering, sorting, pagination, distinct, select
  - **Relationships**: JOINs for belongs_to and has_many relationships
  - **Lateral Joins**: Per-parent scoped relationship loading (via NEST_MANY/NEST_ONE)
  - **Aggregates**: count, sum, avg, min, max, exists, first, list
  - **Transactions**: Full transaction support with commit/rollback
  - **Bitemporal Queries**: Query across valid time and system time dimensions
  - **Calculations**: Expression-based calculations evaluated in Elixir
  - **Multitenancy**: Attribute-based tenant isolation
  - **Bulk Operations**: Efficient batch inserts and query-based updates

  ## DSL

  ### xtdb

  Configuration for the XTDB data layer.

  #### Options

  - `:repo` (required) - The repo module to use for database connections
  - `:table` (required) - The XTDB table name

  #### Example

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
          attribute :name, :string
          attribute :email, :string
        end

        actions do
          defaults [:read, :create, :update, :destroy]
        end
      end

  ## Telemetry

  The data layer emits telemetry events for monitoring:

  - `[:ash_xtdb, :query]` - Emitted for each query executed
  - `[:ash_xtdb, :create]` - Emitted for record creation
  - `[:ash_xtdb, :update]` - Emitted for record updates
  - `[:ash_xtdb, :destroy]` - Emitted for record deletion

  Each event includes:
  - `duration` - Query execution time in native time units
  - `result` - `:ok` or `:error`
  - `resource` - The Ash resource being operated on

  ## XTDB-Specific Considerations

  - **Primary Key**: XTDB uses `_id` for the primary key column. Ash's `id` attribute
    is automatically mapped to `_id`.
  - **Upsert Behavior**: XTDB INSERT acts as an upsert by default.
  - **No Constraints**: XTDB doesn't enforce database constraints. Use Ash validations.
  - **Schemaless**: No DDL migrations needed - tables are created automatically.
  - **Temporal Data**: Use `AshXTDB.Query` and `AshXTDB.Changeset` for bitemporal operations.

  ## Lateral Join Support

  Lateral joins enable per-parent scoped relationship loading, such as
  "first 5 posts per user" or paginated relationships with offset and limit.

  XTDB doesn't support the SQL `LATERAL` keyword, so this data layer uses
  XTDB's `NEST_MANY` and `NEST_ONE` functions for efficient single-query
  relationship loading:

      # Load first 3 posts per user (single query with NEST_MANY)
      User
      |> Ash.Query.load(posts: Ash.Query.limit(Post, 3))
      |> Ash.read!()

  This generates an efficient query like:

      SELECT t._id, t.name,
             NEST_MANY(SELECT n._id, n.title
                       FROM posts n
                       WHERE n.user_id = t._id
                       FETCH FIRST 3 ROWS ONLY) AS posts
      FROM users t

  **Note**: NEST_MANY/NEST_ONE requires XTDB v2. Aggregate queries scoped to
  relationships still use iteration (N+1 queries) as XTDB's nested functions
  don't support aggregation.

  ## Unsupported Features

  - Row locking (`FOR UPDATE`, `FOR SHARE`)
  - Context-based multitenancy (PostgreSQL schemas)
  - Database constraints (enforced at app level via Ash)
  """

  @behaviour Ash.DataLayer

  @xtdb %Spark.Dsl.Section{
    name: :xtdb,
    describe: "Configuration for the XTDB data layer",
    schema: [
      repo: [
        type: {:behaviour, AshXTDB.Repo},
        required: true,
        doc: "The repo module to use for database connections"
      ],
      table: [
        type: :string,
        required: true,
        doc: "The XTDB table name"
      ],
      valid_from_public?: [
        type: :boolean,
        default: false,
        doc: "Whether the `_valid_from` attribute should be public"
      ],
      valid_to_public?: [
        type: :boolean,
        default: false,
        doc: "Whether the `_valid_to` attribute should be public"
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@xtdb],
    transformers: [
      AshXTDB.DataLayer.Transformers.SetDefaults,
      AshXTDB.DataLayer.Transformers.AddTemporalAttributes
    ]

  require Logger
  require Ash.Query

  alias AshXTDB.DataLayer.BulkOperations
  alias AshXTDB.DataLayer.Capabilities
  alias AshXTDB.DataLayer.Errors
  alias AshXTDB.DataLayer.Info
  alias AshXTDB.DataLayer.LateralJoins
  alias AshXTDB.DataLayer.Mutations
  alias AshXTDB.DataLayer.ResultTransformer
  alias AshXTDB.DataLayer.Transactions
  alias AshXTDB.SQL

  # ============================================================================
  # Ash.DataLayer Callbacks - Capabilities
  # ============================================================================

  @impl Ash.DataLayer
  defdelegate can?(resource, capability), to: Capabilities

  @impl Ash.DataLayer
  def prefer_lateral_join_for_many_to_many?, do: false

  @impl Ash.DataLayer
  def resource_to_query(resource, domain) do
    %SQL{
      resource: resource,
      domain: domain,
      table: Info.table!(resource)
    }
  end

  @impl Ash.DataLayer
  def source(resource) do
    Info.table!(resource)
  end

  @impl Ash.DataLayer
  def set_context(_resource, query, context) do
    {:ok, %{query | context: context}}
  end

  @impl Ash.DataLayer
  def set_tenant(_resource, query, tenant) do
    {:ok, %{query | tenant: tenant}}
  end

  # ============================================================================
  # Query Operations
  # ============================================================================

  @impl Ash.DataLayer
  def run_query(query, resource, opts \\ []) do
    repo = Info.repo!(resource)
    {sql, params} = SQL.to_sql(query, :select)

    Logger.debug("AshXTDB SQL: #{sql} with params: #{inspect(params)}")

    case repo.query(sql, params, opts) do
      {:ok, %Postgrex.Result{rows: rows, columns: columns}} ->
        records_with_sql_calcs = ResultTransformer.rows_to_records(rows, columns, resource)
        add_calculations_to_records(records_with_sql_calcs, resource, query)

      {:error, error} ->
        {:error, Errors.to_ash_error(error)}
    end
  end

  defp add_calculations_to_records(records_with_sql_calcs, _resource, %{calculations: []}) do
    # No calculations requested - just extract the records
    records = Enum.map(records_with_sql_calcs, fn {record, _sql_calcs} -> record end)
    {:ok, records}
  end

  defp add_calculations_to_records(records_with_sql_calcs, resource, %{
         calculations: calculations,
         domain: domain
       }) do
    Enum.reduce_while(records_with_sql_calcs, {:ok, []}, fn {record, sql_calculations},
                                                            {:ok, acc} ->
      case evaluate_calculations_for_record(
             record,
             calculations,
             sql_calculations,
             resource,
             domain
           ) do
        {:ok, updated_record} -> {:cont, {:ok, [updated_record | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp evaluate_calculations_for_record(record, calculations, sql_calculations, resource, domain) do
    Enum.reduce_while(calculations, {:ok, record}, fn {calculation, expression}, {:ok, record} ->
      # Get the calculation key (load name or calculation name)
      calc_key = calculation.load || calculation.name

      # Check if this calculation was computed in SQL
      case Map.get(sql_calculations, calc_key) do
        nil ->
          # Not in SQL results - evaluate in Elixir
          evaluate_calculation_in_elixir(record, calculation, expression, resource, domain)

        sql_value ->
          # Use the SQL-computed value, cast to the calculation's type
          casted_value = cast_calculation_value(sql_value, calculation.type)
          updated_record = put_calculation_value(record, calculation, casted_value)
          {:cont, {:ok, updated_record}}
      end
    end)
  end

  # Cast SQL calculation result to the expected type
  defp cast_calculation_value(nil, _type), do: nil

  defp cast_calculation_value(value, type) when is_binary(value) do
    # XTDB may return numeric results as strings
    resolved_type = Ash.Type.get_type(type)

    cond do
      resolved_type in [Ash.Type.Integer, :integer] ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> value
        end

      resolved_type in [Ash.Type.Float, :float] ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> value
        end

      resolved_type in [Ash.Type.Decimal, :decimal] ->
        Decimal.new(value)

      resolved_type in [Ash.Type.Boolean, :boolean] ->
        value in ["true", "t", "1"]

      true ->
        value
    end
  end

  defp cast_calculation_value(value, _type), do: value

  defp evaluate_calculation_in_elixir(record, calculation, expression, resource, domain) do
    case Ash.Filter.hydrate_refs(expression, %{resource: resource, public?: false}) do
      {:ok, hydrated_expression} ->
        # Access context using struct field access, not Access protocol
        context = calculation.context
        actor = if is_struct(context), do: Map.get(context, :actor), else: context[:actor]
        tenant = if is_struct(context), do: Map.get(context, :tenant), else: context[:tenant]

        case Ash.Expr.eval_hydrated(hydrated_expression,
               record: record,
               resource: resource,
               domain: domain,
               actor: actor,
               tenant: tenant
             ) do
          {:ok, value} ->
            updated_record = put_calculation_value(record, calculation, value)
            {:cont, {:ok, updated_record}}

          :unknown ->
            # If we can't evaluate, set to nil
            updated_record = put_calculation_value(record, calculation, nil)
            {:cont, {:ok, updated_record}}

          {:error, error} ->
            {:halt, {:error, error}}
        end

      {:error, error} ->
        {:halt, {:error, error}}
    end
  end

  defp put_calculation_value(record, calculation, value) do
    if calculation.load do
      Map.put(record, calculation.load, value)
    else
      Map.update!(record, :calculations, &Map.put(&1, calculation.name, value))
    end
  end

  @impl Ash.DataLayer
  def filter(query, filter, _resource) do
    {:ok, %{query | filter: filter}}
  end

  @impl Ash.DataLayer
  def sort(query, sort, _resource) do
    {:ok, %{query | sort: sort}}
  end

  @impl Ash.DataLayer
  def limit(query, limit, _resource) do
    {:ok, %{query | limit: limit}}
  end

  @impl Ash.DataLayer
  def offset(query, offset, _resource) do
    {:ok, %{query | offset: offset}}
  end

  @impl Ash.DataLayer
  def select(query, select, _resource) do
    {:ok, %{query | select: select}}
  end

  @impl Ash.DataLayer
  def distinct(query, distinct, _resource) do
    {:ok, %{query | distinct: distinct}}
  end

  # ============================================================================
  # Aggregate Operations
  # ============================================================================

  @impl Ash.DataLayer
  def add_aggregate(query, aggregate, _resource) do
    {:ok, %{query | aggregates: [aggregate | query.aggregates]}}
  end

  # ============================================================================
  # Calculation Operations
  # ============================================================================

  @impl Ash.DataLayer
  def add_calculations(query, calculations, _resource) do
    {:ok, %{query | calculations: query.calculations ++ calculations}}
  end

  @impl Ash.DataLayer
  def run_aggregate_query(query, aggregates, resource) do
    repo = Info.repo!(resource)
    {sql, params} = SQL.to_aggregate_sql(query, aggregates)

    Logger.debug("AshXTDB Aggregate SQL: #{sql} with params: #{inspect(params)}")

    case repo.query(sql, params) do
      {:ok, %Postgrex.Result{rows: [row], columns: columns}} ->
        # Map column names to aggregate names and values
        result =
          columns
          |> Enum.zip(row)
          |> Enum.reduce(%{}, fn {col_name, value}, acc ->
            # Find the aggregate with this name
            agg = Enum.find(aggregates, fn a -> Atom.to_string(a.name) == col_name end)

            if agg do
              Map.put(acc, agg.name, cast_aggregate_value(value, agg))
            else
              acc
            end
          end)

        {:ok, result}

      {:ok, %Postgrex.Result{rows: []}} ->
        # No results - return defaults
        result =
          aggregates
          |> Enum.map(fn agg -> {agg.name, agg.default_value} end)
          |> Map.new()

        {:ok, result}

      {:error, error} ->
        {:error, Errors.to_ash_error(error)}
    end
  end

  # Delegate to shared implementation in ResultTransformer
  defp cast_aggregate_value(value, agg) do
    ResultTransformer.cast_aggregate_value(value, agg)
  end

  # ============================================================================
  # Lateral Join Operations (NEST_MANY/NEST_ONE)
  # ============================================================================

  @impl Ash.DataLayer
  defdelegate run_query_with_lateral_join(query, root_data, destination_resource, path),
    to: LateralJoins

  @impl Ash.DataLayer
  defdelegate run_aggregate_query_with_lateral_join(
                query,
                aggregates,
                root_data,
                destination_resource,
                path
              ),
              to: LateralJoins

  # ============================================================================
  # Mutation Operations
  # ============================================================================

  @impl Ash.DataLayer
  defdelegate create(resource, changeset), to: Mutations

  @impl Ash.DataLayer
  defdelegate update(resource, changeset), to: Mutations

  @impl Ash.DataLayer
  defdelegate destroy(resource, changeset), to: Mutations

  @impl Ash.DataLayer
  defdelegate upsert(resource, changeset, keys), to: Mutations

  # ============================================================================
  # Bulk Operations
  # ============================================================================

  @impl Ash.DataLayer
  defdelegate bulk_create(resource, stream, options), to: BulkOperations

  @impl Ash.DataLayer
  defdelegate update_query(query, changeset, resource, options), to: BulkOperations

  @impl Ash.DataLayer
  defdelegate destroy_query(query, changeset, resource, options), to: BulkOperations

  # ============================================================================
  # Transaction Support
  # ============================================================================

  @impl Ash.DataLayer
  defdelegate transaction(resource, func, timeout, reason), to: Transactions

  @impl Ash.DataLayer
  @spec rollback(Ash.Resource.t(), term()) :: no_return()
  defdelegate rollback(resource, value), to: Transactions

  @impl Ash.DataLayer
  defdelegate in_transaction?(resource), to: Transactions

  # ============================================================================
  # Telemetry
  # ============================================================================

  @doc false
  def emit_telemetry(event, metadata, func) do
    start_time = System.monotonic_time()

    try do
      result = func.()

      :telemetry.execute(
        [:ash_xtdb, event],
        %{duration: System.monotonic_time() - start_time},
        Map.put(metadata, :result, :ok)
      )

      result
    rescue
      e ->
        :telemetry.execute(
          [:ash_xtdb, event],
          %{duration: System.monotonic_time() - start_time},
          Map.put(metadata, :result, :error)
        )

        reraise e, __STACKTRACE__
    end
  end
end
