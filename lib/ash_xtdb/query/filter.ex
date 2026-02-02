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
  Test helper to expose expression_to_sql for unit testing.

  This function is only intended for testing purposes to verify SQL generation
  for individual expression types without going through the full filter pipeline.
  """
  @spec expression_to_sql_for_test(term(), map()) :: {String.t() | nil, map()}
  def expression_to_sql_for_test(expr, state) do
    expression_to_sql(expr, state)
  end

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
  - aggregate_alias_map (default %{}): Map of aggregate names to their
    SQL column expressions (e.g., %{post_count: "COALESCE(agg0.post_count, 0)"})
  """
  @spec to_sql(
          Ash.Filter.t() | nil,
          Ash.Resource.t(),
          String.t(),
          pos_integer(),
          String.t(),
          map()
        ) ::
          {String.t() | nil, list(), map()}
  def to_sql(
        filter,
        resource,
        table,
        start_param_idx \\ 1,
        table_alias \\ @default_table_alias,
        aggregate_alias_map \\ %{}
      )

  def to_sql(nil, _resource, _table, _start_idx, _table_alias, _agg_map), do: {nil, [], %{}}

  def to_sql(%Ash.Filter{expression: nil}, _resource, _table, _start_idx, _table_alias, _agg_map),
    do: {nil, [], %{}}

  def to_sql(
        %Ash.Filter{expression: expression},
        resource,
        _table,
        start_param_idx,
        table_alias,
        aggregate_alias_map
      ) do
    state = %{
      resource: resource,
      param_idx: start_param_idx,
      params: [],
      joins: %{},
      join_counter: 0,
      table_alias: table_alias,
      aggregate_alias_map: aggregate_alias_map
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

  # ============================================================================
  # Exists Expression (relationship existence check)
  # ============================================================================

  # Handle Ash.Query.Exists - generates EXISTS subquery
  # Example: exists(posts, title == "Hello") becomes:
  # EXISTS (SELECT 1 FROM posts sub WHERE sub.user_id = t._id AND sub.title = 'Hello')
  defp expression_to_sql(%Ash.Query.Exists{path: path, expr: expr}, state) when is_list(path) do
    exists_to_sql(path, expr, state)
  end

  # Handle Ash.Resource.Calculation.Expression - expand the expression
  # Uses map pattern to avoid compile-time struct expansion issues
  defp expression_to_sql(%{__struct__: struct_name, expression: expr}, state)
       when struct_name == Ash.Resource.Calculation.Expression do
    expression_to_sql(expr, state)
  end

  # Handle Ash.Query.Call for function calls like string_downcase, string_length, etc.
  defp expression_to_sql(%Ash.Query.Call{name: name, args: args}, state) do
    call_to_sql(name, args, state)
  end

  # Handle Ash Query Functions and Operators dynamically by checking the struct name
  # This avoids compile-time issues with struct expansion
  defp expression_to_sql(%{__struct__: struct_name} = expr, state) do
    struct_string = to_string(struct_name)

    cond do
      # Handle Ash.Query.Ref - delegate to ref_or_value_to_sql
      struct_string == "Elixir.Ash.Query.Ref" ->
        ref_or_value_to_sql(expr, state)

      # Type function - extract inner expression
      String.ends_with?(struct_string, ".Type") ->
        [inner | _] = Map.get(expr, :arguments, [])
        expression_to_sql(inner, state)

      # If function with 3 args (if/else)
      String.ends_with?(struct_string, ".If") ->
        args = Map.get(expr, :arguments, [])
        handle_if_function(args, state)

      # Cond function
      String.ends_with?(struct_string, ".Cond") ->
        [branches] = Map.get(expr, :arguments, [[]])
        cond_to_sql(branches, state)

      # String functions
      String.ends_with?(struct_string, ".StringDowncase") ->
        [arg] = Map.get(expr, :arguments)
        {arg_sql, state} = ref_or_value_to_sql(arg, state)
        {"LOWER(#{arg_sql})", state}

      String.ends_with?(struct_string, ".StringLength") ->
        [arg] = Map.get(expr, :arguments)
        {arg_sql, state} = ref_or_value_to_sql(arg, state)
        {"LENGTH(#{arg_sql})", state}

      String.ends_with?(struct_string, ".StringTrim") ->
        [arg] = Map.get(expr, :arguments)
        {arg_sql, state} = ref_or_value_to_sql(arg, state)
        {"TRIM(#{arg_sql})", state}

      String.ends_with?(struct_string, ".StringJoin") ->
        args = Map.get(expr, :arguments, [])
        string_join_to_sql(args, state)

      String.ends_with?(struct_string, ".StringSplit") ->
        args = Map.get(expr, :arguments, [])
        string_split_to_sql(args, state)

      # Arithmetic operators
      String.ends_with?(struct_string, ".Plus") ->
        {left_sql, state} = ref_or_value_to_sql(Map.get(expr, :left), state)
        {right_sql, state} = ref_or_value_to_sql(Map.get(expr, :right), state)
        {"(#{left_sql} + #{right_sql})", state}

      String.ends_with?(struct_string, ".Minus") ->
        {left_sql, state} = ref_or_value_to_sql(Map.get(expr, :left), state)
        {right_sql, state} = ref_or_value_to_sql(Map.get(expr, :right), state)
        {"(#{left_sql} - #{right_sql})", state}

      String.ends_with?(struct_string, ".Times") ->
        {left_sql, state} = ref_or_value_to_sql(Map.get(expr, :left), state)
        {right_sql, state} = ref_or_value_to_sql(Map.get(expr, :right), state)
        {"(#{left_sql} * #{right_sql})", state}

      String.ends_with?(struct_string, ".Div") ->
        {left_sql, state} = ref_or_value_to_sql(Map.get(expr, :left), state)
        {right_sql, state} = ref_or_value_to_sql(Map.get(expr, :right), state)
        {"(#{left_sql} / #{right_sql})", state}

      # String concatenation
      String.ends_with?(struct_string, ".Concat") ->
        {left_sql, state} = ref_or_value_to_sql(Map.get(expr, :left), state)
        {right_sql, state} = ref_or_value_to_sql(Map.get(expr, :right), state)
        {"(#{left_sql} || #{right_sql})", state}

      # Fragment - raw SQL with interpolation
      String.ends_with?(struct_string, ".Fragment") ->
        arguments = Map.get(expr, :arguments, [])
        fragment_to_sql(arguments, state)

      # GetPath - struct/map traversal
      String.ends_with?(struct_string, ".GetPath") ->
        [left, path] = Map.get(expr, :arguments, [nil, []])
        {left_sql, state} = ref_or_value_to_sql(left, state)
        path_sql = build_xtdb_path(left_sql, path)
        {path_sql, state}

      # Date/Time functions
      String.ends_with?(struct_string, ".Now") ->
        {"CURRENT_TIMESTAMP", state}

      String.ends_with?(struct_string, ".Today") ->
        {"CURRENT_DATE", state}

      String.ends_with?(struct_string, ".Ago") ->
        [amount, interval] = Map.get(expr, :arguments, [0, :second])
        {amount_sql, state} = ref_or_value_to_sql(amount, state)
        interval_str = interval_to_sql(interval)
        {"(CURRENT_TIMESTAMP - (#{amount_sql} * INTERVAL '1' #{String.upcase(interval_str)}))", state}

      String.ends_with?(struct_string, ".FromNow") ->
        [amount, interval] = Map.get(expr, :arguments, [0, :second])
        {amount_sql, state} = ref_or_value_to_sql(amount, state)
        interval_str = interval_to_sql(interval)
        {"(CURRENT_TIMESTAMP + (#{amount_sql} * INTERVAL '1' #{String.upcase(interval_str)}))", state}

      # Math functions
      String.ends_with?(struct_string, ".Round") ->
        args = Map.get(expr, :arguments, [])
        case args do
          [value] ->
            {value_sql, state} = ref_or_value_to_sql(value, state)
            {"ROUND(#{value_sql})", state}
          [value, precision] ->
            {value_sql, state} = ref_or_value_to_sql(value, state)
            {precision_sql, state} = ref_or_value_to_sql(precision, state)
            {"ROUND(#{value_sql}, #{precision_sql})", state}
        end

      String.ends_with?(struct_string, ".Rem") ->
        [left, right] = Map.get(expr, :arguments, [0, 1])
        {left_sql, state} = ref_or_value_to_sql(left, state)
        {right_sql, state} = ref_or_value_to_sql(right, state)
        {"MOD(#{left_sql}, #{right_sql})", state}

      String.ends_with?(struct_string, ".Floor") ->
        [arg] = Map.get(expr, :arguments)
        {arg_sql, state} = ref_or_value_to_sql(arg, state)
        {"FLOOR(#{arg_sql})", state}

      String.ends_with?(struct_string, ".Ceil") ->
        [arg] = Map.get(expr, :arguments)
        {arg_sql, state} = ref_or_value_to_sql(arg, state)
        {"CEIL(#{arg_sql})", state}

      String.ends_with?(struct_string, ".Abs") ->
        [arg] = Map.get(expr, :arguments)
        {arg_sql, state} = ref_or_value_to_sql(arg, state)
        {"ABS(#{arg_sql})", state}

      # String position - returns 0-based index, SQL POSITION is 1-based
      String.ends_with?(struct_string, ".StringPosition") ->
        [string, substring] = Map.get(expr, :arguments)
        {str_sql, state} = ref_or_value_to_sql(string, state)
        {sub_sql, state} = ref_or_value_to_sql(substring, state)
        # POSITION returns 1-based or 0 if not found; Ash expects 0-based or nil
        # We return (POSITION(...) - 1), but need NULLIF for not-found case
        {"(CASE WHEN POSITION(#{sub_sql} IN #{str_sql}) = 0 THEN NULL ELSE POSITION(#{sub_sql} IN #{str_sql}) - 1 END)", state}

      # Date/Time addition
      String.ends_with?(struct_string, ".DateAdd") ->
        args = Map.get(expr, :arguments, [])
        date_add_to_sql(args, state)

      # Start of day - truncate to day
      String.ends_with?(struct_string, ".StartOfDay") ->
        args = Map.get(expr, :arguments, [])
        start_of_day_to_sql(args, state)

      # Exists - relationship existence check
      String.ends_with?(struct_string, ".Exists") ->
        path = Map.get(expr, :path, [])
        inner_expr = Map.get(expr, :expr, true)
        exists_to_sql(path, inner_expr, state)

      true ->
        # Unhandled struct
        require Logger
        Logger.warning("Unhandled filter expression struct: #{struct_string}")
        {nil, state}
    end
  end

  # Catch-all for unhandled non-struct expressions
  defp expression_to_sql(expr, state) when not is_map(expr) or not is_map_key(expr, :__struct__) do
    require Logger
    Logger.warning("Unhandled filter expression: #{inspect(expr)}")
    {nil, state}
  end

  # ============================================================================
  # Exists Subquery Support
  # ============================================================================

  # Build EXISTS subquery for relationship existence checks
  # Handles single-level and multi-level relationship paths
  defp exists_to_sql([rel_name | rest], expr, state) do
    relationship = Ash.Resource.Info.relationship(state.resource, rel_name)

    unless relationship do
      require Logger
      Logger.warning("Unknown relationship in exists: #{inspect(rel_name)}")
      {nil, state}
    else
      dest_resource = relationship.destination
      dest_table = Info.table!(dest_resource)

      # Use a unique subquery alias
      sub_alias = "sub#{state.join_counter}"
      state = %{state | join_counter: state.join_counter + 1}

      # Build the join condition based on relationship type
      join_condition = build_exists_join_condition(relationship, state.table_alias, sub_alias)

      # Build the inner expression filter if provided and not just `true`
      {inner_where, state} =
        if rest != [] do
          # Multi-level path: recurse with updated context
          inner_state = %{
            state
            | resource: dest_resource,
              table_alias: sub_alias
          }

          {inner_sql, inner_state} = exists_to_sql(rest, expr, inner_state)
          # Restore original state but keep params and join_counter
          state = %{state | params: inner_state.params, join_counter: inner_state.join_counter}
          {inner_sql, state}
        else
          # Single-level: apply the expression filter
          case expr do
            true ->
              {nil, state}

            nil ->
              {nil, state}

            _ ->
              # Evaluate expression in context of destination resource
              inner_state = %{
                state
                | resource: dest_resource,
                  table_alias: sub_alias
              }

              {inner_sql, inner_state} = expression_to_sql(expr, inner_state)
              # Restore original state but keep params and join_counter
              state = %{state | params: inner_state.params, join_counter: inner_state.join_counter}
              {inner_sql, state}
          end
        end

      # Combine join condition with inner where clause
      where_clause =
        case inner_where do
          nil -> join_condition
          "" -> join_condition
          inner -> "#{join_condition} AND #{inner}"
        end

      sql = "EXISTS (SELECT 1 FROM #{quote_table(dest_table)} #{sub_alias} WHERE #{where_clause})"
      {sql, state}
    end
  end

  defp exists_to_sql([], _expr, state) do
    # Empty path - shouldn't happen, but handle gracefully
    {"TRUE", state}
  end

  # Build the join condition for EXISTS based on relationship type
  defp build_exists_join_condition(relationship, parent_alias, sub_alias) do
    case relationship.type do
      :many_to_many ->
        # Many-to-many needs a through-table subquery
        build_many_to_many_join_condition(relationship, parent_alias, sub_alias)

      _ ->
        # Direct relationship (belongs_to, has_one, has_many)
        build_direct_join_condition(relationship, parent_alias, sub_alias)
    end
  end

  # Build join condition for direct relationships (belongs_to, has_one, has_many)
  defp build_direct_join_condition(relationship, parent_alias, sub_alias) do
    source_attr = relationship.source_attribute
    dest_attr = relationship.destination_attribute

    # Handle :id -> _id mapping
    source_col =
      if source_attr == :id,
        do: "#{parent_alias}.\"_id\"",
        else: "#{parent_alias}.#{quote_identifier(Atom.to_string(source_attr))}"

    dest_col =
      if dest_attr == :id,
        do: "#{sub_alias}.\"_id\"",
        else: "#{sub_alias}.#{quote_identifier(Atom.to_string(dest_attr))}"

    "#{dest_col} = #{source_col}"
  end

  # Build join condition for many-to-many relationships using a through-table subquery
  defp build_many_to_many_join_condition(relationship, parent_alias, sub_alias) do
    # Get through table info
    through_resource = relationship.through
    through_table = Info.table!(through_resource)

    # Get the join attributes
    source_attr = relationship.source_attribute
    dest_attr = relationship.destination_attribute
    source_attr_on_join = relationship.source_attribute_on_join_resource
    dest_attr_on_join = relationship.destination_attribute_on_join_resource

    # Handle :id -> _id mapping for the main tables
    source_col =
      if source_attr == :id,
        do: "#{parent_alias}.\"_id\"",
        else: "#{parent_alias}.#{quote_identifier(Atom.to_string(source_attr))}"

    dest_col =
      if dest_attr == :id,
        do: "#{sub_alias}.\"_id\"",
        else: "#{sub_alias}.#{quote_identifier(Atom.to_string(dest_attr))}"

    # Build column references for the through table
    source_attr_on_join_col = quote_identifier(Atom.to_string(source_attr_on_join))
    dest_attr_on_join_col = quote_identifier(Atom.to_string(dest_attr_on_join))
    through_table_quoted = quote_identifier(through_table)

    # Generate: dest."_id" IN (SELECT th.dest_attr FROM through th WHERE th.source_attr = parent."_id")
    "#{dest_col} IN (SELECT th.#{dest_attr_on_join_col} FROM #{through_table_quoted} th WHERE th.#{source_attr_on_join_col} = #{source_col})"
  end

  defp quote_table(table) when is_atom(table), do: quote_identifier(Atom.to_string(table))
  defp quote_table(table) when is_binary(table), do: quote_identifier(table)

  defp quote_identifier(name) do
    AshXTDB.Query.quote_identifier(name)
  end

  # ============================================================================
  # Fragment Support
  # ============================================================================

  # Build SQL from fragment arguments
  defp fragment_to_sql(arguments, state) when is_list(arguments) do
    {parts, state} =
      Enum.reduce(arguments, {[], state}, fn
        {:raw, str}, {parts, st} ->
          {[str | parts], st}

        {:expr, expr}, {parts, st} ->
          {sql, st} = ref_or_value_to_sql(expr, st)
          {[sql | parts], st}

        {:casted_expr, expr}, {parts, st} ->
          # casted_expr is used when the expression has already been processed
          # In our case, treat it the same as expr
          {sql, st} = ref_or_value_to_sql(expr, st)
          {[sql | parts], st}
      end)

    sql = parts |> Enum.reverse() |> Enum.join()
    {sql, state}
  end

  # ============================================================================
  # GetPath Support (JSON/Map traversal)
  # ============================================================================

  # Build XTDB path traversal SQL using dot notation
  # XTDB uses (expr).field for struct access and [index] for array access
  # Example: (t.data).user.name or (t.data).items[0].value
  defp build_xtdb_path(base_sql, []), do: base_sql

  defp build_xtdb_path(base_sql, path) do
    # Wrap the base in parentheses for XTDB path syntax
    path_parts =
      Enum.map(path, fn
        key when is_atom(key) -> ".#{key}"
        key when is_binary(key) -> ".#{key}"
        idx when is_integer(idx) -> "[#{idx}]"
      end)

    "(#{base_sql})#{Enum.join(path_parts)}"
  end

  # ============================================================================
  # Date/Time Functions
  # ============================================================================

  # Convert interval atoms/strings to SQL interval names
  defp interval_to_sql(:year), do: "year"
  defp interval_to_sql(:month), do: "month"
  defp interval_to_sql(:week), do: "week"
  defp interval_to_sql(:day), do: "day"
  defp interval_to_sql(:hour), do: "hour"
  defp interval_to_sql(:minute), do: "minute"
  defp interval_to_sql(:second), do: "second"
  defp interval_to_sql(:millisecond), do: "millisecond"
  defp interval_to_sql(:microsecond), do: "microsecond"
  defp interval_to_sql(interval) when is_binary(interval), do: interval
  defp interval_to_sql(interval) when is_atom(interval), do: Atom.to_string(interval)

  # ============================================================================
  # Date/Time Addition Functions
  # ============================================================================

  # DateAdd with amount and interval: date_add(date, 7, :day)
  defp date_add_to_sql([date, amount, interval], state) do
    {date_sql, state} = ref_or_value_to_sql(date, state)
    {amount_sql, state} = ref_or_value_to_sql(amount, state)
    interval_str = interval_to_sql(interval)
    {"(#{date_sql} + #{amount_sql} * INTERVAL '1' #{String.upcase(interval_str)})", state}
  end

  # DateAdd with Duration struct: date_add(date, Duration.new!(day: 7))
  defp date_add_to_sql([date, %Duration{} = duration], state) do
    {date_sql, state} = ref_or_value_to_sql(date, state)
    duration_sql = duration_to_sql(duration)
    {"(#{date_sql} + #{duration_sql})", state}
  end

  # Fallback for unknown duration/interval format
  defp date_add_to_sql([date, interval_or_duration], state) do
    {date_sql, state} = ref_or_value_to_sql(date, state)
    {interval_sql, state} = ref_or_value_to_sql(interval_or_duration, state)
    {"(#{date_sql} + #{interval_sql})", state}
  end

  defp date_add_to_sql(_args, state) do
    {"NULL", state}
  end

  # Convert Elixir Duration to SQL INTERVAL
  defp duration_to_sql(%Duration{} = duration) do
    parts = []

    parts = if duration.year && duration.year != 0, do: ["#{duration.year} YEAR" | parts], else: parts
    parts = if duration.month && duration.month != 0, do: ["#{duration.month} MONTH" | parts], else: parts
    parts = if duration.week && duration.week != 0, do: ["#{duration.week * 7} DAY" | parts], else: parts
    parts = if duration.day && duration.day != 0, do: ["#{duration.day} DAY" | parts], else: parts
    parts = if duration.hour && duration.hour != 0, do: ["#{duration.hour} HOUR" | parts], else: parts
    parts = if duration.minute && duration.minute != 0, do: ["#{duration.minute} MINUTE" | parts], else: parts
    parts = if duration.second && duration.second != 0, do: ["#{duration.second} SECOND" | parts], else: parts

    case Enum.reverse(parts) do
      [] -> "INTERVAL '0' SECOND"
      [single] -> "INTERVAL '#{single}'"
      multiple ->
        # Multiple parts need to be added together
        intervals = Enum.map(multiple, fn part -> "INTERVAL '#{part}'" end)
        "(#{Enum.join(intervals, " + ")})"
    end
  end

  # StartOfDay - truncate datetime to start of day
  # XTDB uses unquoted unit keywords: DATE_TRUNC(DAY, timestamp)
  defp start_of_day_to_sql([datetime], state) do
    {dt_sql, state} = ref_or_value_to_sql(datetime, state)
    {"DATE_TRUNC(DAY, #{dt_sql})", state}
  end

  defp start_of_day_to_sql([datetime, timezone], state) do
    {dt_sql, state} = ref_or_value_to_sql(datetime, state)
    {tz_sql, state} = ref_or_value_to_sql(timezone, state)
    {"DATE_TRUNC(DAY, #{dt_sql}, #{tz_sql})", state}
  end

  defp start_of_day_to_sql(_args, state) do
    {"NULL", state}
  end

  # Helper for if function - uses extract_cases pattern from ash_sql
  # to flatten nested if/else chains into a single CASE statement
  #
  # Ash compiles `cond` expressions into nested `if` calls with keyword format:
  # [condition, [do: true_val, else: <nested if or final value>]]

  # Handle keyword list format: [condition, [do: true_val, else: false_val]]
  defp handle_if_function([condition, opts], state) when is_list(opts) do
    true_val = Keyword.get(opts, :do)
    false_val = Keyword.get(opts, :else)

    {cond_sql, state} = expression_to_sql(condition, state)
    {true_sql, state} = ref_or_value_to_sql(true_val, state)

    # Extract additional WHEN clauses from nested If expressions
    {additional_cases, else_sql, state} = extract_cases(false_val, state)

    when_clauses =
      [{"WHEN #{cond_sql} THEN #{true_sql}"} | additional_cases]
      |> Enum.map(fn
        {clause} -> clause
        {cond_str, result} -> "WHEN #{cond_str} THEN #{result}"
      end)
      |> Enum.join(" ")

    {"CASE #{when_clauses} ELSE #{else_sql} END", state}
  end

  # Handle positional format: [condition, true_val, false_val]
  defp handle_if_function([condition, true_val, false_val], state) do
    {cond_sql, state} = expression_to_sql(condition, state)
    {true_sql, state} = ref_or_value_to_sql(true_val, state)

    # Extract additional WHEN clauses from nested If expressions
    {additional_cases, else_sql, state} = extract_cases(false_val, state)

    when_clauses =
      [{"WHEN #{cond_sql} THEN #{true_sql}"} | additional_cases]
      |> Enum.map(fn
        {clause} -> clause
        {cond_str, result} -> "WHEN #{cond_str} THEN #{result}"
      end)
      |> Enum.join(" ")

    {"CASE #{when_clauses} ELSE #{else_sql} END", state}
  end

  # Handle [condition, [do: true_val]] without else
  defp handle_if_function([condition, [do: true_val]], state) do
    {cond_sql, state} = expression_to_sql(condition, state)
    {true_sql, state} = ref_or_value_to_sql(true_val, state)
    {"CASE WHEN #{cond_sql} THEN #{true_sql} ELSE NULL END", state}
  end

  defp handle_if_function([condition, true_val], state) do
    {cond_sql, state} = expression_to_sql(condition, state)
    {true_sql, state} = ref_or_value_to_sql(true_val, state)
    {"CASE WHEN #{cond_sql} THEN #{true_sql} ELSE NULL END", state}
  end

  defp handle_if_function(_, state), do: {"NULL", state}

  # Extract nested If expressions into flat list of WHEN clauses
  # This is based on the extract_cases pattern from ash_sql
  #
  # Handles both Ash.Query.Call with name: :if and Ash.Query.Function.If
  defp extract_cases(expr, state, acc \\ [])

  # Handle Ash.Query.Call with name: :if and keyword list args
  # When condition is literal `true`, this is the final else clause (from cond's true -> value)
  defp extract_cases(%Ash.Query.Call{name: :if, args: [true, opts]}, state, acc)
       when is_list(opts) do
    true_val = Keyword.get(opts, :do)
    # Condition is `true`, so true_val is the final else value
    {else_sql, state} = ref_or_value_to_sql(true_val, state)
    {Enum.reverse(acc), else_sql, state}
  end

  defp extract_cases(%Ash.Query.Call{name: :if, args: [condition, opts]}, state, acc)
       when is_list(opts) do
    true_val = Keyword.get(opts, :do)
    false_val = Keyword.get(opts, :else)

    {cond_sql, state} = expression_to_sql(condition, state)
    {true_sql, state} = ref_or_value_to_sql(true_val, state)
    extract_cases(false_val, state, [{cond_sql, true_sql} | acc])
  end

  # Handle Ash.Query.Call with name: :if and positional args
  defp extract_cases(%Ash.Query.Call{name: :if, args: [condition, true_val, false_val]}, state, acc) do
    {cond_sql, state} = expression_to_sql(condition, state)
    {true_sql, state} = ref_or_value_to_sql(true_val, state)
    extract_cases(false_val, state, [{cond_sql, true_sql} | acc])
  end

  # Handle Ash.Query.Function.If struct (3-arg form)
  defp extract_cases(%{__struct__: struct_name, arguments: [condition, when_true, when_false]}, state, acc)
       when struct_name == Ash.Query.Function.If do
    {cond_sql, state} = expression_to_sql(condition, state)
    {true_sql, state} = ref_or_value_to_sql(when_true, state)
    extract_cases(when_false, state, [{cond_sql, true_sql} | acc])
  end

  # Handle If struct dynamically by checking struct name (for compile-time safety)
  defp extract_cases(%{__struct__: struct_name} = expr, state, acc) do
    struct_string = to_string(struct_name)

    if String.ends_with?(struct_string, ".If") do
      case Map.get(expr, :arguments) do
        [condition, when_true, when_false] ->
          {cond_sql, state} = expression_to_sql(condition, state)
          {true_sql, state} = ref_or_value_to_sql(when_true, state)
          extract_cases(when_false, state, [{cond_sql, true_sql} | acc])

        _ ->
          # Not a 3-arg If, treat as final else value
          {else_sql, state} = ref_or_value_to_sql(expr, state)
          {Enum.reverse(acc), else_sql, state}
      end
    else
      # Not an If expression - this is the final else value
      {else_sql, state} = ref_or_value_to_sql(expr, state)
      {Enum.reverse(acc), else_sql, state}
    end
  end

  # Base case - any other expression is the final else value
  defp extract_cases(expr, state, acc) do
    {else_sql, state} = ref_or_value_to_sql(expr, state)
    {Enum.reverse(acc), else_sql, state}
  end

  # ============================================================================
  # Function Call Helpers
  # ============================================================================

  # Handle function calls by name
  defp call_to_sql(:string_downcase, [arg], state) do
    {arg_sql, state} = ref_or_value_to_sql(arg, state)
    {"LOWER(#{arg_sql})", state}
  end

  defp call_to_sql(:string_length, [arg], state) do
    {arg_sql, state} = ref_or_value_to_sql(arg, state)
    {"LENGTH(#{arg_sql})", state}
  end

  defp call_to_sql(:string_trim, [arg], state) do
    {arg_sql, state} = ref_or_value_to_sql(arg, state)
    {"TRIM(#{arg_sql})", state}
  end

  defp call_to_sql(:is_nil, [arg], state) do
    {arg_sql, state} = ref_or_value_to_sql(arg, state)
    {"#{arg_sql} IS NULL", state}
  end

  defp call_to_sql(:not, [arg], state) do
    {arg_sql, state} = expression_to_sql(arg, state)
    {"NOT (#{arg_sql})", state}
  end

  # Delegate :if calls to handle_if_function which handles flattening nested ifs
  defp call_to_sql(:if, args, state) do
    handle_if_function(args, state)
  end

  defp call_to_sql(:cond, [branches], state) do
    cond_to_sql(branches, state)
  end

  defp call_to_sql(:type, [expr | _], state) do
    # Type casting - just evaluate the inner expression
    expression_to_sql(expr, state)
  end

  # Comparison operators as function calls
  defp call_to_sql(:==, [left, right], state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {right_sql, state} = ref_or_value_to_sql(right, state)
    {"#{left_sql} = #{right_sql}", state}
  end

  defp call_to_sql(:!=, [left, right], state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {right_sql, state} = ref_or_value_to_sql(right, state)
    {"#{left_sql} != #{right_sql}", state}
  end

  defp call_to_sql(:>, [left, right], state) do
    binary_op_to_sql(">", left, right, state)
  end

  defp call_to_sql(:>=, [left, right], state) do
    binary_op_to_sql(">=", left, right, state)
  end

  defp call_to_sql(:<, [left, right], state) do
    binary_op_to_sql("<", left, right, state)
  end

  defp call_to_sql(:<=, [left, right], state) do
    binary_op_to_sql("<=", left, right, state)
  end

  # Arithmetic operators as function calls
  defp call_to_sql(:+, [left, right], state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {right_sql, state} = ref_or_value_to_sql(right, state)
    {"(#{left_sql} + #{right_sql})", state}
  end

  defp call_to_sql(:-, [left, right], state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {right_sql, state} = ref_or_value_to_sql(right, state)
    {"(#{left_sql} - #{right_sql})", state}
  end

  defp call_to_sql(:*, [left, right], state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {right_sql, state} = ref_or_value_to_sql(right, state)
    {"(#{left_sql} * #{right_sql})", state}
  end

  defp call_to_sql(:/, [left, right], state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {right_sql, state} = ref_or_value_to_sql(right, state)
    {"(#{left_sql} / #{right_sql})", state}
  end

  # String concatenation
  defp call_to_sql(:<>, [left, right], state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {right_sql, state} = ref_or_value_to_sql(right, state)
    {"(#{left_sql} || #{right_sql})", state}
  end

  # Date/Time functions as calls
  defp call_to_sql(:now, [], state) do
    {"CURRENT_TIMESTAMP", state}
  end

  defp call_to_sql(:today, [], state) do
    {"CURRENT_DATE", state}
  end

  defp call_to_sql(:ago, [amount, interval], state) do
    {amount_sql, state} = ref_or_value_to_sql(amount, state)
    interval_str = interval_to_sql(interval)
    {"(CURRENT_TIMESTAMP - (#{amount_sql} * INTERVAL '1' #{String.upcase(interval_str)}))", state}
  end

  defp call_to_sql(:from_now, [amount, interval], state) do
    {amount_sql, state} = ref_or_value_to_sql(amount, state)
    interval_str = interval_to_sql(interval)
    {"(CURRENT_TIMESTAMP + (#{amount_sql} * INTERVAL '1' #{String.upcase(interval_str)}))", state}
  end

  # Math functions as calls
  defp call_to_sql(:round, [value], state) do
    {value_sql, state} = ref_or_value_to_sql(value, state)
    {"ROUND(#{value_sql})", state}
  end

  defp call_to_sql(:round, [value, precision], state) do
    {value_sql, state} = ref_or_value_to_sql(value, state)
    {precision_sql, state} = ref_or_value_to_sql(precision, state)
    {"ROUND(#{value_sql}, #{precision_sql})", state}
  end

  defp call_to_sql(:rem, [left, right], state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    {right_sql, state} = ref_or_value_to_sql(right, state)
    {"MOD(#{left_sql}, #{right_sql})", state}
  end

  defp call_to_sql(:floor, [value], state) do
    {value_sql, state} = ref_or_value_to_sql(value, state)
    {"FLOOR(#{value_sql})", state}
  end

  defp call_to_sql(:ceil, [value], state) do
    {value_sql, state} = ref_or_value_to_sql(value, state)
    {"CEIL(#{value_sql})", state}
  end

  defp call_to_sql(:abs, [value], state) do
    {value_sql, state} = ref_or_value_to_sql(value, state)
    {"ABS(#{value_sql})", state}
  end

  defp call_to_sql(:string_position, [string, substring], state) do
    {str_sql, state} = ref_or_value_to_sql(string, state)
    {sub_sql, state} = ref_or_value_to_sql(substring, state)
    # POSITION returns 1-based or 0 if not found; Ash expects 0-based or nil
    {"(CASE WHEN POSITION(#{sub_sql} IN #{str_sql}) = 0 THEN NULL ELSE POSITION(#{sub_sql} IN #{str_sql}) - 1 END)", state}
  end

  defp call_to_sql(:date_add, args, state) do
    date_add_to_sql(args, state)
  end

  defp call_to_sql(:start_of_day, args, state) do
    start_of_day_to_sql(args, state)
  end

  # GetPath as call (bracket notation)
  defp call_to_sql(:get_path, [left, path], state) do
    {left_sql, state} = ref_or_value_to_sql(left, state)
    path_sql = build_xtdb_path(left_sql, path)
    {path_sql, state}
  end

  # Catch-all for unhandled function calls
  defp call_to_sql(name, args, state) do
    require Logger
    Logger.warning("Unhandled function call in filter: #{name}/#{length(args)}")
    {nil, state}
  end

  # ============================================================================
  # Complex Expression Helpers
  # ============================================================================

  # Convert cond branches to CASE WHEN
  defp cond_to_sql(branches, state) when is_list(branches) do
    {when_clauses, state} =
      Enum.reduce(branches, {[], state}, fn {condition, result}, {clauses, st} ->
        {cond_sql, st} = expression_to_sql(condition, st)
        {result_sql, st} = ref_or_value_to_sql(result, st)
        clause = "WHEN #{cond_sql} THEN #{result_sql}"
        {[clause | clauses], st}
      end)

    when_sql = when_clauses |> Enum.reverse() |> Enum.join(" ")
    {"CASE #{when_sql} ELSE NULL END", state}
  end

  defp cond_to_sql(_branches, state) do
    {"NULL", state}
  end

  # String join with optional separator
  defp string_join_to_sql([list], state) when is_list(list) do
    {parts, state} =
      Enum.reduce(list, {[], state}, fn arg, {parts, st} ->
        {sql, st} = ref_or_value_to_sql(arg, st)
        {[sql | parts], st}
      end)

    joined = parts |> Enum.reverse() |> Enum.join(" || ")
    {joined, state}
  end

  defp string_join_to_sql([list, separator], state) when is_list(list) do
    {parts, state} =
      Enum.reduce(list, {[], state}, fn arg, {parts, st} ->
        {sql, st} = ref_or_value_to_sql(arg, st)
        {[sql | parts], st}
      end)

    {sep_sql, state} = ref_or_value_to_sql(separator, state)
    joined = parts |> Enum.reverse() |> Enum.intersperse(" || #{sep_sql} || ") |> Enum.join()
    {joined, state}
  end

  defp string_join_to_sql(_args, state), do: {"NULL", state}

  # String split - SQL doesn't have direct split, use STRING_TO_ARRAY (if supported)
  defp string_split_to_sql([str], state) do
    {str_sql, state} = ref_or_value_to_sql(str, state)
    # XTDB may not support STRING_TO_ARRAY, return null for now
    {"STRING_TO_ARRAY(#{str_sql}, ' ')", state}
  end

  defp string_split_to_sql([str, delimiter], state) do
    {str_sql, state} = ref_or_value_to_sql(str, state)
    {delim_sql, state} = ref_or_value_to_sql(delimiter, state)
    {"STRING_TO_ARRAY(#{str_sql}, #{delim_sql})", state}
  end

  defp string_split_to_sql(_args, state), do: {"NULL", state}

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

    # Handle calculation attributes - they need special treatment
    case attr do
      %{__struct__: struct_name, expression: expr}
      when struct_name == Ash.Resource.Calculation.Expression ->
        # For calculation expressions on related resources, we need to evaluate
        # the expression in the context of the joined table
        join_info = Map.get(state.joins, path)

        old_alias = state.table_alias
        old_resource = state.resource

        state = %{state | table_alias: table_alias, resource: join_info.resource}
        {sql, state} = expression_to_sql(expr, state)
        state = %{state | table_alias: old_alias, resource: old_resource}
        {sql, state}

      # Handle Ash.Query.Calculation - extract the expression from opts[:expr]
      %Ash.Query.Calculation{opts: opts} ->
        case Keyword.get(opts, :expr) do
          nil ->
            # No expression, can't filter by this calculation in SQL
            attr_name = get_attr_name(attr)
            column = column_name(attr_name, table_alias)
            {column, state}

          expr ->
            # Expand the calculation expression in the context of the joined table
            join_info = Map.get(state.joins, path)

            old_alias = state.table_alias
            old_resource = state.resource

            state = %{state | table_alias: table_alias, resource: join_info.resource}
            {sql, state} = expression_to_sql(expr, state)
            state = %{state | table_alias: old_alias, resource: old_resource}
            {sql, state}
        end

      _ ->
        attr_name = get_attr_name(attr)
        column = column_name(attr_name, table_alias)
        {column, state}
    end
  end

  defp ref_or_value_to_sql(
         %Ash.Query.Ref{attribute: %{__struct__: struct_name, expression: expr}},
         state
       )
       when struct_name == Ash.Resource.Calculation.Expression do
    # Local calculation expression - evaluate it
    expression_to_sql(expr, state)
  end

  # Handle Ash.Query.Calculation - extract and expand the expression
  defp ref_or_value_to_sql(
         %Ash.Query.Ref{attribute: %Ash.Query.Calculation{opts: opts}},
         state
       ) do
    case Keyword.get(opts, :expr) do
      nil ->
        # No expression, can't filter by this calculation in SQL
        {"NULL", state}

      expr ->
        # Expand the calculation expression
        expression_to_sql(expr, state)
    end
  end

  # Handle Ash.Query.Aggregate references - use the precomputed aggregate alias
  defp ref_or_value_to_sql(
         %Ash.Query.Ref{attribute: %Ash.Query.Aggregate{name: name}},
         state
       ) do
    agg_alias_map = Map.get(state, :aggregate_alias_map, %{})

    case Map.get(agg_alias_map, name) do
      nil ->
        # Aggregate not in alias map - this shouldn't happen if build_aggregate_joins worked
        require Logger
        Logger.warning("Aggregate #{inspect(name)} not found in alias map: #{inspect(agg_alias_map)}")
        {"0", state}

      agg_expr ->
        {agg_expr, state}
    end
  end

  # Handle aggregate references by name (when Ash passes just the aggregate struct)
  defp ref_or_value_to_sql(%Ash.Query.Aggregate{name: name}, state) do
    agg_alias_map = Map.get(state, :aggregate_alias_map, %{})

    case Map.get(agg_alias_map, name) do
      nil ->
        require Logger
        Logger.warning("Aggregate #{inspect(name)} not found in alias map")
        {"0", state}

      agg_expr ->
        {agg_expr, state}
    end
  end

  defp ref_or_value_to_sql(%Ash.Query.Ref{attribute: %{name: name}}, state) do
    # Check if this is an aggregate by name first
    agg_alias_map = Map.get(state, :aggregate_alias_map, %{})

    case Map.get(agg_alias_map, name) do
      nil ->
        # Not an aggregate, treat as regular column
        column = column_name(name, state.table_alias)
        {column, state}

      agg_expr ->
        # Found in aggregate map, use the precomputed expression
        {agg_expr, state}
    end
  end

  defp ref_or_value_to_sql(%Ash.Query.Ref{attribute: name}, state) when is_atom(name) do
    # Check if this is an aggregate by name first
    agg_alias_map = Map.get(state, :aggregate_alias_map, %{})

    case Map.get(agg_alias_map, name) do
      nil ->
        # Not an aggregate, treat as regular column
        column = column_name(name, state.table_alias)
        {column, state}

      agg_expr ->
        # Found in aggregate map, use the precomputed expression
        {agg_expr, state}
    end
  end

  # Handle calculation expression structs directly
  defp ref_or_value_to_sql(%{__struct__: struct_name, expression: expr}, state)
       when struct_name == Ash.Resource.Calculation.Expression do
    expression_to_sql(expr, state)
  end

  # Handle Ash.Query.Call (function calls) passed as values
  defp ref_or_value_to_sql(%Ash.Query.Call{} = call, state) do
    expression_to_sql(call, state)
  end

  # Handle operator structs passed as values
  defp ref_or_value_to_sql(%Ash.Query.Operator.Eq{} = op, state) do
    expression_to_sql(op, state)
  end

  defp ref_or_value_to_sql(%Ash.Query.Operator.NotEq{} = op, state) do
    expression_to_sql(op, state)
  end

  defp ref_or_value_to_sql(%Ash.Query.Operator.GreaterThan{} = op, state) do
    expression_to_sql(op, state)
  end

  defp ref_or_value_to_sql(%Ash.Query.Operator.GreaterThanOrEqual{} = op, state) do
    expression_to_sql(op, state)
  end

  defp ref_or_value_to_sql(%Ash.Query.Operator.LessThan{} = op, state) do
    expression_to_sql(op, state)
  end

  defp ref_or_value_to_sql(%Ash.Query.Operator.LessThanOrEqual{} = op, state) do
    expression_to_sql(op, state)
  end

  defp ref_or_value_to_sql(%Ash.Query.Operator.IsNil{} = op, state) do
    expression_to_sql(op, state)
  end

  defp ref_or_value_to_sql(nil, state) do
    {"NULL", state}
  end

  defp ref_or_value_to_sql(true, state) do
    {"TRUE", state}
  end

  defp ref_or_value_to_sql(false, state) do
    {"FALSE", state}
  end

  defp ref_or_value_to_sql(value, state) when is_struct(value) do
    # Unhandled struct - try expression_to_sql
    case expression_to_sql(value, state) do
      {nil, state} ->
        # Fall back to parameter
        placeholder = "$#{state.param_idx}"
        state = %{state | param_idx: state.param_idx + 1, params: [value | state.params]}
        {placeholder, state}

      result ->
        result
    end
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
  # All column names are quoted to prevent SQL injection
  defp column_name(:id, alias), do: "#{alias}.\"_id\""
  defp column_name(:_id, alias), do: "#{alias}.\"_id\""

  defp column_name(name, alias) do
    quoted_col = AshXTDB.Query.quote_identifier(Atom.to_string(name))
    "#{alias}.#{quoted_col}"
  end
end
