# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.LateralJoins do
  @moduledoc """
  Lateral join operations for the XTDB data layer.

  Implements lateral join semantics using XTDB's NEST_MANY/NEST_ONE functions.
  These provide efficient single-query loading of relationships with limits,
  offsets, and filters scoped to each parent.

  ## XTDB Implementation

  XTDB doesn't support the SQL LATERAL keyword, so we use NEST_MANY/NEST_ONE
  correlated subqueries which return nested JSON structures:

      SELECT t._id, t.name,
             NEST_MANY(SELECT n._id, n.title
                       FROM posts n
                       WHERE n.user_id = t._id
                       FETCH FIRST 3 ROWS ONLY) AS posts
      FROM users t

  ## Aggregate Queries

  Aggregate queries scoped to relationships use iteration (N+1 queries) because
  XTDB's nested functions don't support aggregation directly.
  """

  require Ash.Query
  require Logger

  alias AshXTDB.DataLayer.Errors
  alias AshXTDB.DataLayer.Info
  alias AshXTDB.DataLayer.ResultTransformer
  alias AshXTDB.NestedResult
  alias AshXTDB.SQL

  # ============================================================================
  # Query Lateral Joins
  # ============================================================================

  @doc """
  Run a query with lateral join semantics using XTDB's NEST_MANY/NEST_ONE.

  ## Simple Relationship (1 join link)

  For has_many, belongs_to, has_one relationships:

      run_query_with_lateral_join(query, root_data, resource, [
        {source_query, source_attribute, destination_attribute, relationship}
      ])

  ## Many-to-Many Relationship (2 join links)

  For relationships through a join table:

      run_query_with_lateral_join(query, root_data, resource, [
        {source_query, source_attribute, source_attr_on_join, relationship},
        {through_query, dest_attr_on_join, destination_attribute, through_relationship}
      ])
  """
  @spec run_query_with_lateral_join(SQL.t(), [struct()], Ash.Resource.t(), list()) ::
          {:ok, [struct()]} | {:error, term()}
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
  # Aggregate Lateral Joins
  # ============================================================================

  @doc """
  Run an aggregate query with lateral join semantics.

  Computes aggregates scoped to each parent record's relationship.
  Uses iteration (N+1 queries) because XTDB's NEST_MANY/NEST_ONE don't support
  aggregation directly.

  Returns a list of maps with aggregate results and `:__lateral_join_source__`
  containing the parent's primary key.
  """
  @spec run_aggregate_query_with_lateral_join(
          SQL.t(),
          [Ash.Query.Aggregate.t()],
          [struct()],
          Ash.Resource.t(),
          list()
        ) :: {:ok, [map()]} | {:error, term()}
  # Simple relationship
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

  # Many-to-many relationship
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
          Ash.Filter.parse!(source_resource, or: conditions)
      end

    # Build query with nested subquery
    parent_query = %SQL{
      resource: source_resource,
      domain: query.domain,
      table: source_table,
      filter: parent_filter,
      context: query.context,
      nested_subqueries: [nested_config]
    }

    {sql, params} = SQL.to_sql(parent_query, :select)

    Logger.debug("AshXTDB NEST_#{String.upcase(to_string(nest_type))} SQL: #{sql}")

    case repo.query(sql, params) do
      {:ok, %Postgrex.Result{rows: rows, columns: columns}} ->
        # Transform nested results
        parent_records = NestedResult.transform_rows(rows, columns, [nested_config])

        # Map _id to primary key for parent records (so extract_nested can find pkey)
        parent_records =
          Enum.map(parent_records, fn record ->
            ResultTransformer.map_id_to_primary_key(record, source_resource)
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
        {:error, Errors.to_ash_error(error)}
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
      correlation:
        {:through_subquery,
         %{
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
          Ash.Filter.parse!(source_resource, or: conditions)
      end

    # Build query with nested subquery
    parent_query = %SQL{
      resource: source_resource,
      domain: query.domain,
      table: source_table,
      filter: parent_filter,
      context: query.context,
      nested_subqueries: [nested_config]
    }

    {sql, params} = SQL.to_sql(parent_query, :select)

    Logger.debug("AshXTDB NEST_MANY (M2M) SQL: #{sql}")

    case repo.query(sql, params) do
      {:ok, %Postgrex.Result{rows: rows, columns: columns}} ->
        parent_records = NestedResult.transform_rows(rows, columns, [nested_config])

        # Map _id to primary key for parent records (so extract_nested can find pkey)
        parent_records =
          Enum.map(parent_records, fn record ->
            ResultTransformer.map_id_to_primary_key(record, source_resource)
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
        {:error, Errors.to_ash_error(error)}
    end
  end

  # ============================================================================
  # Aggregate Lateral Join Helpers
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
  # Aggregate Query Helper (used internally)
  # ============================================================================

  defp run_aggregate_query(query, aggregates, resource) do
    repo = Info.repo!(resource)
    {sql, params} = SQL.to_aggregate_sql(query, aggregates)

    Logger.debug("AshXTDB Lateral Aggregate SQL: #{sql} with params: #{inspect(params)}")

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
end
