# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL do
  @moduledoc """
  Represents an XTDB query and provides SQL generation.

  XTDB has specific SQL requirements:
  - SELECT requires fully-qualified column names (table.column or alias.column)
  - INSERT uses `_id` for the primary key column
  - UPDATE/DELETE use `"_id"` (quoted) in WHERE clauses
  - SELECT * doesn't work, must specify columns explicitly

  ## Module Organization

  SQL generation is organized into focused submodules:

  - `AshXTDB.SQL.Core` - Shared utilities (value escaping, identifier quoting)
  - `AshXTDB.SQL.Filter` - WHERE clause generation
  - `AshXTDB.SQL.Nested` - NEST_MANY/NEST_ONE subqueries
  - `AshXTDB.SQL.Temporal` - Temporal clause generation
  - `AshXTDB.SQL.DML.Insert` - INSERT statement generation
  - `AshXTDB.SQL.DML.Update` - UPDATE statement generation
  - `AshXTDB.SQL.DML.Delete` - DELETE statement generation
  - `AshXTDB.SQL.DML.Patch` - PATCH (upsert) statement generation
  - `AshXTDB.SQL.Aggregate` - Aggregate function generation
  - `AshXTDB.SQL.Window` - Window function generation
  - `AshXTDB.SQL.CTE` - CTEs and set operations

  This module serves as the main entry point and defines the Query struct.
  """

  alias AshXTDB.SQL.Aggregate
  alias AshXTDB.SQL.Core
  alias AshXTDB.SQL.CTE
  alias AshXTDB.SQL.DML.Delete
  alias AshXTDB.SQL.DML.Insert
  alias AshXTDB.SQL.DML.Update
  alias AshXTDB.SQL.Filter
  alias AshXTDB.SQL.Nested
  alias AshXTDB.SQL.Temporal
  alias AshXTDB.SQL.Window

  defstruct [
    :resource,
    :domain,
    :table,
    :filter,
    :sort,
    :limit,
    :offset,
    :select,
    :distinct,
    :context,
    :tenant,
    joins: %{},
    aggregates: [],
    calculations: [],
    nested_subqueries: [],
    # Advanced query features
    window_functions: [],
    ctes: [],
    set_operation: nil
  ]

  @type join_info :: %{
          table: String.t(),
          alias: String.t(),
          source_attr: atom(),
          dest_attr: atom(),
          resource: Ash.Resource.t()
        }

  @type nested_subquery :: %{
          name: atom(),
          type: :nest_many | :nest_one,
          resource: Ash.Resource.t(),
          table: String.t(),
          correlation: {atom(), atom()} | {:through_subquery, map()},
          select: list(atom()) | nil,
          filter: Ash.Filter.t() | nil,
          sort: list() | nil,
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil
        }

  @type window_function :: %{
          name: atom(),
          function: atom(),
          field: atom() | nil,
          partition_by: list(atom()),
          order_by: list({atom(), :asc | :desc})
        }

  @type cte :: %{
          name: String.t(),
          query: t()
        }

  @type set_operation ::
          {:union, t()}
          | {:union_all, t()}
          | {:intersect, t()}
          | {:except, t()}
          | nil

  @type t :: %__MODULE__{
          resource: Ash.Resource.t(),
          domain: Ash.Domain.t(),
          table: String.t(),
          filter: Ash.Filter.t() | nil,
          sort: list() | nil,
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          select: list(atom()) | nil,
          distinct: list(atom()) | nil,
          context: map() | nil,
          tenant: term() | nil,
          aggregates: list(),
          calculations: list(),
          joins: %{list(atom()) => join_info()},
          nested_subqueries: list(nested_subquery()),
          window_functions: list(window_function()),
          ctes: list(cte()),
          set_operation: set_operation()
        }

  # Table alias for XTDB queries
  @table_alias "t"

  @doc """
  Converts a Query struct to SQL.
  """
  @spec to_sql(t(), :select) :: {String.t(), list()}
  def to_sql(%__MODULE__{nested_subqueries: nested} = query, :select) when nested != [] do
    # Use nested subquery builder for queries with NEST_MANY/NEST_ONE
    {select_clause, select_params} = Nested.build_nested_select(query, nested)
    from_clause = build_from(query)

    # Build aggregate joins for BOTH sort and filter aggregates
    {agg_join_clauses, agg_alias_map} = build_aggregate_joins(query)

    {where_clause, where_params, joins} = build_where(query, agg_alias_map)
    join_clauses = build_joins(joins)
    order_clause = build_order(query, agg_alias_map)
    limit_clause = build_limit(query)
    offset_clause = build_offset(query)

    # SQL:2011 order: OFFSET comes before FETCH
    sql =
      [
        select_clause,
        from_clause,
        join_clauses,
        agg_join_clauses,
        where_clause,
        order_clause,
        offset_clause,
        limit_clause
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    {sql, select_params ++ where_params}
  end

  def to_sql(%__MODULE__{distinct: distinct} = query, :select)
      when is_list(distinct) and distinct != [] do
    # DISTINCT ON implementation using ROW_NUMBER window function
    # This wraps the query in a subquery with ROW_NUMBER() partitioned by distinct fields
    build_distinct_on_query(query)
  end

  def to_sql(%__MODULE__{} = query, :select) do
    cte_clause = build_cte_clause(query.ctes)
    {select_clause, _} = build_select_with_windows(query)
    from_clause = build_from(query)

    # Build aggregate joins for BOTH sort and filter aggregates
    # This must happen before build_where so the alias map is available
    {agg_join_clauses, agg_alias_map} = build_aggregate_joins(query)

    # Pass aggregate alias map to filter for aggregate reference resolution
    {where_clause, params, joins} = build_where(query, agg_alias_map)
    join_clauses = build_joins(joins)
    order_clause = build_order(query, agg_alias_map)
    limit_clause = build_limit(query)
    offset_clause = build_offset(query)
    set_operation_clause = build_set_operation(query.set_operation)

    # SQL:2011 order: OFFSET comes before FETCH
    sql =
      [
        cte_clause,
        select_clause,
        from_clause,
        join_clauses,
        agg_join_clauses,
        where_clause,
        order_clause,
        offset_clause,
        limit_clause,
        set_operation_clause
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    {sql, params}
  end

  @doc """
  Converts a Query struct to an aggregate SQL query.
  """
  @spec to_aggregate_sql(t(), list()) :: {String.t(), list()}
  def to_aggregate_sql(%__MODULE__{context: context} = query, aggregates) do
    select_clause = Aggregate.build_aggregate_select(aggregates)
    from_clause = build_from(%{table: query.table, context: context})
    {where_clause, params, joins} = build_where(query)
    join_clauses = build_joins(joins)

    sql =
      [
        select_clause,
        from_clause,
        join_clauses,
        where_clause
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    {sql, params}
  end

  # ============================================================================
  # Window Functions
  # ============================================================================

  @doc """
  Adds a window function to the query.

  ## Options

  - `:name` - The alias for the window function result (required)
  - `:function` - The window function to use (e.g., :row_number, :rank, :sum)
  - `:field` - The field to operate on (optional for row_number, rank, etc.)
  - `:partition_by` - List of fields to partition by
  - `:order_by` - List of `{field, direction}` tuples for ordering

  ## Examples

      query
      |> AshXTDB.SQL.add_window_function(%{
        name: :row_num,
        function: :row_number,
        partition_by: [:organization_id],
        order_by: [{:created_at, :desc}]
      })

      query
      |> AshXTDB.SQL.add_window_function(%{
        name: :running_total,
        function: :sum,
        field: :amount,
        order_by: [{:date, :asc}]
      })
  """
  @spec add_window_function(t(), map()) :: t()
  def add_window_function(%__MODULE__{} = query, window_function) do
    %{query | window_functions: query.window_functions ++ [window_function]}
  end

  @doc """
  Adds a CTE (Common Table Expression) to the query.

  CTEs are defined using WITH clauses and can be referenced in the main query.

  ## Examples

      subquery = %AshXTDB.SQL{...}
      query
      |> AshXTDB.SQL.add_cte("active_users", subquery)
  """
  @spec add_cte(t(), String.t(), t()) :: t()
  def add_cte(%__MODULE__{} = query, name, cte_query) do
    %{query | ctes: query.ctes ++ [%{name: name, query: cte_query}]}
  end

  @doc """
  Sets a UNION operation with another query.
  """
  @spec union(t(), t()) :: t()
  def union(%__MODULE__{} = query, other_query) do
    %{query | set_operation: {:union, other_query}}
  end

  @doc """
  Sets a UNION ALL operation with another query.
  """
  @spec union_all(t(), t()) :: t()
  def union_all(%__MODULE__{} = query, other_query) do
    %{query | set_operation: {:union_all, other_query}}
  end

  @doc """
  Sets an INTERSECT operation with another query.
  """
  @spec intersect(t(), t()) :: t()
  def intersect(%__MODULE__{} = query, other_query) do
    %{query | set_operation: {:intersect, other_query}}
  end

  @doc """
  Sets an EXCEPT operation with another query.
  """
  @spec except(t(), t()) :: t()
  def except(%__MODULE__{} = query, other_query) do
    %{query | set_operation: {:except, other_query}}
  end

  # ============================================================================
  # Insert/Update/Delete Operations (delegated to DML modules)
  # ============================================================================

  @doc """
  Builds an INSERT statement.
  See `AshXTDB.SQL.DML.Insert.build_insert/3` for documentation.
  """
  defdelegate build_insert(table, record, resource), to: Insert

  @doc """
  Builds an INSERT statement with explicit valid time period.
  See `AshXTDB.SQL.DML.Insert.build_insert_with_valid_time/5` for documentation.
  """
  defdelegate build_insert_with_valid_time(table, record, resource, from, to), to: Insert

  @doc """
  Builds an INSERT statement with explicit valid_from time.
  See `AshXTDB.SQL.DML.Insert.build_insert_with_valid_from/4` for documentation.
  """
  defdelegate build_insert_with_valid_from(table, record, resource, from), to: Insert

  @doc """
  Builds a bulk INSERT statement for multiple records.
  See `AshXTDB.SQL.DML.Insert.build_bulk_insert/3` for documentation.
  """
  defdelegate build_bulk_insert(table, records, resource), to: Insert

  @doc """
  Builds an UPDATE statement.
  See `AshXTDB.SQL.DML.Update.build_update/5` for documentation.
  """
  defdelegate build_update(table, pkey, changes, atomics, resource), to: Update

  @doc """
  Builds an UPDATE statement with FOR PORTION OF VALID_TIME clause.
  See `AshXTDB.SQL.DML.Update.build_update_for_portion/6` for documentation.
  """
  defdelegate build_update_for_portion(table, pkey, changes, resource, from, to), to: Update

  @doc """
  Builds an UPDATE statement with WHERE clause from a query filter.
  See `AshXTDB.SQL.DML.Update.build_update_query/5` for documentation.
  """
  defdelegate build_update_query(table, changes, atomics, query, resource), to: Update

  @doc """
  Builds a DELETE statement.
  See `AshXTDB.SQL.DML.Delete.build_delete/3` for documentation.
  """
  defdelegate build_delete(table, pkey, resource), to: Delete

  @doc """
  Builds a DELETE statement with FOR PORTION OF VALID_TIME clause.
  See `AshXTDB.SQL.DML.Delete.build_delete_for_portion/5` for documentation.
  """
  defdelegate build_delete_for_portion(table, pkey, resource, from, to), to: Delete

  @doc """
  Builds a DELETE statement with WHERE clause from a query filter.
  See `AshXTDB.SQL.DML.Delete.build_destroy_query/3` for documentation.
  """
  defdelegate build_destroy_query(table, query, resource), to: Delete

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Build SELECT with optional window functions
  defp build_select_with_windows(%{window_functions: []} = query) do
    build_select(query)
  end

  defp build_select_with_windows(%{window_functions: window_functions} = query) do
    {base_select, params} = build_select(query)
    window_clauses = Window.build_window_functions(window_functions)

    if window_clauses do
      # Extract just the column list from "SELECT columns"
      select_columns = String.replace_prefix(base_select, "SELECT ", "")
      select_columns = String.replace_prefix(select_columns, "DISTINCT ", "")
      is_distinct = String.starts_with?(base_select, "SELECT DISTINCT")

      prefix = if is_distinct, do: "SELECT DISTINCT", else: "SELECT"
      {"#{prefix} #{select_columns}, #{window_clauses}", params}
    else
      {base_select, params}
    end
  end

  # Delegate to CTE module for building WITH clauses
  defp build_cte_clause(ctes) do
    CTE.build_cte_clause(ctes, fn query -> to_sql(query, :select) end)
  end

  # Delegate to CTE module for set operations
  defp build_set_operation(set_op) do
    CTE.build_set_operation(set_op, fn query -> to_sql(query, :select) end)
  end

  # ============================================================================
  # DISTINCT ON Implementation
  # ============================================================================
  # Uses ROW_NUMBER() window function to implement DISTINCT ON behavior
  # since XTDB may not support PostgreSQL's DISTINCT ON syntax directly.
  #
  # Example output:
  # SELECT sub.* FROM (
  #   SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.field1 ORDER BY t.sort_col) as __rn
  #   FROM table t
  #   WHERE ...
  # ) sub WHERE sub.__rn = 1 ORDER BY ...

  defp build_distinct_on_query(
         %{distinct: distinct, sort: sort, resource: resource, table: table} = query
       ) do
    # Build the inner query without distinct (we handle it via ROW_NUMBER)
    inner_query = %{query | distinct: nil}

    # Get columns for the inner SELECT
    columns = get_all_columns(resource, table)
    calc_sql = build_calculation_selects(inner_query)

    # Build PARTITION BY clause from distinct fields
    partition_cols =
      Enum.map_join(distinct, ", ", fn
        {field, _direction} -> to_select_column_name(field, @table_alias)
        field when is_atom(field) -> to_select_column_name(field, @table_alias)
      end)

    # Build aggregate joins for both sort and filter
    {agg_join_clauses, agg_alias_map} = build_aggregate_joins(inner_query)

    # Build ORDER BY for the window function (use sort if provided, otherwise distinct order)
    window_order_sql =
      if sort && sort != [] do
        build_order_for_window(sort, resource, inner_query, agg_alias_map)
      else
        # Default to ordering by distinct fields
        Enum.map_join(distinct, ", ", fn
          {field, direction} ->
            "#{to_select_column_name(field, @table_alias)} #{direction_to_sql(direction)}"

          field ->
            "#{to_select_column_name(field, @table_alias)} ASC"
        end)
      end

    # Build the inner SELECT with ROW_NUMBER
    inner_select =
      if calc_sql && calc_sql != "" do
        "SELECT #{columns}, #{calc_sql}, ROW_NUMBER() OVER (PARTITION BY #{partition_cols} ORDER BY #{window_order_sql}) AS __rn"
      else
        "SELECT #{columns}, ROW_NUMBER() OVER (PARTITION BY #{partition_cols} ORDER BY #{window_order_sql}) AS __rn"
      end

    from_clause = build_from(inner_query)
    {where_clause, params, joins} = build_where(inner_query, agg_alias_map)
    join_clauses = build_joins(joins)

    # Build the inner query SQL
    inner_sql =
      [
        inner_select,
        from_clause,
        join_clauses,
        agg_join_clauses,
        where_clause
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    # Build outer query columns - need to re-alias them from sub.*
    outer_columns = get_outer_columns_for_distinct(resource, calc_sql)

    # Build outer ORDER BY (rewrite to use sub. alias)
    outer_order =
      if sort && sort != [] do
        build_order_for_outer_distinct(sort, resource, inner_query)
      else
        nil
      end

    limit_clause = build_limit(query)
    offset_clause = build_offset(query)

    # Build the complete SQL with subquery
    sql =
      [
        "SELECT #{outer_columns} FROM (#{inner_sql}) sub WHERE sub.__rn = 1",
        outer_order,
        offset_clause,
        limit_clause
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    {sql, params}
  end

  # Build ORDER BY clause for use inside the window function
  defp build_order_for_window(sort, resource, query, agg_alias_map) do
    Enum.map_join(sort, ", ", fn {field, direction} ->
      expr_sql = sort_field_to_sql(field, resource, query, agg_alias_map)
      "#{expr_sql}#{direction_to_sql(direction)}"
    end)
  end

  # Build ORDER BY for the outer query (using sub. alias)
  defp build_order_for_outer_distinct(sort, resource, _query) do
    clauses =
      Enum.map_join(sort, ", ", fn {field, direction} ->
        col_name = get_sort_field_name(field, resource)
        "sub.#{quote_identifier(col_name)}#{direction_to_sql(direction)}"
      end)

    "ORDER BY #{clauses}"
  end

  # Get column name for sorting in outer query
  defp get_sort_field_name(field, _resource) when is_atom(field) do
    if field == :id, do: "_id", else: Atom.to_string(field)
  end

  defp get_sort_field_name(%Ash.Query.Calculation{name: name}, _resource), do: "__calc_#{name}"
  defp get_sort_field_name(%Ash.Query.Aggregate{name: name}, _resource), do: Atom.to_string(name)
  defp get_sort_field_name(%{name: name}, _resource), do: Atom.to_string(name)

  # Get outer columns for distinct subquery (mapping from sub.*)
  defp get_outer_columns_for_distinct(resource, calc_sql) do
    attrs = Ash.Resource.Info.attributes(resource)

    columns =
      attrs
      |> Enum.map(& &1.name)
      |> ensure_id_column()
      |> Enum.map_join(", ", fn
        :id -> "sub.\"_id\" AS \"_id\""
        :_id -> "sub.\"_id\""
        attr -> "sub.#{quote_identifier(Atom.to_string(attr))}"
      end)

    if calc_sql && calc_sql != "" do
      # Include calculation columns
      calc_cols =
        calc_sql
        |> String.split(", ")
        |> Enum.map(fn calc_expr ->
          # Extract the alias from "expr AS alias"
          case Regex.run(~r/AS\s+"?(__calc_\w+)"?$/i, calc_expr) do
            [_, alias] -> "sub.#{quote_identifier(alias)}"
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")

      if calc_cols != "", do: "#{columns}, #{calc_cols}", else: columns
    else
      columns
    end
  end

  defp build_select(%{select: nil, distinct: nil, resource: resource, table: table} = query) do
    # XTDB requires explicit column list with table alias
    columns = get_all_columns(resource, table)
    calc_sql = build_calculation_selects(query)

    if calc_sql && calc_sql != "" do
      {"SELECT #{columns}, #{calc_sql}", []}
    else
      {"SELECT #{columns}", []}
    end
  end

  defp build_select(%{select: select, distinct: nil, table: _table} = query)
       when is_list(select) do
    columns =
      select
      |> ensure_id_column()
      |> Enum.map_join(", ", &to_select_column_name(&1, @table_alias))

    calc_sql = build_calculation_selects(query)

    if calc_sql && calc_sql != "" do
      {"SELECT #{columns}, #{calc_sql}", []}
    else
      {"SELECT #{columns}", []}
    end
  end

  # Build SQL SELECT expressions for calculations that can be evaluated in SQL
  # Returns nil if no calculations or empty string if none are SQL-evaluable
  defp build_calculation_selects(%{calculations: []}), do: nil
  defp build_calculation_selects(%{calculations: nil}), do: nil

  defp build_calculation_selects(%{calculations: calculations, resource: resource, table: _table}) do
    state = %{
      resource: resource,
      param_idx: 1,
      params: [],
      joins: %{},
      join_counter: 0,
      table_alias: @table_alias
    }

    calculations
    |> Enum.map(fn {calculation, expression} ->
      # Try to convert the expression to SQL
      case Filter.expression_to_sql(expression, state) do
        {nil, _state} ->
          # Not SQL-evaluable, will be computed in Elixir
          nil

        {sql, new_state} ->
          # SQL-evaluable - inline any parameters into the SQL
          params = Enum.reverse(new_state.params)
          inlined_sql = inline_params(sql, params)
          calc_name = calculation_select_name(calculation)
          "#{inlined_sql} AS #{quote_identifier(calc_name)}"
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  # Get the name to use for a calculation in SELECT
  defp calculation_select_name(%{load: load}) when not is_nil(load), do: "__calc_#{load}"
  defp calculation_select_name(%{name: name}), do: "__calc_#{name}"

  defp get_all_columns(resource, _table) do
    attrs = Ash.Resource.Info.attributes(resource)

    attrs
    |> Enum.map(& &1.name)
    |> ensure_id_column()
    |> Enum.map_join(", ", &to_select_column_name(&1, @table_alias))
  end

  defp build_from(%{table: table, context: context}) do
    # XTDB temporal syntax: FROM table FOR temporal_clause AS alias
    # e.g., FROM users FOR VALID_TIME AS OF TIMESTAMP '...' AS t
    temporal_clauses = Temporal.build_temporal_clauses_from_context(context)

    quoted_table = quote_identifier(table)

    if temporal_clauses == "" do
      "FROM #{quoted_table} #{@table_alias}"
    else
      "FROM #{quoted_table} #{temporal_clauses} #{@table_alias}"
    end
  end

  defp build_from(%{table: table}) do
    # Use table alias for XTDB (fallback when no context)
    "FROM #{quote_identifier(table)} #{@table_alias}"
  end

  defp build_where(query, agg_alias_map \\ %{})

  defp build_where(%{filter: nil}, _agg_alias_map) do
    {nil, [], %{}}
  end

  defp build_where(%{filter: filter, resource: resource, table: table}, agg_alias_map) do
    Filter.to_sql(filter, resource, table, 1, "t", agg_alias_map)
  end

  defp build_joins(joins) when joins == %{}, do: nil

  defp build_joins(joins) do
    # Sort joins by their path length to ensure proper ordering
    joins
    |> Map.values()
    |> Enum.sort_by(fn join -> String.length(join.alias) end)
    |> Enum.map_join(" ", fn join ->
      # Handle _id column quoting for join conditions
      source_col = format_join_column(join.source_alias, join.source_attr)
      dest_col = format_join_column(join.alias, join.dest_attr)
      quoted_table = quote_identifier(join.table)
      "LEFT JOIN #{quoted_table} #{join.alias} ON #{source_col} = #{dest_col}"
    end)
  end

  defp format_join_column(alias, :id), do: "#{alias}.\"_id\""
  defp format_join_column(alias, :_id), do: "#{alias}.\"_id\""

  defp format_join_column(alias, attr) do
    quoted_col = quote_identifier(Atom.to_string(attr))
    "#{alias}.#{quoted_col}"
  end

  defp build_order(query, agg_alias_map)
  defp build_order(%{sort: nil}, _agg_alias_map), do: nil
  defp build_order(%{sort: []}, _agg_alias_map), do: nil

  defp build_order(%{sort: sort, table: _table, resource: resource} = query, agg_alias_map) do
    clauses =
      Enum.map_join(sort, ", ", fn {field, direction} ->
        expr_sql = sort_field_to_sql(field, resource, query, agg_alias_map)
        dir_sql = direction_to_sql(direction)
        "#{expr_sql}#{dir_sql}"
      end)

    "ORDER BY #{clauses}"
  end

  # Build aggregate subquery joins for BOTH sorting AND filtering
  # Returns {join_sql, aggregate_alias_map}
  defp build_aggregate_joins(%{resource: resource, table: table} = query) do
    # Collect aggregates from sort
    sort_aggregates = get_sort_aggregates(query)

    # Collect aggregates from filter
    filter_aggregates = get_filter_aggregates(query)

    # Combine and deduplicate
    all_aggregates =
      (sort_aggregates ++ filter_aggregates)
      |> Enum.uniq_by(& &1.name)

    if Enum.empty?(all_aggregates) do
      {nil, %{}}
    else
      # Build joins for each aggregate
      {joins, alias_map} =
        all_aggregates
        |> Enum.with_index()
        |> Enum.reduce({[], %{}}, fn {aggregate, idx}, {joins_acc, alias_acc} ->
          agg_alias = "agg#{idx}"

          {join_sql, agg_col} =
            build_aggregate_subquery_join(aggregate, resource, table, agg_alias)

          {[join_sql | joins_acc], Map.put(alias_acc, aggregate.name, agg_col)}
        end)

      {Enum.reverse(joins) |> Enum.join(" "), alias_map}
    end
  end

  # Extract aggregates from sort clause
  defp get_sort_aggregates(%{sort: nil}), do: []
  defp get_sort_aggregates(%{sort: []}), do: []

  defp get_sort_aggregates(%{sort: sort, resource: resource}) do
    sort
    |> Enum.filter(fn
      {%Ash.Query.Aggregate{}, _direction} ->
        true

      {field, _direction} when is_atom(field) ->
        not is_nil(Ash.Resource.Info.aggregate(resource, field))

      _ ->
        false
    end)
    |> Enum.map(fn
      {%Ash.Query.Aggregate{} = agg, _direction} -> agg
      {field, _direction} -> Ash.Resource.Info.aggregate(resource, field)
    end)
  end

  # Extract aggregates from filter clause
  defp get_filter_aggregates(%{filter: nil}), do: []

  defp get_filter_aggregates(%{filter: %Ash.Filter{} = filter, resource: resource}) do
    # Use Ash.Filter.used_aggregates to find all aggregate references in the filter
    filter
    |> Ash.Filter.used_aggregates()
    |> Enum.map(fn
      %Ash.Query.Aggregate{} = agg ->
        agg

      agg_name when is_atom(agg_name) ->
        # Look up the aggregate definition from the resource
        Ash.Resource.Info.aggregate(resource, agg_name)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp get_filter_aggregates(_), do: []

  # Build a single aggregate subquery join
  defp build_aggregate_subquery_join(aggregate, resource, _table, agg_alias) do
    relationship_path = aggregate.relationship_path
    relationship = Ash.Resource.Info.relationship(resource, hd(relationship_path))
    dest_table = AshXTDB.DataLayer.Info.table!(relationship.destination)

    # Use a unique inner alias for the subquery table
    inner_alias = "inner_#{agg_alias}"

    # Determine the aggregate SQL function
    agg_func = aggregate_kind_to_sql(aggregate.kind, aggregate.field)

    # Get the join column - handle :id -> _id mapping
    dest_attr = relationship.destination_attribute
    dest_col = if dest_attr == :id, do: "_id", else: Atom.to_string(dest_attr)

    source_attr = relationship.source_attribute

    source_col =
      if source_attr == :id, do: "\"_id\"", else: quote_identifier(Atom.to_string(source_attr))

    # Build the subquery
    subquery = """
    LEFT JOIN (
      SELECT #{inner_alias}.#{quote_identifier(dest_col)}, #{agg_func} AS #{quote_identifier(Atom.to_string(aggregate.name))}
      FROM #{quote_identifier(dest_table)} #{inner_alias}
      GROUP BY #{inner_alias}.#{quote_identifier(dest_col)}
    ) #{agg_alias} ON #{@table_alias}.#{source_col} = #{agg_alias}.#{quote_identifier(dest_col)}
    """

    agg_col = "COALESCE(#{agg_alias}.#{quote_identifier(Atom.to_string(aggregate.name))}, 0)"
    {subquery, agg_col}
  end

  defp aggregate_kind_to_sql(:count, nil), do: "COUNT(*)"
  defp aggregate_kind_to_sql(:count, field), do: "COUNT(#{field})"
  defp aggregate_kind_to_sql(:sum, field), do: "SUM(#{field})"
  defp aggregate_kind_to_sql(:avg, field), do: "AVG(#{field})"
  defp aggregate_kind_to_sql(:min, field), do: "MIN(#{field})"
  defp aggregate_kind_to_sql(:max, field), do: "MAX(#{field})"
  defp aggregate_kind_to_sql(kind, _field), do: raise("Unsupported aggregate kind: #{kind}")

  # Convert sort direction to SQL
  # NOTE: XTDB has a quirk where DESC reverses NULLS FIRST/LAST behavior.
  # To get correct results, we swap NULLS FIRST <-> NULLS LAST for DESC sorts.
  # See: https://github.com/xtdb/xtdb/issues/... (if there's a bug report)
  defp direction_to_sql(:asc), do: " ASC"
  defp direction_to_sql(:desc), do: " DESC"
  defp direction_to_sql(:asc_nils_first), do: " ASC NULLS FIRST"
  defp direction_to_sql(:asc_nils_last), do: " ASC NULLS LAST"
  # XTDB quirk: swap NULLS FIRST/LAST for DESC to get correct behavior
  defp direction_to_sql(:desc_nils_first), do: " DESC NULLS LAST"
  defp direction_to_sql(:desc_nils_last), do: " DESC NULLS FIRST"

  # Convert a sort field to SQL - handles calculations, aggregates, and regular fields

  # Handle Ash.Query.Aggregate struct (when Ash pre-processes aggregate sorts)
  defp sort_field_to_sql(%Ash.Query.Aggregate{name: name}, _resource, _query, agg_alias_map) do
    # Use the pre-computed alias from the aggregate join
    case Map.get(agg_alias_map, name) do
      nil ->
        # Fallback if no alias (shouldn't happen if build_aggregate_sort_joins worked)
        "\"#{name}\""

      agg_expr ->
        agg_expr
    end
  end

  # Handle Ash.Query.Calculation struct (when Ash pre-processes calculation sorts)
  defp sort_field_to_sql(
         %Ash.Query.Calculation{module: Ash.Resource.Calculation.Expression, opts: opts},
         resource,
         _query,
         _agg_alias_map
       ) do
    case Keyword.get(opts, :expr) do
      nil ->
        "NULL"

      expr ->
        sort_expression_to_sql(expr, resource)
    end
  end

  defp sort_field_to_sql(%Ash.Query.Calculation{name: name}, _resource, _query, _agg_alias_map) do
    # Non-expression calculation - fall back to column reference
    "#{@table_alias}.\"#{name}\""
  end

  defp sort_field_to_sql(field, resource, _query, agg_alias_map) when is_atom(field) do
    # Check if this is a calculation
    case Ash.Resource.Info.calculation(resource, field) do
      %{calculation: {Ash.Resource.Calculation.Expression, opts}} ->
        # Expression-based calculation - get expression from opts
        case Keyword.get(opts, :expr) do
          nil ->
            # No expression, fall back to column name
            "#{@table_alias}.\"#{field}\""

          expr ->
            sort_expression_to_sql(expr, resource)
        end

      nil ->
        # Not a calculation - check if it's an aggregate
        case Ash.Resource.Info.aggregate(resource, field) do
          nil ->
            # Regular attribute - use column name with table alias
            "#{@table_alias}.\"#{field}\""

          _aggregate ->
            # Aggregate - use the pre-computed alias from the join
            case Map.get(agg_alias_map, field) do
              nil ->
                # Fallback if no alias (shouldn't happen if build_aggregate_sort_joins worked)
                "\"#{field}\""

              agg_expr ->
                agg_expr
            end
        end

      _other_calc ->
        # Other calculation type (module-based) - fall back to column reference
        "#{@table_alias}.\"#{field}\""
    end
  end

  defp sort_field_to_sql(field, _resource, _query, _agg_alias_map) do
    # Fallback for non-atom fields - convert to string
    field_str = if is_binary(field), do: field, else: "#{inspect(field)}"
    "#{@table_alias}.\"#{field_str}\""
  end

  # Convert a calculation expression to SQL for ORDER BY
  defp sort_expression_to_sql(expression, resource) do
    state = %{
      resource: resource,
      param_idx: 1,
      params: [],
      joins: %{},
      join_counter: 0,
      table_alias: @table_alias
    }

    case Filter.expression_to_sql(expression, state) do
      {nil, _state} ->
        # Can't convert to SQL, this shouldn't happen for sortable calculations
        "NULL"

      {sql, new_state} ->
        # Inline any parameters
        params = Enum.reverse(new_state.params)
        inline_params(sql, params)
    end
  end

  # XTDB uses SQL:2011 FETCH/OFFSET syntax instead of PostgreSQL LIMIT/OFFSET
  defp build_limit(%{limit: nil}), do: nil
  defp build_limit(%{limit: limit}), do: "FETCH FIRST #{limit} ROWS ONLY"

  defp build_offset(%{offset: nil}), do: nil
  defp build_offset(%{offset: 0}), do: nil
  defp build_offset(%{offset: offset}), do: "OFFSET #{offset} ROWS"

  defp to_select_column_name(field, table), do: Core.to_select_column_name(field, table)

  # ============================================================================
  # Public API - Delegated to Core Module
  # ============================================================================

  # These functions delegate to AshXTDB.SQL.Core for the actual implementation.
  # The functions remain here for backward compatibility.

  @doc """
  Inlines parameters into SQL by replacing $1, $2, etc. with actual values.

  We use the simple query protocol which doesn't support
  parameterized queries, so we need to inline values directly into the SQL.
  """
  @spec inline_params(String.t(), list()) :: String.t()
  defdelegate inline_params(sql, params), to: Core

  @doc """
  Escapes a value for use in XTDB SQL.

  Handles various Elixir types and converts them to their SQL representation.
  """
  @spec escape_value(term()) :: String.t()
  defdelegate escape_value(value), to: Core

  @doc """
  Quotes a SQL identifier (table name, column name) to prevent SQL injection.

  Identifiers are wrapped in double quotes and any embedded double quotes
  are escaped by doubling them.

  ## Examples

      iex> AshXTDB.SQL.quote_identifier("users")
      "\\"users\\""

      iex> AshXTDB.SQL.quote_identifier("user\\"table")
      "\\"user\\"\\"table\\""
  """
  @spec quote_identifier(String.t() | atom()) :: String.t()
  defdelegate quote_identifier(identifier), to: Core

  @doc """
  Validates that an identifier contains only safe characters.

  Raises ArgumentError if the identifier contains potentially dangerous characters.
  This is a defense-in-depth measure in addition to quoting.

  Allowed: letters, numbers, underscores, and dots (for schema.table notation)
  """
  @spec validate_identifier!(String.t() | atom()) :: :ok
  defdelegate validate_identifier!(identifier), to: Core

  @doc """
  Safely quotes an identifier after validation.

  This combines validation and quoting for maximum safety.
  """
  @spec safe_identifier(String.t() | atom()) :: String.t()
  defdelegate safe_identifier(identifier), to: Core

  @doc false
  defdelegate table_alias(), to: Core

  @doc false
  defdelegate field_to_column(field), to: Core

  @doc false
  defdelegate ensure_id_column(columns), to: Core
end
