# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Query do
  @moduledoc """
  Represents an XTDB query and provides SQL generation.

  XTDB has specific SQL requirements:
  - SELECT requires fully-qualified column names (table.column or alias.column)
  - INSERT uses `_id` for the primary key column
  - UPDATE/DELETE use `"_id"` (quoted) in WHERE clauses
  - SELECT * doesn't work, must specify columns explicitly
  """

  alias AshXTDB.Query.Filter
  alias AshXTDB.Query.Nested

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
    {where_clause, where_params, joins} = build_where(query)
    join_clauses = build_joins(joins)
    order_clause = build_order(query)
    limit_clause = build_limit(query)
    offset_clause = build_offset(query)

    # SQL:2011 order: OFFSET comes before FETCH
    sql =
      [
        select_clause,
        from_clause,
        join_clauses,
        where_clause,
        order_clause,
        offset_clause,
        limit_clause
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    {sql, select_params ++ where_params}
  end

  def to_sql(%__MODULE__{} = query, :select) do
    cte_clause = build_cte_clause(query.ctes)
    {select_clause, _} = build_select_with_windows(query)
    from_clause = build_from(query)
    {where_clause, params, joins} = build_where(query)
    join_clauses = build_joins(joins)
    order_clause = build_order(query)
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
      |> AshXTDB.Query.add_window_function(%{
        name: :row_num,
        function: :row_number,
        partition_by: [:organization_id],
        order_by: [{:created_at, :desc}]
      })

      query
      |> AshXTDB.Query.add_window_function(%{
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

      subquery = %AshXTDB.Query{...}
      query
      |> AshXTDB.Query.add_cte("active_users", subquery)
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

    sql = "INSERT INTO #{table} (#{column_list}) VALUES (#{placeholders})"

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

    sql = "INSERT INTO #{table} (#{column_list}) VALUES (#{placeholders})"

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

    sql = "INSERT INTO #{table} (#{column_list}) VALUES (#{placeholders})"

    {sql, values}
  end

  @doc """
  Builds an UPDATE statement.
  """
  @spec build_update(String.t(), map(), map(), Ash.Resource.t()) :: {String.t(), list()}
  def build_update(table, pkey, changes, resource) do
    # Build SET clause - XTDB UPDATE doesn't need table alias for SET columns
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

    # XTDB requires fully-qualified column in WHERE
    where_clause = "#{table}.\"_id\" = $#{next_idx}"
    where_params = [pkey_value]

    sql = "UPDATE #{table} SET #{set_clause} WHERE #{where_clause}"
    params = set_params ++ where_params

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
    where_clause = "#{table}.\"_id\" = $#{next_idx}"
    where_params = [pkey_value]

    # Build FOR PORTION OF clause
    portion_clause =
      "FOR PORTION OF VALID_TIME FROM TIMESTAMP '#{DateTime.to_iso8601(from)}' TO TIMESTAMP '#{DateTime.to_iso8601(to)}'"

    sql = "UPDATE #{table} #{portion_clause} SET #{set_clause} WHERE #{where_clause}"
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

    sql = "DELETE FROM #{table} #{portion_clause} WHERE #{table}.\"_id\" = $1"

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
    sql = "DELETE FROM #{table} WHERE #{table}.\"_id\" = $1"

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
    sql = "INSERT INTO #{table} (#{column_list}) VALUES #{values}"

    {sql, params}
  end

  @doc """
  Builds an UPDATE statement with WHERE clause from a query filter.
  """
  @spec build_update_query(String.t(), map(), t(), Ash.Resource.t()) :: {String.t(), list()}
  def build_update_query(table, changes, query, resource) do
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

    sql =
      if where_clause do
        "UPDATE #{table} SET #{set_clause} #{where_clause}"
      else
        "UPDATE #{table} SET #{set_clause}"
      end

    {sql, set_params ++ where_params}
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

    sql =
      if where_clause do
        "DELETE FROM #{table} #{where_clause}"
      else
        "DELETE FROM #{table}"
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

  defp build_select(%{select: nil, distinct: nil, resource: resource, table: table}) do
    # XTDB requires explicit column list with table alias
    columns = get_all_columns(resource, table)
    {"SELECT #{columns}", []}
  end

  defp build_select(%{select: nil, distinct: distinct, table: table}) when is_list(distinct) do
    columns = Enum.map_join(distinct, ", ", &to_select_column_name(&1, table))
    {"SELECT DISTINCT #{columns}", []}
  end

  defp build_select(%{select: select, distinct: nil, table: table}) when is_list(select) do
    columns =
      select
      |> ensure_id_column()
      |> Enum.map_join(", ", &to_select_column_name(&1, table))

    {"SELECT #{columns}", []}
  end

  defp build_select(%{select: select, distinct: distinct, table: table})
       when is_list(select) and is_list(distinct) do
    columns =
      select
      |> ensure_id_column()
      |> Enum.map_join(", ", &to_select_column_name(&1, table))

    {"SELECT DISTINCT #{columns}", []}
  end

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

    if temporal_clauses == "" do
      "FROM #{table} #{@table_alias}"
    else
      "FROM #{table} #{temporal_clauses} #{@table_alias}"
    end
  end

  defp build_from(%{table: table}) do
    # Use table alias for XTDB (fallback when no context)
    "FROM #{table} #{@table_alias}"
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

  defp build_where(%{filter: nil}) do
    {nil, [], %{}}
  end

  defp build_where(%{filter: filter, resource: resource, table: table}) do
    Filter.to_sql(filter, resource, table)
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
      "LEFT JOIN #{join.table} #{join.alias} ON #{source_col} = #{dest_col}"
    end)
  end

  defp format_join_column(alias, :id), do: "#{alias}.\"_id\""
  defp format_join_column(alias, :_id), do: "#{alias}.\"_id\""
  defp format_join_column(alias, attr), do: "#{alias}.#{Atom.to_string(attr)}"

  defp build_order(%{sort: nil}), do: nil
  defp build_order(%{sort: []}), do: nil

  defp build_order(%{sort: sort, table: table}) do
    clauses =
      Enum.map_join(sort, ", ", fn
        {field, :asc} -> "#{to_select_column_name(field, table)} ASC"
        {field, :desc} -> "#{to_select_column_name(field, table)} DESC"
        {field, :asc_nils_first} -> "#{to_select_column_name(field, table)} ASC NULLS FIRST"
        {field, :asc_nils_last} -> "#{to_select_column_name(field, table)} ASC NULLS LAST"
        {field, :desc_nils_first} -> "#{to_select_column_name(field, table)} DESC NULLS FIRST"
        {field, :desc_nils_last} -> "#{to_select_column_name(field, table)} DESC NULLS LAST"
      end)

    "ORDER BY #{clauses}"
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

  def escape_value(value) when is_map(value) do
    # Convert maps to JSON for XTDB
    json = Jason.encode!(value)
    escaped = String.replace(json, "'", "''")
    "'#{escaped}'"
  end
end
