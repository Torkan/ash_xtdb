# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Query.Filter do
  @moduledoc """
  Translates Ash filters to SQL WHERE clauses.

  XTDB requires fully-qualified column names in WHERE clauses.
  Supports filtering through relationships via JOINs.
  """

  alias AshXTDB.DataLayer.Info

  # Default table alias used in queries for the main table
  @default_table_alias "t"

  @doc """
  Converts an Ash filter to a SQL WHERE clause with parameters.

  Returns `{where_clause, params, joins}` where joins is a map of
  relationship paths to join info needed for the query.

  Options:
  - start_param_idx (default 1): Starting parameter index for when
    the WHERE clause needs to continue numbering from earlier parameters
    (e.g., in UPDATE SET clause).
  - table_alias (default "t"): Table alias to use for column references.
    For UPDATE/DELETE statements, pass the table name directly since
    XTDB doesn't support aliases in those contexts.
  """
  @spec to_sql(Ash.Filter.t() | nil, Ash.Resource.t(), String.t(), pos_integer(), String.t()) ::
          {String.t() | nil, list(), map()}
  def to_sql(filter, resource, table, start_param_idx \\ 1, table_alias \\ @default_table_alias)

  def to_sql(nil, _resource, _table, _start_idx, _table_alias), do: {nil, [], %{}}

  def to_sql(%Ash.Filter{expression: nil}, _resource, _table, _start_idx, _table_alias),
    do: {nil, [], %{}}

  def to_sql(%Ash.Filter{expression: expression}, resource, _table, start_param_idx, table_alias) do
    state = %{
      resource: resource,
      param_idx: start_param_idx,
      params: [],
      joins: %{},
      join_counter: 0,
      table_alias: table_alias
    }

    {sql, state} = expression_to_sql(expression, state)

    if sql && sql != "" do
      {"WHERE #{sql}", Enum.reverse(state.params), state.joins}
    else
      {nil, [], %{}}
    end
  end

  # ============================================================================
  # Expression Translation
  # ============================================================================

  defp expression_to_sql(%Ash.Query.BooleanExpression{op: :and, left: left, right: right}, state) do
    {left_sql, state} = expression_to_sql(left, state)
    {right_sql, state} = expression_to_sql(right, state)

    cond do
      is_nil(left_sql) -> {right_sql, state}
      is_nil(right_sql) -> {left_sql, state}
      true -> {"(#{left_sql} AND #{right_sql})", state}
    end
  end

  defp expression_to_sql(%Ash.Query.BooleanExpression{op: :or, left: left, right: right}, state) do
    {left_sql, state} = expression_to_sql(left, state)
    {right_sql, state} = expression_to_sql(right, state)

    cond do
      is_nil(left_sql) -> {right_sql, state}
      is_nil(right_sql) -> {left_sql, state}
      true -> {"(#{left_sql} OR #{right_sql})", state}
    end
  end

  defp expression_to_sql(%Ash.Query.Not{expression: expr}, state) do
    {sql, state} = expression_to_sql(expr, state)

    if sql do
      {"NOT (#{sql})", state}
    else
      {nil, state}
    end
  end

  defp expression_to_sql(%Ash.Query.Operator.Eq{left: left, right: right}, state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {right_sql, state} = ref_or_value_to_sql(right, state)

    sql =
      case {left_sql, right_sql} do
        {_, "NULL"} -> "#{left_sql} IS NULL"
        {"NULL", _} -> "#{right_sql} IS NULL"
        _ -> "#{left_sql} = #{right_sql}"
      end

    {sql, state}
  end

  defp expression_to_sql(%Ash.Query.Operator.NotEq{left: left, right: right}, state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {right_sql, state} = ref_or_value_to_sql(right, state)

    sql =
      case {left_sql, right_sql} do
        {_, "NULL"} -> "#{left_sql} IS NOT NULL"
        {"NULL", _} -> "#{right_sql} IS NOT NULL"
        _ -> "#{left_sql} != #{right_sql}"
      end

    {sql, state}
  end

  defp expression_to_sql(%Ash.Query.Operator.LessThan{left: left, right: right}, state) do
    binary_op_to_sql("<", left, right, state)
  end

  defp expression_to_sql(%Ash.Query.Operator.LessThanOrEqual{left: left, right: right}, state) do
    binary_op_to_sql("<=", left, right, state)
  end

  defp expression_to_sql(%Ash.Query.Operator.GreaterThan{left: left, right: right}, state) do
    binary_op_to_sql(">", left, right, state)
  end

  defp expression_to_sql(%Ash.Query.Operator.GreaterThanOrEqual{left: left, right: right}, state) do
    binary_op_to_sql(">=", left, right, state)
  end

  defp expression_to_sql(%Ash.Query.Operator.In{left: left, right: right}, state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)

    case right do
      %Ash.Query.Ref{} = ref ->
        {right_sql, state} = ref_or_value_to_sql(ref, state)
        {"#{left_sql} = ANY(#{right_sql})", state}

      %MapSet{} = set ->
        values = MapSet.to_list(set)
        in_clause_to_sql(left_sql, values, state)

      values when is_list(values) ->
        in_clause_to_sql(left_sql, values, state)
    end
  end

  defp expression_to_sql(%Ash.Query.Operator.IsNil{left: left, right: true}, state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {"#{left_sql} IS NULL", state}
  end

  defp expression_to_sql(%Ash.Query.Operator.IsNil{left: left, right: false}, state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {"#{left_sql} IS NOT NULL", state}
  end

  # Note: BETWEEN is not a separate Ash operator. Instead, Ash represents
  # BETWEEN-style queries as compound expressions (age >= 18 and age <= 65).
  # The existing GreaterThanOrEqual and LessThanOrEqual operators handle this.

  # String operators - Contains (LIKE with wildcards on both sides)
  # This handles Ash's contains(field, "substring") function
  defp expression_to_sql(%Ash.Query.Function.Contains{arguments: [left, right]}, state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {right_sql, state} = ref_or_value_to_sql(right, state)
    {"#{left_sql} LIKE '%' || #{right_sql} || '%'", state}
  end

  # Catch-all for unhandled expressions
  defp expression_to_sql(expr, state) do
    require Logger
    Logger.warning("Unhandled filter expression: #{inspect(expr)}")
    {nil, state}
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp binary_op_to_sql(op, left, right, state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {right_sql, state} = ref_or_value_to_sql(right, state)
    {"#{left_sql} #{op} #{right_sql}", state}
  end

  defp in_clause_to_sql(left_sql, values, state) do
    {placeholders, state} =
      Enum.reduce(values, {[], state}, fn value, {phs, st} ->
        placeholder = "$#{st.param_idx}"
        st = %{st | param_idx: st.param_idx + 1, params: [value | st.params]}
        {[placeholder | phs], st}
      end)

    placeholders_str = placeholders |> Enum.reverse() |> Enum.join(", ")
    {"#{left_sql} IN (#{placeholders_str})", state}
  end

  # Handle Refs with relationship paths (for JOINs)
  defp ref_or_value_to_sql(
         %Ash.Query.Ref{relationship_path: path, attribute: attr},
         state
       )
       when path != [] do
    # Need to add JOIN(s) for this relationship path
    {table_alias, state} = ensure_join(path, state)
    attr_name = get_attr_name(attr)
    column = column_name(attr_name, table_alias)
    {column, state}
  end

  defp ref_or_value_to_sql(%Ash.Query.Ref{attribute: %{name: name}}, state) do
    column = column_name(name, state.table_alias)
    {column, state}
  end

  defp ref_or_value_to_sql(%Ash.Query.Ref{attribute: name}, state) when is_atom(name) do
    column = column_name(name, state.table_alias)
    {column, state}
  end

  defp ref_or_value_to_sql(nil, state) do
    {"NULL", state}
  end

  defp ref_or_value_to_sql(value, state) do
    placeholder = "$#{state.param_idx}"
    state = %{state | param_idx: state.param_idx + 1, params: [value | state.params]}
    {placeholder, state}
  end

  # Ensure a join exists for the given relationship path
  defp ensure_join(path, state) do
    case Map.get(state.joins, path) do
      nil ->
        # Need to create the join
        {join_info, state} = build_join_chain(path, state)
        {join_info.alias, state}

      join_info ->
        {join_info.alias, state}
    end
  end

  # Build join chain for a relationship path
  defp build_join_chain(path, state) do
    build_join_chain(path, [], state.resource, state.table_alias, state)
  end

  defp build_join_chain([], _built_path, _current_resource, current_alias, state) do
    # Return the current alias - this shouldn't happen with non-empty paths
    {%{alias: current_alias}, state}
  end

  defp build_join_chain([rel_name | rest], built_path, current_resource, current_alias, state) do
    full_path = built_path ++ [rel_name]

    case Map.get(state.joins, full_path) do
      nil ->
        # Create new join
        relationship = Ash.Resource.Info.relationship(current_resource, rel_name)
        dest_resource = relationship.destination
        dest_table = Info.table!(dest_resource)

        # Generate unique alias
        join_alias = "j#{state.join_counter}"
        state = %{state | join_counter: state.join_counter + 1}

        join_info = %{
          table: dest_table,
          alias: join_alias,
          source_alias: current_alias,
          source_attr: relationship.source_attribute,
          dest_attr: relationship.destination_attribute,
          resource: dest_resource
        }

        state = %{state | joins: Map.put(state.joins, full_path, join_info)}

        if rest == [] do
          {join_info, state}
        else
          build_join_chain(rest, full_path, dest_resource, join_alias, state)
        end

      existing_join ->
        if rest == [] do
          {existing_join, state}
        else
          build_join_chain(rest, full_path, existing_join.resource, existing_join.alias, state)
        end
    end
  end

  defp get_attr_name(%{name: name}), do: name
  defp get_attr_name(name) when is_atom(name), do: name

  # Column names with table alias for XTDB
  defp column_name(:id, alias), do: "#{alias}.\"_id\""
  defp column_name(:_id, alias), do: "#{alias}.\"_id\""
  defp column_name(name, alias), do: "#{alias}.#{Atom.to_string(name)}"
end
