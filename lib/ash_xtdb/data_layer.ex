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
  - **Temporal Data**: Use `AshXTDB.Temporal` for bitemporal queries.

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
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@xtdb],
    transformers: [AshXTDB.DataLayer.Transformers.SetDefaults]

  require Logger
  require Ash.Query

  alias AshXTDB.DataLayer.Info
  alias AshXTDB.NestedResult
  alias AshXTDB.Query

  # ============================================================================
  # Ash.DataLayer Callbacks
  # ============================================================================

  @impl Ash.DataLayer
  def can?(resource, capability) do
    do_can?(resource, capability)
  end

  # Phase 1: Basic CRUD
  defp do_can?(_, :create), do: true
  defp do_can?(_, :read), do: true
  defp do_can?(_, :update), do: true
  defp do_can?(_, :destroy), do: true

  # Phase 2: Query features
  defp do_can?(_, :filter), do: true
  defp do_can?(_, :sort), do: true
  defp do_can?(_, :limit), do: true
  defp do_can?(_, :offset), do: true
  defp do_can?(_, :select), do: true
  defp do_can?(_, :distinct), do: true
  defp do_can?(_, :boolean_filter), do: true
  defp do_can?(_, :nested_expressions), do: true

  # Filter expressions
  defp do_can?(_, {:filter_expr, _}), do: true

  # Sort on attribute
  defp do_can?(_, {:sort, _}), do: true

  # XTDB INSERT is naturally upsert
  defp do_can?(_, :upsert), do: true

  # Async engine support
  defp do_can?(_, :async_engine), do: true

  # Phase 3: Relationships - allow joins to other XTDB resources
  defp do_can?(_, {:join, resource}) do
    Ash.Resource.Info.data_layer(resource) == __MODULE__
  end

  defp do_can?(_, {:filter_relationship, _}), do: true

  # Phase 4: Aggregates
  defp do_can?(_, {:aggregate, :count}), do: true
  defp do_can?(_, {:aggregate, :sum}), do: true
  defp do_can?(_, {:aggregate, :avg}), do: true
  defp do_can?(_, {:aggregate, :min}), do: true
  defp do_can?(_, {:aggregate, :max}), do: true
  defp do_can?(_, {:aggregate, :exists}), do: true
  defp do_can?(_, {:aggregate, :first}), do: true
  defp do_can?(_, {:aggregate, :list}), do: true
  # Statistical aggregates
  defp do_can?(_, {:aggregate, :stddev_pop}), do: true
  defp do_can?(_, {:aggregate, :stddev_samp}), do: true
  defp do_can?(_, {:aggregate, :var_pop}), do: true
  defp do_can?(_, {:aggregate, :var_samp}), do: true
  # Boolean aggregates
  defp do_can?(_, {:aggregate, :bool_and}), do: true
  defp do_can?(_, {:aggregate, :bool_or}), do: true

  defp do_can?(_, {:query_aggregate, :count}), do: true
  defp do_can?(_, {:query_aggregate, :sum}), do: true
  defp do_can?(_, {:query_aggregate, :avg}), do: true
  defp do_can?(_, {:query_aggregate, :min}), do: true
  defp do_can?(_, {:query_aggregate, :max}), do: true
  defp do_can?(_, {:query_aggregate, :exists}), do: true
  defp do_can?(_, {:query_aggregate, :first}), do: true
  defp do_can?(_, {:query_aggregate, :list}), do: true
  # Statistical query aggregates
  defp do_can?(_, {:query_aggregate, :stddev_pop}), do: true
  defp do_can?(_, {:query_aggregate, :stddev_samp}), do: true
  defp do_can?(_, {:query_aggregate, :var_pop}), do: true
  defp do_can?(_, {:query_aggregate, :var_samp}), do: true
  # Boolean query aggregates
  defp do_can?(_, {:query_aggregate, :bool_and}), do: true
  defp do_can?(_, {:query_aggregate, :bool_or}), do: true

  # Phase 5: Transactions
  defp do_can?(_, :transact), do: true

  # Phase 7: Bulk Operations
  defp do_can?(_, :bulk_create), do: true
  defp do_can?(_, :update_query), do: true
  defp do_can?(_, :destroy_query), do: true

  # Phase 9: Calculations
  defp do_can?(_, :expression_calculation), do: true

  # Phase 10: Multitenancy (attribute-based only)
  defp do_can?(_, :multitenancy), do: true
  defp do_can?(_, {:multitenancy, :attribute}), do: true
  defp do_can?(_, :changeset_filter), do: true
  # Context-based multitenancy (schemas) not supported - XTDB has no schemas
  defp do_can?(_, {:multitenancy, :context}), do: false

  # Lateral joins - supported via iteration when all resources use XTDB
  defp do_can?(_resource, {:lateral_join, resources}) do
    Enum.all?(resources, fn res ->
      Ash.Resource.Info.data_layer(res) == __MODULE__
    end)
  end

  # Not supported (XTDB limitations)
  defp do_can?(_, {:lock, _}), do: false

  # Default: not supported
  defp do_can?(_, _), do: false

  @impl Ash.DataLayer
  def prefer_lateral_join_for_many_to_many?, do: false

  @impl Ash.DataLayer
  def resource_to_query(resource, domain) do
    %Query{
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
    {sql, params} = Query.to_sql(query, :select)

    Logger.debug("AshXTDB SQL: #{sql} with params: #{inspect(params)}")

    case repo.query(sql, params, opts) do
      {:ok, %Postgrex.Result{rows: rows, columns: columns}} ->
        records = rows_to_records(rows, columns, resource)
        add_calculations_to_records(records, resource, query)

      {:error, error} ->
        {:error, to_ash_error(error)}
    end
  end

  defp add_calculations_to_records(records, _resource, %{calculations: []}),
    do: {:ok, records}

  defp add_calculations_to_records(records, resource, %{
         calculations: calculations,
         domain: domain
       }) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case evaluate_calculations_for_record(record, calculations, resource, domain) do
        {:ok, updated_record} -> {:cont, {:ok, [updated_record | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp evaluate_calculations_for_record(record, calculations, resource, domain) do
    Enum.reduce_while(calculations, {:ok, record}, fn {calculation, expression}, {:ok, record} ->
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
    end)
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
    {sql, params} = Query.to_aggregate_sql(query, aggregates)

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
        {:error, to_ash_error(error)}
    end
  end

  defp cast_aggregate_value(nil, _agg), do: nil

  defp cast_aggregate_value(value, %{kind: :count}) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp cast_aggregate_value(value, %{kind: kind}) when kind in [:sum, :min, :max] do
    cond do
      is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} ->
            int

          _ ->
            case Float.parse(value) do
              {float, ""} -> float
              _ -> value
            end
        end

      true ->
        value
    end
  end

  defp cast_aggregate_value(value, %{kind: :avg}) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> value
    end
  end

  defp cast_aggregate_value(value, %{kind: :exists}) do
    case value do
      "t" -> true
      "f" -> false
      "true" -> true
      "false" -> false
      true -> true
      false -> false
      1 -> true
      0 -> false
      "1" -> true
      "0" -> false
      nil -> false
      _ -> !!value
    end
  end

  # Statistical aggregates return floats
  defp cast_aggregate_value(value, %{kind: kind})
       when kind in [:stddev_pop, :stddev_samp, :var_pop, :var_samp] do
    cond do
      is_nil(value) -> nil
      is_float(value) -> value
      is_integer(value) -> value * 1.0
      is_binary(value) ->
        case Float.parse(value) do
          {float, _} -> float
          :error -> value
        end
      true -> value
    end
  end

  # Boolean aggregates
  defp cast_aggregate_value(value, %{kind: kind}) when kind in [:bool_and, :bool_or] do
    case value do
      "t" -> true
      "f" -> false
      "true" -> true
      "false" -> false
      true -> true
      false -> false
      1 -> true
      0 -> false
      "1" -> true
      "0" -> false
      nil -> nil
      _ -> !!value
    end
  end

  defp cast_aggregate_value(value, _agg), do: value

  # ============================================================================
  # Lateral Join Operations (NEST_MANY/NEST_ONE)
  # ============================================================================

  @doc """
  Run a query with lateral join semantics using XTDB's NEST_MANY/NEST_ONE.

  XTDB doesn't support the SQL LATERAL keyword, so we use NEST_MANY/NEST_ONE
  correlated subqueries which return nested JSON structures. This provides
  efficient single-query loading of relationships with limits, offsets, and
  filters scoped to each parent.
  """
  @impl Ash.DataLayer
  # Simple relationship (1 join link) - e.g., has_many, belongs_to
  def run_query_with_lateral_join(
        query,
        root_data,
        destination_resource,
        [{_source_query, _source_attribute, _destination_attribute, _relationship}] = path
      ) do
    run_nested_lateral_join(query, root_data, destination_resource, path)
  end

  # Many-to-many relationship (2 join links) - e.g., through join table
  def run_query_with_lateral_join(
        query,
        root_data,
        destination_resource,
        [
          {_source_query, _source_attribute, _source_attr_on_join, _relationship},
          {_through_query, _dest_attr_on_join, _destination_attribute, _through_relationship}
        ] = path
      ) do
    run_nested_many_to_many_lateral_join(query, root_data, destination_resource, path)
  end

  # ============================================================================
  # NEST_MANY/NEST_ONE Implementation
  # ============================================================================

  defp run_nested_lateral_join(
         query,
         root_data,
         destination_resource,
         [{source_query, source_attribute, destination_attribute, relationship}]
       ) do
    source_resource = source_query.resource
    repo = Info.repo!(source_resource)
    source_table = Info.table!(source_resource)
    dest_table = Info.table!(destination_resource)
    pkey_attrs = Ash.Resource.Info.primary_key(source_resource)

    # Determine nest type based on relationship
    nest_type =
      case relationship.cardinality do
        :one -> :nest_one
        :many -> :nest_many
      end

    # Build nested subquery configuration
    nested_config = %{
      name: relationship.name,
      type: nest_type,
      resource: destination_resource,
      table: dest_table,
      correlation: {source_attribute, destination_attribute},
      select: query.select,
      filter: query.filter,
      sort: query.sort,
      limit: query.limit,
      offset: query.offset
    }

    # Build filter for parent records
    pkey_values = Enum.map(root_data, fn record -> Map.take(record, pkey_attrs) end)

    parent_filter =
      case pkey_attrs do
        [pkey] ->
          values = Enum.map(pkey_values, &Map.get(&1, pkey))
          Ash.Filter.parse!(source_resource, [{pkey, [in: values]}])

        _ ->
          # Composite primary key
          conditions = Enum.map(pkey_values, &Map.to_list/1)
          Ash.Filter.parse!(source_resource, [or: conditions])
      end

    # Build query with nested subquery
    parent_query = %Query{
      resource: source_resource,
      domain: query.domain,
      table: source_table,
      filter: parent_filter,
      context: query.context,
      nested_subqueries: [nested_config]
    }

    {sql, params} = Query.to_sql(parent_query, :select)

    Logger.debug("AshXTDB NEST_#{String.upcase(to_string(nest_type))} SQL: #{sql}")

    case repo.query(sql, params) do
      {:ok, %Postgrex.Result{rows: rows, columns: columns}} ->
        # Transform nested results
        parent_records = NestedResult.transform_rows(rows, columns, [nested_config])

        # Map _id to primary key for parent records (so extract_nested can find pkey)
        parent_records =
          Enum.map(parent_records, fn record ->
            map_id_to_primary_key(record, source_resource)
          end)

        # Extract nested records with __lateral_join_source__
        nested_records =
          NestedResult.extract_nested(
            parent_records,
            relationship.name,
            destination_resource,
            source_resource
          )

        {:ok, nested_records}

      {:error, error} ->
        {:error, to_ash_error(error)}
    end
  end

  defp run_nested_many_to_many_lateral_join(
         query,
         root_data,
         destination_resource,
         [
           {source_query, source_attribute, source_attr_on_join, relationship},
           {through_query, dest_attr_on_join, destination_attribute, _through_relationship}
         ]
       ) do
    source_resource = source_query.resource
    through_resource = through_query.resource
    repo = Info.repo!(source_resource)
    source_table = Info.table!(source_resource)
    through_table = Info.table!(through_resource)
    dest_table = Info.table!(destination_resource)
    pkey_attrs = Ash.Resource.Info.primary_key(source_resource)

    # For many-to-many, we use a subquery in the WHERE clause:
    # NEST_MANY(SELECT ... FROM dest WHERE dest.id IN
    #           (SELECT through.dest_id FROM through WHERE through.source_id = parent.id))
    nested_config = %{
      name: relationship.name,
      type: :nest_many,
      resource: destination_resource,
      table: dest_table,
      # For many-to-many, correlation is done via through table subquery
      correlation: {:through_subquery, %{
        through_table: through_table,
        source_attr_on_join: source_attr_on_join,
        dest_attr_on_join: dest_attr_on_join,
        destination_attribute: destination_attribute,
        source_attribute: source_attribute
      }},
      select: query.select,
      filter: query.filter,
      sort: query.sort,
      limit: query.limit,
      offset: query.offset
    }

    # Build filter for parent records
    pkey_values = Enum.map(root_data, fn record -> Map.take(record, pkey_attrs) end)

    parent_filter =
      case pkey_attrs do
        [pkey] ->
          values = Enum.map(pkey_values, &Map.get(&1, pkey))
          Ash.Filter.parse!(source_resource, [{pkey, [in: values]}])

        _ ->
          conditions = Enum.map(pkey_values, &Map.to_list/1)
          Ash.Filter.parse!(source_resource, [or: conditions])
      end

    # Build query with nested subquery
    parent_query = %Query{
      resource: source_resource,
      domain: query.domain,
      table: source_table,
      filter: parent_filter,
      context: query.context,
      nested_subqueries: [nested_config]
    }

    {sql, params} = Query.to_sql(parent_query, :select)

    Logger.debug("AshXTDB NEST_MANY (M2M) SQL: #{sql}")

    case repo.query(sql, params) do
      {:ok, %Postgrex.Result{rows: rows, columns: columns}} ->
        parent_records = NestedResult.transform_rows(rows, columns, [nested_config])

        # Map _id to primary key for parent records (so extract_nested can find pkey)
        parent_records =
          Enum.map(parent_records, fn record ->
            map_id_to_primary_key(record, source_resource)
          end)

        nested_records =
          NestedResult.extract_nested(
            parent_records,
            relationship.name,
            destination_resource,
            source_resource
          )

        {:ok, nested_records}

      {:error, error} ->
        {:error, to_ash_error(error)}
    end
  end

  # ============================================================================
  # Aggregate Lateral Join (uses iteration since NEST_MANY doesn't support aggregates)
  # ============================================================================

  defp prepare_lateral_source_query(source_query, domain) do
    source_query =
      source_query
      |> Ash.Query.unset(:load)
      |> Ash.Query.unset(:page)
      |> Ash.Query.set_context(%{private: %{internal?: true}})
      |> Ash.Query.set_domain(domain)

    {:ok, source_query}
  end

  defp filter_parents_by_root_data(source_query, root_data, source_attribute) do
    pkey_attrs = Ash.Resource.Info.primary_key(source_query.resource)

    if Enum.empty?(root_data) do
      {:ok, []}
    else
      source_query =
        case pkey_attrs do
          [] ->
            source_values = Enum.map(root_data, &Map.get(&1, source_attribute))
            Ash.Query.filter(source_query, ^Ash.Expr.ref(source_attribute) in ^source_values)

          [field] ->
            pkey_values = Enum.map(root_data, &Map.get(&1, field))
            Ash.Query.filter(source_query, ^Ash.Expr.ref(field) in ^pkey_values)

          fields ->
            filter = [
              or:
                Enum.map(root_data, fn record ->
                  [and: Map.take(record, fields) |> Map.to_list()]
                end)
            ]

            Ash.Query.do_filter(source_query, filter)
        end

      Ash.read(source_query, authorize?: false)
    end
  end

  @doc """
  Run an aggregate query with lateral join semantics.

  Computes aggregates scoped to each parent record's relationship.
  """
  @impl Ash.DataLayer
  def run_aggregate_query_with_lateral_join(
        query,
        aggregates,
        root_data,
        _destination_resource,
        [
          {source_query, source_attribute, destination_attribute, _relationship}
        ]
      ) do
    with {:ok, source_query} <- prepare_lateral_source_query(source_query, query.domain),
         {:ok, filtered_parents} <-
           filter_parents_by_root_data(source_query, root_data, source_attribute) do
      run_simple_lateral_aggregate(
        query,
        aggregates,
        filtered_parents,
        source_attribute,
        destination_attribute
      )
    end
  end

  def run_aggregate_query_with_lateral_join(
        query,
        aggregates,
        root_data,
        _destination_resource,
        [
          {source_query, source_attribute, source_attr_on_join, _relationship},
          {through_query, dest_attr_on_join, destination_attribute, _through_relationship}
        ]
      ) do
    with {:ok, source_query} <- prepare_lateral_source_query(source_query, query.domain),
         {:ok, through_query} <- prepare_lateral_source_query(through_query, query.domain),
         {:ok, filtered_parents} <-
           filter_parents_by_root_data(source_query, root_data, source_attribute) do
      run_many_to_many_lateral_aggregate(
        query,
        aggregates,
        filtered_parents,
        through_query,
        source_attribute,
        source_attr_on_join,
        dest_attr_on_join,
        destination_attribute
      )
    end
  end

  defp run_simple_lateral_aggregate(
         query,
         aggregates,
         parents,
         source_attribute,
         destination_attribute
       ) do
    destination_resource = query.resource

    Enum.reduce_while(parents, {:ok, []}, fn parent, {:ok, results} ->
      correlation_value = Map.get(parent, source_attribute)
      source_pkey = Ash.Resource.Info.primary_key(parent.__struct__)

      if is_nil(correlation_value) do
        # Return defaults for nil correlation
        default_result =
          aggregates
          |> Enum.map(fn agg -> {agg.name, agg.default_value} end)
          |> Map.new()
          |> Map.put(:__lateral_join_source__, Map.take(parent, source_pkey))

        {:cont, {:ok, [default_result | results]}}
      else
        correlated_filter =
          Ash.Filter.parse!(destination_resource, [{destination_attribute, correlation_value}])

        merged_filter =
          if query.filter do
            Ash.Filter.add_to_filter!(query.filter, correlated_filter)
          else
            correlated_filter
          end

        correlated_query = %{query | filter: merged_filter}

        case run_aggregate_query(correlated_query, aggregates, destination_resource) do
          {:ok, agg_result} ->
            tagged_result =
              Map.put(agg_result, :__lateral_join_source__, Map.take(parent, source_pkey))

            {:cont, {:ok, [tagged_result | results]}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end
    end)
  end

  defp run_many_to_many_lateral_aggregate(
         query,
         aggregates,
         parents,
         through_query,
         source_attribute,
         source_attr_on_join,
         dest_attr_on_join,
         destination_attribute
       ) do
    destination_resource = query.resource

    Enum.reduce_while(parents, {:ok, []}, fn parent, {:ok, results} ->
      correlation_value = Map.get(parent, source_attribute)
      source_pkey = Ash.Resource.Info.primary_key(parent.__struct__)

      if is_nil(correlation_value) do
        default_result =
          aggregates
          |> Enum.map(fn agg -> {agg.name, agg.default_value} end)
          |> Map.new()
          |> Map.put(:__lateral_join_source__, Map.take(parent, source_pkey))

        {:cont, {:ok, [default_result | results]}}
      else
        through_query_filtered =
          Ash.Query.filter(
            through_query,
            ^Ash.Expr.ref(source_attr_on_join) == ^correlation_value
          )

        case Ash.read(through_query_filtered, authorize?: false) do
          {:ok, join_records} ->
            if Enum.empty?(join_records) do
              default_result =
                aggregates
                |> Enum.map(fn agg -> {agg.name, agg.default_value} end)
                |> Map.new()
                |> Map.put(:__lateral_join_source__, Map.take(parent, source_pkey))

              {:cont, {:ok, [default_result | results]}}
            else
              dest_attr_values =
                join_records
                |> Enum.map(&Map.get(&1, dest_attr_on_join))
                |> Enum.reject(&is_nil/1)
                |> Enum.uniq()

              if Enum.empty?(dest_attr_values) do
                default_result =
                  aggregates
                  |> Enum.map(fn agg -> {agg.name, agg.default_value} end)
                  |> Map.new()
                  |> Map.put(:__lateral_join_source__, Map.take(parent, source_pkey))

                {:cont, {:ok, [default_result | results]}}
              else
                dest_filter =
                  Ash.Filter.parse!(destination_resource, [
                    {destination_attribute, [in: dest_attr_values]}
                  ])

                merged_filter =
                  if query.filter do
                    Ash.Filter.add_to_filter!(query.filter, dest_filter)
                  else
                    dest_filter
                  end

                correlated_query = %{query | filter: merged_filter}

                case run_aggregate_query(correlated_query, aggregates, destination_resource) do
                  {:ok, agg_result} ->
                    tagged_result =
                      Map.put(agg_result, :__lateral_join_source__, Map.take(parent, source_pkey))

                    {:cont, {:ok, [tagged_result | results]}}

                  {:error, error} ->
                    {:halt, {:error, error}}
                end
              end
            end

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end
    end)
  end

  # ============================================================================
  # Mutation Operations
  # ============================================================================

  @impl Ash.DataLayer
  def create(resource, changeset) do
    repo = Info.repo!(resource)
    table = Info.table!(resource)

    # Build record from changeset attributes
    record = build_record_from_changeset(changeset, resource)
    {sql, params} = Query.build_insert(table, record, resource)

    Logger.debug("AshXTDB INSERT: #{sql} with params: #{inspect(params)}")

    case repo.query(sql, params) do
      {:ok, _result} ->
        # Map _id back to the primary key attribute for the struct
        result_attrs = map_id_to_primary_key(record, resource)
        {:ok, struct(resource, result_attrs)}

      {:error, error} ->
        {:error, to_ash_error(error)}
    end
  end

  @impl Ash.DataLayer
  def update(resource, changeset) do
    repo = Info.repo!(resource)
    table = Info.table!(resource)

    # Get the primary key value(s) for WHERE clause
    pkey = primary_key_value(changeset.data, resource)

    # Get changed attributes
    changes = get_changes(changeset)

    if map_size(changes) == 0 do
      # No changes, return existing record
      {:ok, changeset.data}
    else
      {sql, params} = Query.build_update(table, pkey, changes, resource)

      Logger.debug("AshXTDB UPDATE: #{sql} with params: #{inspect(params)}")

      case repo.query(sql, params) do
        {:ok, _result} ->
          updated = Map.merge(changeset.data, changes)
          {:ok, updated}

        {:error, error} ->
          {:error, to_ash_error(error)}
      end
    end
  end

  @impl Ash.DataLayer
  def destroy(resource, changeset) do
    repo = Info.repo!(resource)
    table = Info.table!(resource)

    pkey = primary_key_value(changeset.data, resource)
    {sql, params} = Query.build_delete(table, pkey, resource)

    Logger.debug("AshXTDB DELETE: #{sql} with params: #{inspect(params)}")

    case repo.query(sql, params) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        {:error, to_ash_error(error)}
    end
  end

  # ============================================================================
  # Upsert
  # ============================================================================

  @impl Ash.DataLayer
  def upsert(resource, changeset, _keys) do
    # XTDB INSERT is naturally an upsert based on _id
    create(resource, changeset)
  end

  # ============================================================================
  # Bulk Operations
  # ============================================================================

  @impl Ash.DataLayer
  def bulk_create(resource, stream, options) do
    repo = Info.repo!(resource)
    table = Info.table!(resource)
    options = options || %{}
    return_records? = Map.get(options, :return_records?, false)

    # Convert stream to list and apply attributes to get full records
    changesets = Enum.to_list(stream)

    # Get attribute names (not relationships)
    attr_names = resource |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

    records_with_changesets =
      changesets
      |> Enum.reduce_while({:ok, []}, fn changeset, {:ok, acc} ->
        case Ash.Changeset.apply_attributes(changeset) do
          {:ok, record} ->
            # Convert struct to map, keeping only attributes (not relationships)
            record_map =
              record
              |> Map.from_struct()
              |> Map.take(attr_names)
              |> Enum.reject(fn {_k, v} -> is_nil(v) end)
              |> Map.new()
              |> map_primary_key_to_id(resource)

            {:cont, {:ok, [{record_map, changeset} | acc]}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end)

    case records_with_changesets do
      {:error, error} ->
        {:error, error}

      {:ok, []} ->
        if return_records?, do: {:ok, []}, else: :ok

      {:ok, records_with_changesets} ->
        # Reverse to maintain order
        records_with_changesets = Enum.reverse(records_with_changesets)
        records = Enum.map(records_with_changesets, fn {record, _} -> record end)

        # Build batch INSERT SQL
        {sql, params} = Query.build_bulk_insert(table, records, resource)

        Logger.debug("AshXTDB BULK INSERT: #{sql} with params: #{inspect(params)}")

        # XTDB requires inlined params for inserts
        inlined_sql = AshXTDB.Query.inline_params(sql, params)

        case repo.query(inlined_sql, []) do
          {:ok, _result} ->
            if return_records? do
              # Map records back to structs with bulk metadata
              result_records =
                Enum.map(records_with_changesets, fn {record, changeset} ->
                  attrs = map_id_to_primary_key(record, resource)
                  result = struct(resource, attrs)
                  # Add bulk operation metadata from changeset context
                  Ash.Actions.Helpers.Bulk.put_metadata(result, changeset)
                end)

              {:ok, result_records}
            else
              :ok
            end

          {:error, error} ->
            {:error, to_ash_error(error)}
        end
    end
  end

  @impl Ash.DataLayer
  def update_query(query, changeset, resource, options) do
    repo = Info.repo!(resource)
    table = Info.table!(resource)
    return_records? = Map.get(options, :return_records?, false)

    # Get the changes from changeset
    changes = get_changes(changeset)

    if map_size(changes) == 0 do
      if return_records?, do: {:ok, []}, else: :ok
    else
      # Build UPDATE with WHERE from filter
      {sql, params} = Query.build_update_query(table, changes, query, resource)

      Logger.debug("AshXTDB UPDATE QUERY: #{sql} with params: #{inspect(params)}")

      # Inline params for XTDB
      inlined_sql = AshXTDB.Query.inline_params(sql, params)

      case repo.query(inlined_sql, []) do
        {:ok, _result} ->
          # XTDB doesn't allow SELECT in DML transactions, so we can't return
          # the actual updated records. Return empty list when return_records? is true.
          # Ash will re-fetch if needed.
          if return_records? do
            {:ok, []}
          else
            :ok
          end

        {:error, error} ->
          {:error, to_ash_error(error)}
      end
    end
  end

  @impl Ash.DataLayer
  def destroy_query(query, _changeset, resource, options) do
    repo = Info.repo!(resource)
    table = Info.table!(resource)
    return_records? = Map.get(options, :return_records?, false)

    # Build DELETE with WHERE from filter
    {sql, params} = Query.build_destroy_query(table, query, resource)

    Logger.debug("AshXTDB DESTROY QUERY: #{sql} with params: #{inspect(params)}")

    # Inline params for XTDB
    inlined_sql = AshXTDB.Query.inline_params(sql, params)

    case repo.query(inlined_sql, []) do
      {:ok, _result} ->
        # XTDB doesn't allow SELECT in DML transactions, so we can't return
        # the actual destroyed records. Return empty list when return_records? is true.
        if return_records? do
          {:ok, []}
        else
          :ok
        end

      {:error, error} ->
        {:error, to_ash_error(error)}
    end
  end

  # ============================================================================
  # Transaction Support
  # ============================================================================

  @transaction_key :ash_xtdb_in_transaction

  @impl Ash.DataLayer
  def transaction(resource, func, _timeout, _reason) do
    repo = Info.repo!(resource)

    if in_transaction?(resource) do
      # Already in a transaction, just run the function
      {:ok, func.()}
    else
      # Start a new transaction - XTDB requires explicit READ WRITE for DML
      case repo.query("START TRANSACTION READ WRITE", []) do
        {:ok, _} ->
          Process.put(@transaction_key, true)

          try do
            result = func.()

            case repo.query("COMMIT", []) do
              {:ok, _} ->
                {:ok, result}

              {:error, error} ->
                {:error, to_ash_error(error)}
            end
          rescue
            e ->
              repo.query("ROLLBACK", [])
              {:error, Ash.Error.to_ash_error(e, __STACKTRACE__)}
          catch
            :throw, {:ash_rollback, value} ->
              repo.query("ROLLBACK", [])
              {:error, value}

            kind, value ->
              repo.query("ROLLBACK", [])
              {:error, Ash.Error.to_ash_error({kind, value})}
          after
            Process.delete(@transaction_key)
          end

        {:error, error} ->
          {:error, to_ash_error(error)}
      end
    end
  end

  @impl Ash.DataLayer
  def rollback(resource, value) do
    repo = Info.repo!(resource)

    case repo.query("ROLLBACK", []) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end

    Process.delete(@transaction_key)
    throw({:ash_rollback, value})
  end

  @impl Ash.DataLayer
  def in_transaction?(_resource) do
    Process.get(@transaction_key, false)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp rows_to_records(rows, columns, resource) do
    # Use String.to_atom since XTDB may return synthetic column names
    columns = Enum.map(columns, &String.to_atom/1)

    # Get attribute info for type casting
    attr_types = get_attribute_types(resource)

    Enum.map(rows, fn row ->
      attrs =
        columns
        |> Enum.zip(row)
        |> Enum.map(fn {col, val} -> {col, cast_value(val, Map.get(attr_types, col))} end)
        |> Map.new()

      # Map _id back to the primary key attribute
      attrs = map_id_to_primary_key(attrs, resource)

      struct(resource, attrs)
    end)
  end

  defp get_attribute_types(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(fn attr -> {attr.name, attr.type} end)
    |> Map.new()
    |> Map.put(:_id, :string)
  end

  defp cast_value(nil, _type), do: nil
  defp cast_value(value, nil), do: value

  defp cast_value(value, type) when is_binary(value) do
    case type do
      Ash.Type.Integer ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> value
        end

      Ash.Type.Float ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> value
        end

      Ash.Type.Boolean ->
        case value do
          "true" -> true
          "t" -> true
          "false" -> false
          "f" -> false
          _ -> value
        end

      _ ->
        value
    end
  end

  defp cast_value(value, _type), do: value

  defp map_id_to_primary_key(attrs, resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [pkey] when pkey != :_id ->
        case Map.pop(attrs, :_id) do
          {nil, attrs} -> attrs
          {id_value, attrs} -> Map.put(attrs, pkey, id_value)
        end

      _ ->
        attrs
    end
  end

  defp build_record_from_changeset(changeset, resource) do
    # Get all attributes that have values
    # Use attributes map which contains all attribute values including defaults and primary key
    attrs =
      if is_map(changeset.attributes) and map_size(changeset.attributes) > 0 do
        changeset.attributes
      else
        # Fallback: extract attributes from the changeset using Ash API
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.reduce(%{}, fn attr, acc ->
          case Ash.Changeset.get_attribute(changeset, attr.name) do
            nil -> acc
            value -> Map.put(acc, attr.name, value)
          end
        end)
      end

    attrs = Map.new(attrs)

    # Map primary key to _id for XTDB
    map_primary_key_to_id(attrs, resource)
  end

  defp map_primary_key_to_id(attrs, resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [pkey] when pkey != :_id ->
        case Map.pop(attrs, pkey) do
          {nil, attrs} -> attrs
          {pkey_value, attrs} -> Map.put(attrs, :_id, pkey_value)
        end

      _ ->
        attrs
    end
  end

  defp primary_key_value(record, resource) do
    pkey_attrs = Ash.Resource.Info.primary_key(resource)

    Map.new(pkey_attrs, fn attr ->
      {attr, Map.get(record, attr)}
    end)
  end

  defp get_changes(changeset) do
    changeset.attributes
    |> Map.new()
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  defp to_ash_error(%Postgrex.Error{postgres: %{code: code, message: message}} = error) do
    case code do
      # Connection errors
      "08000" ->
        Ash.Error.Unknown.exception(
          error: "XTDB connection error: #{message}",
          error_context: error
        )

      "08003" ->
        Ash.Error.Unknown.exception(
          error: "XTDB connection does not exist: #{message}",
          error_context: error
        )

      # Syntax errors
      "42601" ->
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Query.InvalidQuery.exception(
              query: nil,
              message: "SQL syntax error: #{message}"
            )
          ]
        )

      # Undefined table
      "42P01" ->
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Query.InvalidQuery.exception(
              query: nil,
              message: "Table does not exist: #{message}"
            )
          ]
        )

      # Undefined column
      "42703" ->
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Query.InvalidQuery.exception(
              query: nil,
              message: "Column does not exist: #{message}"
            )
          ]
        )

      # Data type mismatch
      "42804" ->
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Query.InvalidQuery.exception(
              query: nil,
              message: "Data type mismatch: #{message}"
            )
          ]
        )

      # Default: convert to Ash error
      _ ->
        Ash.Error.to_ash_error(error)
    end
  end

  defp to_ash_error(%Postgrex.Error{} = error) do
    Ash.Error.to_ash_error(error)
  end

  defp to_ash_error(%DBConnection.ConnectionError{message: message}) do
    Ash.Error.Unknown.exception(error: "Database connection error: #{message}")
  end

  defp to_ash_error(error) when is_exception(error) do
    Ash.Error.to_ash_error(error)
  end

  defp to_ash_error(error) do
    Ash.Error.Unknown.exception(error: error)
  end

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
