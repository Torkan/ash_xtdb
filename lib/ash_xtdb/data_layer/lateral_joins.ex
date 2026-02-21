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
        [{source_query, source_attribute, destination_attribute, relationship}]
      ) do
    source_resource = source_query.resource
    dest_table = Info.table!(destination_resource)

    nest_type =
      case relationship.cardinality do
        :one -> :nest_one
        :many -> :nest_many
      end

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

    execute_nested_query(query, root_data, source_resource, destination_resource,
      nested_config: nested_config,
      relationship_name: relationship.name
    )
  end

  # Many-to-many relationship (2 join links) - e.g., through join table
  def run_query_with_lateral_join(
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
    through_table = Info.table!(through_resource)
    dest_table = Info.table!(destination_resource)

    nested_config = %{
      name: relationship.name,
      type: :nest_many,
      resource: destination_resource,
      table: dest_table,
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

    execute_nested_query(query, root_data, source_resource, destination_resource,
      nested_config: nested_config,
      relationship_name: relationship.name
    )
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
  # Shared NEST_MANY/NEST_ONE Execution
  # ============================================================================

  defp execute_nested_query(query, root_data, source_resource, destination_resource, opts) do
    nested_config = Keyword.fetch!(opts, :nested_config)
    relationship_name = Keyword.fetch!(opts, :relationship_name)
    repo = Info.repo!(source_resource)
    source_table = Info.table!(source_resource)
    pkey_attrs = Ash.Resource.Info.primary_key(source_resource)

    parent_filter = build_parent_filter(source_resource, pkey_attrs, root_data)

    parent_query = %SQL{
      resource: source_resource,
      domain: query.domain,
      table: source_table,
      filter: parent_filter,
      context: query.context,
      nested_subqueries: [nested_config]
    }

    {sql, params} = SQL.to_sql(parent_query, :select)

    Logger.debug("AshXTDB NEST SQL: #{sql}")

    case repo.query(sql, params) do
      {:ok, %Postgrex.Result{rows: rows, columns: columns}} ->
        parent_records =
          rows
          |> NestedResult.transform_rows(columns, [nested_config])
          |> Enum.map(&ResultTransformer.map_id_to_primary_key(&1, source_resource))

        nested_records =
          NestedResult.extract_nested(
            parent_records,
            relationship_name,
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

  defp run_simple_lateral_aggregate(query, aggregates, parents, source_attribute, dest_attribute) do
    destination_resource = query.resource

    Enum.reduce_while(parents, {:ok, []}, fn parent, {:ok, results} ->
      correlation_value = Map.get(parent, source_attribute)
      parent_pkey = parent_pkey_map(parent)

      if is_nil(correlation_value) do
        {:cont, {:ok, [tagged_default(aggregates, parent_pkey) | results]}}
      else
        correlated_filter =
          Ash.Filter.parse!(destination_resource, [{dest_attribute, correlation_value}])

        correlated_query = %{query | filter: merge_filter(query.filter, correlated_filter)}

        case ResultTransformer.run_aggregate_query(
               correlated_query,
               aggregates,
               destination_resource
             ) do
          {:ok, agg_result} ->
            {:cont, {:ok, [tag_with_source(agg_result, parent_pkey) | results]}}

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
      parent_pkey = parent_pkey_map(parent)

      if is_nil(correlation_value) do
        {:cont, {:ok, [tagged_default(aggregates, parent_pkey) | results]}}
      else
        case resolve_m2m_destination_values(
               through_query,
               correlation_value,
               source_attr_on_join,
               dest_attr_on_join
             ) do
          {:ok, []} ->
            {:cont, {:ok, [tagged_default(aggregates, parent_pkey) | results]}}

          {:ok, dest_attr_values} ->
            dest_filter =
              Ash.Filter.parse!(destination_resource, [
                {destination_attribute, [in: dest_attr_values]}
              ])

            correlated_query = %{query | filter: merge_filter(query.filter, dest_filter)}

            case ResultTransformer.run_aggregate_query(
                   correlated_query,
                   aggregates,
                   destination_resource
                 ) do
              {:ok, agg_result} ->
                {:cont, {:ok, [tag_with_source(agg_result, parent_pkey) | results]}}

              {:error, error} ->
                {:halt, {:error, error}}
            end

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end
    end)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Builds a filter to select parent records by primary key from root_data.
  defp build_parent_filter(resource, pkey_attrs, root_data) do
    pkey_values = Enum.map(root_data, fn record -> Map.take(record, pkey_attrs) end)

    case pkey_attrs do
      [pkey] ->
        values = Enum.map(pkey_values, &Map.get(&1, pkey))
        Ash.Filter.parse!(resource, [{pkey, [in: values]}])

      _ ->
        conditions = Enum.map(pkey_values, &Map.to_list/1)
        Ash.Filter.parse!(resource, or: conditions)
    end
  end

  # Resolves destination attribute values through a join table for M2M relationships.
  # Returns {:ok, values} or {:error, error}.
  defp resolve_m2m_destination_values(
         through_query,
         correlation_value,
         source_attr_on_join,
         dest_attr_on_join
       ) do
    filtered =
      Ash.Query.filter(
        through_query,
        ^Ash.Expr.ref(source_attr_on_join) == ^correlation_value
      )

    case Ash.read(filtered, authorize?: false) do
      {:ok, join_records} ->
        values =
          join_records
          |> Enum.map(&Map.get(&1, dest_attr_on_join))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        {:ok, values}

      {:error, error} ->
        {:error, error}
    end
  end

  # Merges an additional filter into an existing one (or uses it as-is if nil).
  defp merge_filter(nil, additional), do: additional
  defp merge_filter(existing, additional), do: Ash.Filter.add_to_filter!(existing, additional)

  # Extracts the primary key map from a parent record.
  defp parent_pkey_map(parent) do
    source_pkey = Ash.Resource.Info.primary_key(parent.__struct__)
    Map.take(parent, source_pkey)
  end

  # Builds a default aggregate result tagged with the parent's primary key.
  defp tagged_default(aggregates, parent_pkey) do
    aggregates
    |> ResultTransformer.default_aggregate_result()
    |> tag_with_source(parent_pkey)
  end

  # Tags a result map with the parent's primary key for lateral join association.
  defp tag_with_source(result, parent_pkey) do
    Map.put(result, :__lateral_join_source__, parent_pkey)
  end
end
