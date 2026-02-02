# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SQL.Nested do
  @moduledoc """
  Builds XTDB NEST_MANY and NEST_ONE subqueries for optimized relationship loading.

  XTDB supports correlated subqueries that return nested JSON structures:

      SELECT p._id, p.name,
             NEST_MANY(SELECT c._id, c.title
                       FROM posts c
                       WHERE c.user_id = p._id
                       ORDER BY c.title
                       FETCH FIRST 5 ROWS ONLY) AS posts
      FROM users p
      WHERE p._id IN ('id1', 'id2')

  This allows loading relationships with limits/offsets in a single query
  instead of N+1 iteration, returning results like:

      [
        %{_id: "user1", name: "Alice", posts: [%{_id: "p1", title: "Post 1"}, ...]},
        %{_id: "user2", name: "Bob", posts: [%{_id: "p2", title: "Post 2"}, ...]}
      ]

  ## Usage

  Use `build_nested_select/2` to generate the SELECT clause including nested subqueries:

      nested = %{
        name: :posts,
        type: :nest_many,
        resource: Post,
        table: "posts",
        correlation: {:id, :user_id},  # parent.id = child.user_id
        select: [:id, :title],
        limit: 5
      }

      {select_sql, params} = Nested.build_nested_select(query, [nested])
  """

  alias AshXTDB.SQL.Filter

  @parent_alias "t"

  @doc """
  Builds a SELECT clause with nested subqueries.

  Returns {select_sql, params} where select_sql includes both regular columns
  and NEST_MANY/NEST_ONE subqueries.
  """
  @spec build_nested_select(AshXTDB.SQL.t(), list(map())) :: {String.t(), list()}
  def build_nested_select(query, nested_subqueries) do
    # Build regular column selections
    regular_columns = build_regular_columns(query)

    # Build nested subquery expressions
    {nested_columns, params} = build_nested_columns(nested_subqueries, query)

    all_columns =
      if nested_columns == "" do
        regular_columns
      else
        "#{regular_columns}, #{nested_columns}"
      end

    {"SELECT #{all_columns}", params}
  end

  @doc """
  Builds a single nested subquery SQL fragment.

  ## Options

    * `:name` - The alias for the nested result (required)
    * `:type` - `:nest_many` or `:nest_one` (required)
    * `:resource` - The Ash resource for the nested table (required)
    * `:table` - The table name (required)
    * `:correlation` - Tuple of {parent_attr, child_attr} for the correlation (required)
    * `:select` - List of attributes to select (optional, defaults to all)
    * `:filter` - Additional filter for the subquery (optional)
    * `:sort` - Sort order (optional)
    * `:limit` - Limit for nest_many (optional)
    * `:offset` - Offset for nest_many (optional)

  """
  @spec build_subquery(map(), String.t()) :: {String.t(), list()}
  def build_subquery(opts, parent_alias \\ @parent_alias) do
    nest_func = if opts.type == :nest_one, do: "NEST_ONE", else: "NEST_MANY"
    subquery_alias = "n"

    # Build SELECT columns for the subquery
    select_clause = build_subquery_select(opts, subquery_alias)

    # Build FROM clause
    from_clause = "FROM #{opts.table} #{subquery_alias}"

    # Build WHERE clause with correlation
    {correlation_condition, correlation_params} =
      build_correlation_condition(opts.correlation, parent_alias, subquery_alias)

    # Add any additional filter conditions
    {filter_conditions, filter_params} =
      case Map.get(opts, :filter) do
        nil ->
          {[], []}

        filter ->
          {filter_sql, f_params, _joins} =
            Filter.to_sql(filter, opts.resource, opts.table, 1, subquery_alias)

          conditions =
            if filter_sql do
              String.replace_prefix(filter_sql, "WHERE ", "")
            else
              nil
            end

          {if(conditions, do: [conditions], else: []), f_params}
      end

    params = correlation_params ++ filter_params
    all_conditions = [correlation_condition | filter_conditions]
    where_clause = "WHERE #{Enum.join(all_conditions, " AND ")}"

    # Build ORDER BY clause
    order_clause = build_subquery_order(opts, subquery_alias)

    # Build LIMIT/OFFSET clauses
    offset_clause = build_subquery_offset(opts)
    limit_clause = build_subquery_limit(opts)

    # Assemble the subquery
    subquery_parts =
      [
        select_clause,
        from_clause,
        where_clause,
        order_clause,
        offset_clause,
        limit_clause
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    sql = "#{nest_func}(#{subquery_parts}) AS \"#{opts.name}\""

    {sql, params}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Many-to-many correlation via through table subquery:
  # child.id IN (SELECT through.dest_id FROM through WHERE through.source_id = parent.id)
  defp build_correlation_condition(
         {:through_subquery,
          %{
            through_table: through_table,
            source_attr_on_join: source_attr_on_join,
            dest_attr_on_join: dest_attr_on_join,
            destination_attribute: destination_attribute,
            source_attribute: source_attribute
          }},
         parent_alias,
         subquery_alias
       ) do
    # Build: n.id IN (SELECT pt.tag_id FROM post_tags pt WHERE pt.post_id = t._id)
    dest_col = format_column(subquery_alias, destination_attribute)
    parent_col = format_column(parent_alias, source_attribute)

    through_alias = "th"
    through_dest_col = format_column(through_alias, dest_attr_on_join)
    through_source_col = format_column(through_alias, source_attr_on_join)

    quoted_through_table = AshXTDB.SQL.quote_identifier(through_table)
    subquery =
      "#{dest_col} IN (SELECT #{through_dest_col} FROM #{quoted_through_table} #{through_alias} WHERE #{through_source_col} = #{parent_col})"

    {subquery, []}
  end

  # Simple correlation: parent.attr = child.attr
  defp build_correlation_condition({parent_attr, child_attr}, parent_alias, subquery_alias) do
    parent_col = format_column(parent_alias, parent_attr)
    child_col = format_column(subquery_alias, child_attr)
    {"#{child_col} = #{parent_col}", []}
  end

  defp build_regular_columns(query) do
    resource = query.resource

    columns =
      case query.select do
        nil ->
          resource
          |> Ash.Resource.Info.attributes()
          |> Enum.map(& &1.name)

        select when is_list(select) ->
          select
      end

    columns
    |> ensure_id_column()
    |> Enum.map_join(", ", &format_column(@parent_alias, &1))
  end

  defp build_nested_columns([], _query), do: {"", []}

  defp build_nested_columns(nested_subqueries, _query) do
    {sqls, all_params} =
      Enum.reduce(nested_subqueries, {[], []}, fn nested, {sqls, params} ->
        {sql, nested_params} = build_subquery(nested)
        {[sql | sqls], params ++ nested_params}
      end)

    {sqls |> Enum.reverse() |> Enum.join(", "), all_params}
  end

  defp build_subquery_select(opts, subquery_alias) do
    columns =
      case Map.get(opts, :select) do
        nil ->
          opts.resource
          |> Ash.Resource.Info.attributes()
          |> Enum.map(& &1.name)

        select when is_list(select) ->
          select
      end

    column_list =
      columns
      |> ensure_id_column()
      |> Enum.map_join(", ", &format_column(subquery_alias, &1))

    "SELECT #{column_list}"
  end

  defp build_subquery_order(%{sort: nil}, _alias), do: nil
  defp build_subquery_order(%{sort: []}, _alias), do: nil

  defp build_subquery_order(%{sort: sort}, subquery_alias) do
    clauses =
      Enum.map_join(sort, ", ", fn
        {field, :asc} -> "#{format_column(subquery_alias, field)} ASC"
        {field, :desc} -> "#{format_column(subquery_alias, field)} DESC"
        {field, :asc_nils_first} -> "#{format_column(subquery_alias, field)} ASC NULLS FIRST"
        {field, :asc_nils_last} -> "#{format_column(subquery_alias, field)} ASC NULLS LAST"
        {field, :desc_nils_first} -> "#{format_column(subquery_alias, field)} DESC NULLS FIRST"
        {field, :desc_nils_last} -> "#{format_column(subquery_alias, field)} DESC NULLS LAST"
      end)

    "ORDER BY #{clauses}"
  end

  defp build_subquery_order(_, _), do: nil

  defp build_subquery_limit(%{limit: nil}), do: nil
  defp build_subquery_limit(%{limit: limit}), do: "FETCH FIRST #{limit} ROWS ONLY"
  defp build_subquery_limit(_), do: nil

  defp build_subquery_offset(%{offset: nil}), do: nil
  defp build_subquery_offset(%{offset: 0}), do: nil
  defp build_subquery_offset(%{offset: offset}), do: "OFFSET #{offset} ROWS"
  defp build_subquery_offset(_), do: nil

  defp format_column(table_alias, :id), do: "#{table_alias}.\"_id\""
  defp format_column(table_alias, :_id), do: "#{table_alias}.\"_id\""

  defp format_column(table_alias, attr) when is_atom(attr) do
    quoted_col = AshXTDB.SQL.quote_identifier(Atom.to_string(attr))
    "#{table_alias}.#{quoted_col}"
  end

  defp ensure_id_column(columns) do
    if :id in columns || :_id in columns do
      columns
    else
      [:_id | columns]
    end
  end
end
