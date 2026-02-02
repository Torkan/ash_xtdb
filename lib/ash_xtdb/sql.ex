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
  """

  alias AshXTDB.SQL.Filter
  alias AshXTDB.SQL.Nested

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
          correlation: {atom(), atom()},
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
    select_clause = build_aggregate_select(aggregates)
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

  defp build_aggregate_select(aggregates) do
    clauses =
      Enum.map_join(aggregates, ", ", fn agg ->
        sql_func = aggregate_to_sql(agg)
        # Quote the alias to handle reserved words like 'exists'
        "#{sql_func} AS \"#{agg.name}\""
      end)

    "SELECT #{clauses}"
  end

  defp aggregate_to_sql(%{kind: :count, field: nil}) do
    "COUNT(*)"
  end

  defp aggregate_to_sql(%{kind: :count, field: field, uniq?: true}) do
    "COUNT(DISTINCT #{@table_alias}.#{field_to_column(field)})"
  end

  defp aggregate_to_sql(%{kind: :count, field: field}) do
    "COUNT(#{@table_alias}.#{field_to_column(field)})"
  end

  defp aggregate_to_sql(%{kind: :sum, field: field}) do
    "SUM(#{@table_alias}.#{field_to_column(field)})"
  end

  defp aggregate_to_sql(%{kind: :avg, field: field}) do
    "AVG(#{@table_alias}.#{field_to_column(field)})"
  end

  defp aggregate_to_sql(%{kind: :min, field: field}) do
    "MIN(#{@table_alias}.#{field_to_column(field)})"
  end

  defp aggregate_to_sql(%{kind: :max, field: field}) do
    "MAX(#{@table_alias}.#{field_to_column(field)})"
  end

  defp aggregate_to_sql(%{kind: :exists}) do
    # EXISTS returns boolean based on whether any rows exist
    "COUNT(*) > 0"
  end

  defp aggregate_to_sql(%{kind: :first, field: field}) do
    # XTDB may not support this directly, use MIN as approximation
    "MIN(#{@table_alias}.#{field_to_column(field)})"
  end

  defp aggregate_to_sql(%{kind: :list, field: field}) do
    # XTDB may support ARRAY_AGG
    "ARRAY_AGG(#{@table_alias}.#{field_to_column(field)})"
  end

  # Statistical aggregates
  defp aggregate_to_sql(%{kind: :stddev_pop, field: field}) do
    "STDDEV_POP(#{@table_alias}.#{field_to_column(field)})"
  end

  defp aggregate_to_sql(%{kind: :stddev_samp, field: field}) do
    "STDDEV_SAMP(#{@table_alias}.#{field_to_column(field)})"
  end

  defp aggregate_to_sql(%{kind: :var_pop, field: field}) do
    "VAR_POP(#{@table_alias}.#{field_to_column(field)})"
  end

  defp aggregate_to_sql(%{kind: :var_samp, field: field}) do
    "VAR_SAMP(#{@table_alias}.#{field_to_column(field)})"
  end

  # Boolean aggregates
  defp aggregate_to_sql(%{kind: :bool_and, field: field}) do
    "BOOL_AND(#{@table_alias}.#{field_to_column(field)})"
  end

  defp aggregate_to_sql(%{kind: :bool_or, field: field}) do
    "BOOL_OR(#{@table_alias}.#{field_to_column(field)})"
  end

  defp field_to_column(:id), do: "\"_id\""
  defp field_to_column(:_id), do: "\"_id\""
  defp field_to_column(field) when is_atom(field), do: Atom.to_string(field)
  defp field_to_column(%{name: name}), do: field_to_column(name)

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
  # Insert/Update/Delete Operations
  # ============================================================================

  @doc """
  Builds an INSERT statement.

  XTDB requires _id column (quoted) for the primary key.
  """
  @spec build_insert(String.t(), map(), Ash.Resource.t()) :: {String.t(), list()}
  def build_insert(table, record, _resource) do
    columns = Map.keys(record)
    values = Map.values(record)

    # XTDB uses "_id" (quoted) for the primary key in INSERT
    column_list = Enum.map_join(columns, ", ", &to_insert_column_name/1)
    placeholders = Enum.map_join(1..length(values), ", ", fn i -> "$#{i}" end)

    sql = "INSERT INTO #{quote_identifier(table)} (#{column_list}) VALUES (#{placeholders})"

    {sql, values}
  end

  @doc """
  Builds an INSERT statement with explicit valid time period.

  XTDB v2 uses _valid_from and _valid_to columns to specify the valid time range.

  ## Example SQL

      INSERT INTO users ("_id", name, "_valid_from", "_valid_to")
      VALUES ($1, $2, TIMESTAMP '2024-01-01T00:00:00Z', TIMESTAMP '2024-12-31T23:59:59Z')
  """
  @spec build_insert_with_valid_time(String.t(), map(), Ash.Resource.t(), DateTime.t(), DateTime.t()) ::
          {String.t(), list()}
  def build_insert_with_valid_time(table, record, _resource, %DateTime{} = from, %DateTime{} = to) do
    # Add _valid_from and _valid_to to the record
    record_with_valid_time =
      record
      |> Map.put(:_valid_from, from)
      |> Map.put(:_valid_to, to)

    columns = Map.keys(record_with_valid_time)
    values = Map.values(record_with_valid_time)

    column_list = Enum.map_join(columns, ", ", &to_insert_column_name/1)
    placeholders = Enum.map_join(1..length(values), ", ", fn i -> "$#{i}" end)

    sql = "INSERT INTO #{quote_identifier(table)} (#{column_list}) VALUES (#{placeholders})"

    {sql, values}
  end

  @doc """
  Builds an INSERT statement with explicit valid_from time.

  XTDB v2 uses _valid_from column to specify the start of valid time.
  The end of valid time will be "end of time" (infinity).

  ## Example SQL

      INSERT INTO users ("_id", name, "_valid_from")
      VALUES ($1, $2, TIMESTAMP '2024-06-01T00:00:00Z')
  """
  @spec build_insert_with_valid_from(String.t(), map(), Ash.Resource.t(), DateTime.t()) ::
          {String.t(), list()}
  def build_insert_with_valid_from(table, record, _resource, %DateTime{} = from) do
    # Add _valid_from to the record
    record_with_valid_from = Map.put(record, :_valid_from, from)

    columns = Map.keys(record_with_valid_from)
    values = Map.values(record_with_valid_from)

    column_list = Enum.map_join(columns, ", ", &to_insert_column_name/1)
    placeholders = Enum.map_join(1..length(values), ", ", fn i -> "$#{i}" end)

    sql = "INSERT INTO #{quote_identifier(table)} (#{column_list}) VALUES (#{placeholders})"

    {sql, values}
  end

  @doc """
  Builds an UPDATE statement.
  """
  @spec build_update(String.t(), map(), map(), list(), Ash.Resource.t()) :: {String.t(), list()}
  def build_update(table, pkey, changes, atomics, resource) do
    # Build SET clause for regular changes
    {set_clauses, set_params, next_idx} =
      changes
      |> Map.to_list()
      |> Enum.reduce({[], [], 1}, fn {col, val}, {clauses, params, idx} ->
        clause = "#{to_insert_column_name(col)} = $#{idx}"
        {[clause | clauses], [val | params], idx + 1}
      end)

    # Build SET clause for atomic updates (expressions)
    quoted_table = quote_identifier(table)
    {atomic_clauses, atomic_params, next_idx} =
      atomics
      |> Enum.reduce({[], [], next_idx}, fn {col, expr}, {clauses, params, idx} ->
        {expr_sql, expr_params, new_idx} = atomic_expression_to_sql(expr, resource, quoted_table, idx)
        clause = "#{to_insert_column_name(col)} = #{expr_sql}"
        {[clause | clauses], params ++ expr_params, new_idx}
      end)

    # Combine all SET clauses
    all_clauses = Enum.reverse(set_clauses) ++ Enum.reverse(atomic_clauses)
    set_clause = Enum.join(all_clauses, ", ")
    all_set_params = Enum.reverse(set_params) ++ atomic_params

    # Build WHERE clause for primary key
    pkey_attr = Ash.Resource.Info.primary_key(resource) |> List.first()
    pkey_value = Map.get(pkey, pkey_attr)

    # XTDB requires fully-qualified column in WHERE
    where_clause = "#{quoted_table}.\"_id\" = $#{next_idx}"
    where_params = [pkey_value]

    sql = "UPDATE #{quoted_table} SET #{set_clause} WHERE #{where_clause}"
    params = all_set_params ++ where_params

    {sql, params}
  end

  @doc """
  Builds an UPDATE statement with FOR PORTION OF VALID_TIME clause.

  This allows updating a record for only a portion of its valid time range.
  XTDB will automatically create separate versions for the affected and
  unaffected time periods.

  ## Example SQL

      UPDATE users FOR PORTION OF VALID_TIME
      FROM TIMESTAMP '2024-01-01T00:00:00Z' TO TIMESTAMP '2024-06-30T23:59:59Z'
      SET status = $1
      WHERE users.\"_id\" = $2
  """
  @spec build_update_for_portion(
          String.t(),
          map(),
          map(),
          Ash.Resource.t(),
          DateTime.t(),
          DateTime.t()
        ) :: {String.t(), list()}
  def build_update_for_portion(table, pkey, changes, resource, %DateTime{} = from, %DateTime{} = to) do
    # Build SET clause
    {set_clauses, set_params, next_idx} =
      changes
      |> Map.to_list()
      |> Enum.reduce({[], [], 1}, fn {col, val}, {clauses, params, idx} ->
        clause = "#{to_insert_column_name(col)} = $#{idx}"
        {[clause | clauses], [val | params], idx + 1}
      end)

    set_clause = set_clauses |> Enum.reverse() |> Enum.join(", ")
    set_params = Enum.reverse(set_params)

    # Build WHERE clause for primary key
    pkey_attr = Ash.Resource.Info.primary_key(resource) |> List.first()
    pkey_value = Map.get(pkey, pkey_attr)
    quoted_table = quote_identifier(table)
    where_clause = "#{quoted_table}.\"_id\" = $#{next_idx}"
    where_params = [pkey_value]

    # Build FOR PORTION OF clause
    portion_clause =
      "FOR PORTION OF VALID_TIME FROM TIMESTAMP '#{DateTime.to_iso8601(from)}' TO TIMESTAMP '#{DateTime.to_iso8601(to)}'"

    sql = "UPDATE #{quoted_table} #{portion_clause} SET #{set_clause} WHERE #{where_clause}"
    params = set_params ++ where_params

    {sql, params}
  end

  @doc """
  Builds a DELETE statement with FOR PORTION OF VALID_TIME clause.

  This allows deleting a record for only a portion of its valid time range.
  """
  @spec build_delete_for_portion(String.t(), map(), Ash.Resource.t(), DateTime.t(), DateTime.t()) ::
          {String.t(), list()}
  def build_delete_for_portion(table, pkey, resource, %DateTime{} = from, %DateTime{} = to) do
    pkey_attr = Ash.Resource.Info.primary_key(resource) |> List.first()
    pkey_value = Map.get(pkey, pkey_attr)

    portion_clause =
      "FOR PORTION OF VALID_TIME FROM TIMESTAMP '#{DateTime.to_iso8601(from)}' TO TIMESTAMP '#{DateTime.to_iso8601(to)}'"

    quoted_table = quote_identifier(table)
    sql = "DELETE FROM #{quoted_table} #{portion_clause} WHERE #{quoted_table}.\"_id\" = $1"

    {sql, [pkey_value]}
  end

  @doc """
  Builds a DELETE statement.
  """
  @spec build_delete(String.t(), map(), Ash.Resource.t()) :: {String.t(), list()}
  def build_delete(table, pkey, resource) do
    pkey_attr = Ash.Resource.Info.primary_key(resource) |> List.first()
    pkey_value = Map.get(pkey, pkey_attr)

    # XTDB requires fully-qualified column in WHERE
    quoted_table = quote_identifier(table)
    sql = "DELETE FROM #{quoted_table} WHERE #{quoted_table}.\"_id\" = $1"

    {sql, [pkey_value]}
  end

  # ============================================================================
  # Bulk Operations
  # ============================================================================

  @doc """
  Builds a bulk INSERT statement for multiple records.
  """
  @spec build_bulk_insert(String.t(), list(map()), Ash.Resource.t()) :: {String.t(), list()}
  def build_bulk_insert(table, records, _resource) when is_list(records) do
    # Get all unique columns from all records
    all_columns =
      records
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    column_list = Enum.map_join(all_columns, ", ", &to_insert_column_name/1)

    # Build values and params
    {value_clauses, params, _} =
      Enum.reduce(records, {[], [], 1}, fn record, {clauses, params, idx} ->
        {placeholders, new_params, new_idx} =
          Enum.reduce(all_columns, {[], [], idx}, fn col, {ph, p, i} ->
            value = Map.get(record, col)
            {["$#{i}" | ph], [value | p], i + 1}
          end)

        clause = "(#{placeholders |> Enum.reverse() |> Enum.join(", ")})"
        {[clause | clauses], params ++ Enum.reverse(new_params), new_idx}
      end)

    values = value_clauses |> Enum.reverse() |> Enum.join(", ")
    sql = "INSERT INTO #{quote_identifier(table)} (#{column_list}) VALUES #{values}"

    {sql, params}
  end

  @doc """
  Builds an UPDATE statement with WHERE clause from a query filter.
  Supports both regular changes and atomic updates (expressions evaluated in SQL).
  """
  @spec build_update_query(String.t(), map(), list(), t(), Ash.Resource.t()) :: {String.t(), list()}
  def build_update_query(table, changes, atomics, query, resource) do
    # Build SET clause for regular changes
    {set_clauses, set_params, next_idx} =
      changes
      |> Map.to_list()
      |> Enum.reduce({[], [], 1}, fn {col, val}, {clauses, params, idx} ->
        clause = "#{to_insert_column_name(col)} = $#{idx}"
        {[clause | clauses], [val | params], idx + 1}
      end)

    # Build SET clause for atomic updates (expressions)
    {atomic_clauses, atomic_params, next_idx} =
      atomics
      |> Enum.reduce({[], [], next_idx}, fn {col, expr}, {clauses, params, idx} ->
        {expr_sql, expr_params, new_idx} = atomic_expression_to_sql(expr, resource, table, idx)
        clause = "#{to_insert_column_name(col)} = #{expr_sql}"
        {[clause | clauses], params ++ expr_params, new_idx}
      end)

    # Combine all SET clauses
    all_clauses = Enum.reverse(set_clauses) ++ Enum.reverse(atomic_clauses)
    set_clause = Enum.join(all_clauses, ", ")
    all_set_params = Enum.reverse(set_params) ++ atomic_params

    # Build WHERE clause from filter
    # Use table name (not alias) for UPDATE statements since XTDB doesn't support aliases in UPDATE
    {where_clause, where_params} =
      case query.filter do
        nil ->
          {nil, []}

        filter ->
          {where_sql, filter_params, _joins} =
            Filter.to_sql(filter, resource, table, next_idx, table)

          {where_sql, filter_params}
      end

    quoted_table = quote_identifier(table)
    sql =
      if where_clause do
        "UPDATE #{quoted_table} SET #{set_clause} #{where_clause}"
      else
        "UPDATE #{quoted_table} SET #{set_clause}"
      end

    {sql, all_set_params ++ where_params}
  end

  # Convert an atomic expression to SQL for use in UPDATE SET clause
  defp atomic_expression_to_sql(expr, resource, table, start_idx) do
    state = %{
      resource: resource,
      param_idx: start_idx,
      params: [],
      joins: %{},
      join_counter: 0,
      table_alias: table
    }

    {sql, final_state} = Filter.expression_to_sql_for_test(expr, state)

    # Return the SQL, parameters, and next parameter index
    {sql, Enum.reverse(final_state.params), final_state.param_idx}
  end

  @doc """
  Builds a DELETE statement with WHERE clause from a query filter.
  """
  @spec build_destroy_query(String.t(), t(), Ash.Resource.t()) :: {String.t(), list()}
  def build_destroy_query(table, query, resource) do
    # Build WHERE clause from filter
    # Use table name (not alias) for DELETE statements since XTDB doesn't support aliases in DELETE
    {where_clause, where_params} =
      case query.filter do
        nil ->
          {nil, []}

        filter ->
          {where_sql, filter_params, _joins} = Filter.to_sql(filter, resource, table, 1, table)
          {where_sql, filter_params}
      end

    quoted_table = quote_identifier(table)
    sql =
      if where_clause do
        "DELETE FROM #{quoted_table} #{where_clause}"
      else
        "DELETE FROM #{quoted_table}"
      end

    {sql, where_params}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Build SELECT with optional window functions
  defp build_select_with_windows(%{window_functions: []} = query) do
    build_select(query)
  end

  defp build_select_with_windows(%{window_functions: window_functions} = query) do
    {base_select, params} = build_select(query)
    window_clauses = build_window_functions(window_functions)

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

  # Build window function clauses
  defp build_window_functions([]), do: nil

  defp build_window_functions(window_functions) do
    Enum.map_join(window_functions, ", ", fn wf ->
      func_name = window_function_name(wf.function)
      field_arg = if wf[:field], do: "#{@table_alias}.#{wf.field}", else: ""

      partition_clause =
        if wf[:partition_by] && wf.partition_by != [] do
          cols = Enum.map_join(wf.partition_by, ", ", &"#{@table_alias}.#{&1}")
          "PARTITION BY #{cols}"
        else
          ""
        end

      order_clause =
        if wf[:order_by] && wf.order_by != [] do
          cols =
            Enum.map_join(wf.order_by, ", ", fn
              {field, :asc} -> "#{@table_alias}.#{field} ASC"
              {field, :desc} -> "#{@table_alias}.#{field} DESC"
              field when is_atom(field) -> "#{@table_alias}.#{field}"
            end)

          "ORDER BY #{cols}"
        else
          ""
        end

      over_clause =
        [partition_clause, order_clause]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" ")

      "#{func_name}(#{field_arg}) OVER (#{over_clause}) AS \"#{wf.name}\""
    end)
  end

  defp window_function_name(:row_number), do: "ROW_NUMBER"
  defp window_function_name(:rank), do: "RANK"
  defp window_function_name(:dense_rank), do: "DENSE_RANK"
  defp window_function_name(:ntile), do: "NTILE"
  defp window_function_name(:lag), do: "LAG"
  defp window_function_name(:lead), do: "LEAD"
  defp window_function_name(:first_value), do: "FIRST_VALUE"
  defp window_function_name(:last_value), do: "LAST_VALUE"
  defp window_function_name(:sum), do: "SUM"
  defp window_function_name(:avg), do: "AVG"
  defp window_function_name(:min), do: "MIN"
  defp window_function_name(:max), do: "MAX"
  defp window_function_name(:count), do: "COUNT"
  defp window_function_name(func), do: String.upcase(to_string(func))

  # Build CTE (WITH) clauses
  defp build_cte_clause([]), do: nil
  defp build_cte_clause(nil), do: nil

  defp build_cte_clause(ctes) do
    cte_sql =
      Enum.map_join(ctes, ", ", fn %{name: name, query: query} ->
        {subquery, _params} = to_sql(query, :select)
        "#{name} AS (#{subquery})"
      end)

    "WITH #{cte_sql}"
  end

  # Build set operations (UNION, INTERSECT, EXCEPT)
  defp build_set_operation(nil), do: nil

  defp build_set_operation({:union, query}) do
    {subquery, _params} = to_sql(query, :select)
    "UNION #{subquery}"
  end

  defp build_set_operation({:union_all, query}) do
    {subquery, _params} = to_sql(query, :select)
    "UNION ALL #{subquery}"
  end

  defp build_set_operation({:intersect, query}) do
    {subquery, _params} = to_sql(query, :select)
    "INTERSECT #{subquery}"
  end

  defp build_set_operation({:except, query}) do
    {subquery, _params} = to_sql(query, :select)
    "EXCEPT #{subquery}"
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

  defp build_distinct_on_query(%{distinct: distinct, sort: sort, resource: resource, table: table} = query) do
    # Build the inner query without distinct (we handle it via ROW_NUMBER)
    inner_query = %{query | distinct: nil}

    # Get columns for the inner SELECT
    columns = get_all_columns(resource, table)
    calc_sql = build_calculation_selects(inner_query)

    # Build PARTITION BY clause from distinct fields
    partition_cols =
      distinct
      |> Enum.map(fn
        {field, _direction} -> to_select_column_name(field, table)
        field when is_atom(field) -> to_select_column_name(field, table)
      end)
      |> Enum.join(", ")

    # Build aggregate joins for both sort and filter
    {agg_join_clauses, agg_alias_map} = build_aggregate_joins(inner_query)

    # Build ORDER BY for the window function (use sort if provided, otherwise distinct order)
    window_order_sql =
      if sort && sort != [] do
        build_order_for_window(sort, resource, inner_query, agg_alias_map)
      else
        # Default to ordering by distinct fields
        distinct
        |> Enum.map(fn
          {field, direction} -> "#{to_select_column_name(field, table)} #{direction_to_sql(direction)}"
          field -> "#{to_select_column_name(field, table)} ASC"
        end)
        |> Enum.join(", ")
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
    sort
    |> Enum.map(fn {field, direction} ->
      expr_sql = sort_field_to_sql(field, resource, query, agg_alias_map)
      "#{expr_sql}#{direction_to_sql(direction)}"
    end)
    |> Enum.join(", ")
  end

  # Build ORDER BY for the outer query (using sub. alias)
  defp build_order_for_outer_distinct(sort, resource, _query) do
    clauses =
      sort
      |> Enum.map(fn {field, direction} ->
        col_name = get_sort_field_name(field, resource)
        "sub.#{quote_identifier(col_name)}#{direction_to_sql(direction)}"
      end)
      |> Enum.join(", ")

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
      |> Enum.map(fn
        :id -> "sub.\"_id\" AS \"_id\""
        :_id -> "sub.\"_id\""
        attr -> "sub.#{quote_identifier(Atom.to_string(attr))}"
      end)
      |> Enum.join(", ")

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

  defp build_select(%{select: select, distinct: nil, table: table} = query) when is_list(select) do
    columns =
      select
      |> ensure_id_column()
      |> Enum.map_join(", ", &to_select_column_name(&1, table))

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
      case Filter.expression_to_sql_for_test(expression, state) do
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

  defp get_all_columns(resource, table) do
    attrs = Ash.Resource.Info.attributes(resource)

    columns =
      attrs
      |> Enum.map(& &1.name)
      |> ensure_id_column()
      |> Enum.map_join(", ", &to_select_column_name(&1, table))

    columns
  end

  defp ensure_id_column(columns) do
    if :id in columns || :_id in columns do
      columns
    else
      [:_id | columns]
    end
  end

  defp build_from(%{table: table, context: context}) do
    # XTDB temporal syntax: FROM table FOR temporal_clause AS alias
    # e.g., FROM users FOR VALID_TIME AS OF TIMESTAMP '...' AS t
    temporal = get_in(context || %{}, [:temporal]) || %{}

    valid_time_clause = build_temporal_clause("VALID_TIME", Map.get(temporal, :valid_time))
    system_time_clause = build_temporal_clause("SYSTEM_TIME", Map.get(temporal, :system_time))

    temporal_clauses =
      [valid_time_clause, system_time_clause]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

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

  defp build_temporal_clause(_type, nil), do: nil

  defp build_temporal_clause(type, :all) do
    "FOR ALL #{type}"
  end

  defp build_temporal_clause(type, {:as_of, %DateTime{} = timestamp}) do
    "FOR #{type} AS OF TIMESTAMP '#{DateTime.to_iso8601(timestamp)}'"
  end

  defp build_temporal_clause(type, {:between, %DateTime{} = from, %DateTime{} = to}) do
    "FOR #{type} BETWEEN TIMESTAMP '#{DateTime.to_iso8601(from)}' AND TIMESTAMP '#{DateTime.to_iso8601(to)}'"
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
          {join_sql, agg_col} = build_aggregate_subquery_join(aggregate, resource, table, agg_alias)
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
      {%Ash.Query.Aggregate{}, _direction} -> true
      {field, _direction} when is_atom(field) ->
        not is_nil(Ash.Resource.Info.aggregate(resource, field))
      _ -> false
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
      %Ash.Query.Aggregate{} = agg -> agg
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
    source_col = if source_attr == :id, do: "\"_id\"", else: quote_identifier(Atom.to_string(source_attr))

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

    case Filter.expression_to_sql_for_test(expression, state) do
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

  # For INSERT statements - XTDB uses "_id" (quoted) for primary key
  defp to_insert_column_name(:id), do: "\"_id\""
  defp to_insert_column_name(:_id), do: "\"_id\""
  defp to_insert_column_name(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp to_insert_column_name(string) when is_binary(string), do: string

  # For SELECT statements - uses table.column format with "_id" quoted
  defp to_select_column_name(:id, _table), do: "#{@table_alias}.\"_id\""
  defp to_select_column_name(:_id, _table), do: "#{@table_alias}.\"_id\""

  defp to_select_column_name(atom, _table) when is_atom(atom) do
    "#{@table_alias}.#{Atom.to_string(atom)}"
  end

  defp to_select_column_name(string, _table) when is_binary(string) do
    "#{@table_alias}.#{string}"
  end

  @doc """
  Inlines parameters into SQL by replacing $1, $2, etc. with actual values.

  We use the simple query protocol which doesn't support
  parameterized queries, so we need to inline values directly into the SQL.
  """
  @spec inline_params(String.t(), list()) :: String.t()
  def inline_params(sql, []), do: sql

  def inline_params(sql, params) do
    # Replace parameters in reverse order to avoid $1 matching $10, $11, etc.
    params
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.reduce(sql, fn {value, idx}, acc ->
      placeholder = "$#{idx}"
      escaped = escape_value(value)
      String.replace(acc, placeholder, escaped)
    end)
  end

  @doc """
  Escapes a value for use in XTDB SQL.

  Handles various Elixir types and converts them to their SQL representation.
  """
  @spec escape_value(term()) :: String.t()
  def escape_value(nil), do: "NULL"
  def escape_value(true), do: "TRUE"
  def escape_value(false), do: "FALSE"
  def escape_value(value) when is_integer(value), do: Integer.to_string(value)
  def escape_value(value) when is_float(value), do: Float.to_string(value)

  def escape_value(%DateTime{} = dt) do
    "TIMESTAMP '#{DateTime.to_iso8601(dt)}'"
  end

  def escape_value(%Date{} = date) do
    "DATE '#{Date.to_iso8601(date)}'"
  end

  def escape_value(%Time{} = time) do
    "TIME '#{Time.to_iso8601(time)}'"
  end

  def escape_value(%Decimal{} = decimal) do
    Decimal.to_string(decimal)
  end

  # Interval type - XTDB uses DURATION 'P...' syntax
  def escape_value(%AshXTDB.Types.Interval{} = interval) do
    iso = AshXTDB.Types.Interval.to_iso(interval)
    "DURATION '#{iso}'"
  end

  # Period type - XTDB uses PERIOD(TIMESTAMP, TIMESTAMP) syntax
  def escape_value(%AshXTDB.Types.Period{from: from, to: to}) do
    "PERIOD(TIMESTAMP '#{DateTime.to_iso8601(from)}', TIMESTAMP '#{DateTime.to_iso8601(to)}')"
  end

  def escape_value(value) when is_atom(value) do
    escape_value(Atom.to_string(value))
  end

  # Binary/string values - handle last to allow structs to match first
  def escape_value(value) when is_binary(value) do
    # Escape single quotes by doubling them
    escaped = String.replace(value, "'", "''")
    "'#{escaped}'"
  end

  def escape_value(value) when is_list(value) do
    elements = Enum.map_join(value, ", ", &escape_value/1)
    "ARRAY[#{elements}]"
  end

  # Handle structs (custom Ash types, etc.) by converting to plain map
  # This must come before the is_map clause since structs are also maps
  def escape_value(value) when is_struct(value) do
    # Convert struct to plain map, removing the __struct__ key
    plain_map =
      value
      |> Map.from_struct()
      |> convert_nested_structs()

    escape_value(plain_map)
  end

  def escape_value(value) when is_map(value) do
    # Convert maps to JSON for XTDB
    plain_map = convert_nested_structs(value)
    json = Jason.encode!(plain_map)
    escaped = String.replace(json, "'", "''")
    "'#{escaped}'"
  end

  # Recursively convert any nested structs to plain maps
  defp convert_nested_structs(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_struct(value) ->
        {key, value |> Map.from_struct() |> convert_nested_structs()}

      {key, value} when is_map(value) ->
        {key, convert_nested_structs(value)}

      {key, value} when is_list(value) ->
        {key, Enum.map(value, &convert_nested_value/1)}

      {key, value} ->
        {key, value}
    end)
  end

  defp convert_nested_value(value) when is_struct(value) do
    value |> Map.from_struct() |> convert_nested_structs()
  end

  defp convert_nested_value(value) when is_map(value) do
    convert_nested_structs(value)
  end

  defp convert_nested_value(value) when is_list(value) do
    Enum.map(value, &convert_nested_value/1)
  end

  defp convert_nested_value(value), do: value

  # ============================================================================
  # SQL Injection Prevention
  # ============================================================================

  @doc """
  Quotes a SQL identifier (table name, column name) to prevent SQL injection.

  Identifiers are wrapped in double quotes and any embedded double quotes
  are escaped by doubling them.

  ## Examples

      iex> AshXTDB.SQL.quote_identifier("users")
      "\"users\""

      iex> AshXTDB.SQL.quote_identifier("user\"table")
      "\"user\"\"table\""
  """
  @spec quote_identifier(String.t() | atom()) :: String.t()
  def quote_identifier(identifier) when is_atom(identifier) do
    quote_identifier(Atom.to_string(identifier))
  end

  def quote_identifier(identifier) when is_binary(identifier) do
    # Escape any embedded double quotes by doubling them
    escaped = String.replace(identifier, "\"", "\"\"")
    "\"#{escaped}\""
  end

  @doc """
  Validates that an identifier contains only safe characters.

  Raises ArgumentError if the identifier contains potentially dangerous characters.
  This is a defense-in-depth measure in addition to quoting.

  Allowed: letters, numbers, underscores, and dots (for schema.table notation)
  """
  @spec validate_identifier!(String.t() | atom()) :: :ok
  def validate_identifier!(identifier) when is_atom(identifier) do
    validate_identifier!(Atom.to_string(identifier))
  end

  def validate_identifier!(identifier) when is_binary(identifier) do
    # Allow alphanumeric, underscores, and dots for schema qualification
    if Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*$/, identifier) do
      :ok
    else
      raise ArgumentError,
            "Invalid SQL identifier: #{inspect(identifier)}. " <>
              "Identifiers must start with a letter or underscore and contain only " <>
              "alphanumeric characters, underscores, and dots."
    end
  end

  @doc """
  Safely quotes an identifier after validation.

  This combines validation and quoting for maximum safety.
  """
  @spec safe_identifier(String.t() | atom()) :: String.t()
  def safe_identifier(identifier) do
    validate_identifier!(identifier)
    quote_identifier(identifier)
  end
end
