# XTDB Feature Feasibility Analysis

## Overview

This document analyzes which ash_sql features can be implemented in AshXTDB based on XTDB's SQL capabilities. Each feature is categorized as:

- **CAN IMPLEMENT**: XTDB has native SQL support
- **PARTIAL**: Can implement with workarounds or limitations
- **CANNOT IMPLEMENT**: XTDB lacks the SQL capability
- **NOT APPLICABLE**: Feature doesn't apply to AshXTDB's architecture

---

## Implementation Requirements

### Hard Requirement: Passing Integration Tests

**A feature or phase is NOT considered implemented until it has passing integration tests.**

For each implemented feature:

1. **Integration tests are mandatory** - Unit tests for SQL generation are helpful but not sufficient
2. **Tests must execute against real XTDB** - Verify actual database behavior, not just SQL string output
3. **Tests must cover:**
   - Basic functionality (happy path)
   - Edge cases (NULL handling, empty inputs, boundary values)
   - Combination with other features (nested functions, compound expressions)
4. **All tests must pass** - Run `mix test` and verify 0 failures before marking complete

### Test File Locations

| Feature Category | Test File |
|-----------------|-----------|
| Filter operators (==, <, >, IN, etc.) | `test/ash_xtdb/filter_operators_test.exs` |
| Expression functions (round, ago, fragment, etc.) | `test/ash_xtdb/expression_functions_test.exs` |
| New functions (string_position, date_add, etc.) | `test/ash_xtdb/new_functions_test.exs` |
| Arithmetic, string_trim coverage | `test/ash_xtdb/missing_coverage_test.exs` |
| Exists with calculations | `test/ash_xtdb/nested_exists_calculation_test.exs` |
| Complex query stress tests | `test/ash_xtdb/complex_query_stress_test.exs` |

### Verification Command

```bash
# Run all tests - must show 0 failures
mix test

# Run specific feature tests
mix test test/ash_xtdb/new_functions_test.exs --trace
```

---

## Feature Analysis

### 1. Date/Time Functions

| Feature | Status | XTDB SQL Support | Implementation Notes |
|---------|--------|------------------|---------------------|
| `date_add/3` | **✅ DONE** | `datetime + INTERVAL` | `(date + amount * INTERVAL '1' UNIT)` |
| `datetime_add/3` | **N/A** | Same as date_add | Ash doesn't provide separate function |
| `ago/1` | **✅ DONE** | `CURRENT_TIMESTAMP - INTERVAL` | Already implemented |
| `from_now/1` | **✅ DONE** | `CURRENT_TIMESTAMP + INTERVAL` | Already implemented |
| `today/0` | **✅ DONE** | `CURRENT_DATE` | Already implemented |
| `now/0` | **✅ DONE** | `CURRENT_TIMESTAMP` | Already implemented |
| `start_of_day/1` | **✅ DONE** | `DATE_TRUNC(DAY, timestamp)` | XTDB uses unquoted unit keywords |

**Implementation approach for date_add/datetime_add:**
```elixir
defp expression_to_sql(%Ash.Query.Function.DateAdd{arguments: [date, amount, interval]}, state) do
  {date_sql, state} = expression_to_sql(date, state)
  {amount_sql, state} = expression_to_sql(amount, state)
  interval_str = to_interval_unit(interval)
  {"(#{date_sql} + #{amount_sql} * INTERVAL '1' #{interval_str})", state}
end
```

---

### 2. String Functions

| Feature | Status | XTDB SQL Support | Implementation Notes |
|---------|--------|------------------|---------------------|
| `string_downcase/1` | **✅ DONE** | `LOWER(str)` | Already implemented |
| `string_length/1` | **✅ DONE** | `CHARACTER_LENGTH(str)` | Already implemented |
| `contains/2` | **✅ DONE** | `str LIKE '%value%'` | Already implemented |
| `string_position/2` | **✅ DONE** | `POSITION(substr IN str)` | Returns 0-based (Ash) vs 1-based (SQL), adjusted with CASE |
| `string_trim/1` | **✅ DONE** | `TRIM(str)` | Already implemented |

**Implementation approach for string_position:**
```elixir
defp expression_to_sql(%Ash.Query.Function.StringPosition{arguments: [string, substring]}, state) do
  {str_sql, state} = expression_to_sql(string, state)
  {sub_sql, state} = expression_to_sql(substring, state)
  {"POSITION(#{sub_sql} IN #{str_sql})", state}
end
```

---

### 3. Numeric/Math Functions

| Feature | Status | XTDB SQL Support | Implementation Notes |
|---------|--------|------------------|---------------------|
| `round/1`, `round/2` | **✅ DONE** | `ROUND(x)`, `ROUND(x, s)` | XTDB supports both forms |
| `rem/2` | **✅ DONE** | `MOD(x, y)` | XTDB supports MOD |
| `floor/1` | **N/A** | `FLOOR(x)` | Ash doesn't provide this function |
| `ceil/1` | **N/A** | `CEIL(x)` | Ash doesn't provide this function |
| `abs/1` | **N/A** | `ABS(x)` | Ash doesn't provide this function |

**Implementation approach:**
```elixir
defp expression_to_sql(%Ash.Query.Function.Round{arguments: [value]}, state) do
  {val_sql, state} = expression_to_sql(value, state)
  {"ROUND(#{val_sql})", state}
end

defp expression_to_sql(%Ash.Query.Function.Round{arguments: [value, precision]}, state) do
  {val_sql, state} = expression_to_sql(value, state)
  {prec_sql, state} = expression_to_sql(precision, state)
  {"ROUND(#{val_sql}, #{prec_sql})", state}
end
```

---

### 4. Array Functions

| Feature | Status | XTDB SQL Support | Implementation Notes |
|---------|--------|------------------|---------------------|
| `length/1` (array) | **PARTIAL** | `LENGTH(array)` | XTDB's LENGTH works on arrays |
| `at/2` | **CANNOT IMPLEMENT** | No documented syntax | XTDB doesn't document array index access |
| `has/2` | **CANNOT IMPLEMENT** | No `ANY`/`@>` operators | Would need workaround or not supported |

**Note:** XTDB supports arrays (`ARRAY[1,2,3]`) and `LENGTH()` for element count, but array element access and membership testing are not documented in the SQL reference.

---

### 5. Comparison Predicates

| Feature | Status | XTDB SQL Support | Implementation Notes |
|---------|--------|------------------|---------------------|
| `is_nil/1` | **ALREADY DONE** | `IS NULL` | Already implemented |
| `is_distinct_from/2` | **CANNOT IMPLEMENT** | Not documented | XTDB predicates docs don't include this |
| `count_nils/1` | **CAN IMPLEMENT** | `SUM(CASE WHEN x IS NULL THEN 1 ELSE 0 END)` | Can build with CASE |

**Note on IS DISTINCT FROM:** This is useful for null-safe comparisons. Without native support, we could potentially emulate with: `(a IS NULL AND b IS NOT NULL) OR (a IS NOT NULL AND b IS NULL) OR (a <> b)` but this is verbose and error-prone.

---

### 6. JSON/GetPath Functions

| Feature | Status | XTDB SQL Support | Implementation Notes |
|---------|--------|------------------|---------------------|
| `GetPath` (JSONB) | **CANNOT IMPLEMENT** | No JSON operators | XTDB doesn't document `->`, `->>`, or `#>` operators |
| Fragment for JSON | **PARTIAL** | Raw SQL | Could use OBJECT access if syntax exists |

**Note:** XTDB supports OBJECT types with nested data, but the SQL documentation doesn't describe field access operators. The XTQL query language may have better nested access support than SQL mode.

---

### 7. Window Functions

| Feature | Status | XTDB SQL Support | Implementation Notes |
|---------|--------|------------------|---------------------|
| `ROW_NUMBER()` | **CAN IMPLEMENT** | `ROW_NUMBER() OVER (...)` | Documented in XTDB |
| `RANK()`, `DENSE_RANK()` | **UNKNOWN** | Not explicitly documented | May work, needs testing |
| `LAG()`, `LEAD()` | **UNKNOWN** | Not explicitly documented | May work, needs testing |

**Implementation approach:**
```elixir
# Would need new module: lib/ash_xtdb/query/window.ex
defp window_function_to_sql(:row_number, partition_by, order_by, state) do
  partition_sql = build_partition_clause(partition_by, state)
  order_sql = build_order_clause(order_by, state)
  "ROW_NUMBER() OVER (#{partition_sql} #{order_sql})"
end
```

---

### 8. Set Operations

| Feature | Status | XTDB SQL Support | Implementation Notes |
|---------|--------|------------------|---------------------|
| `UNION` | **CAN IMPLEMENT** | `UNION [ALL\|DISTINCT]` | Documented |
| `INTERSECT` | **CAN IMPLEMENT** | `INTERSECT [ALL\|DISTINCT]` | Documented |
| `EXCEPT` | **CAN IMPLEMENT** | `EXCEPT [ALL\|DISTINCT]` | Documented |

---

### 9. Sort Features

| Feature | Status | XTDB SQL Support | Implementation Notes |
|---------|--------|------------------|---------------------|
| Sort ASC/DESC | **✅ DONE** | `ORDER BY col ASC/DESC` | Already implemented |
| NULLS FIRST/LAST | **✅ DONE** | Documented | XTDB quirk: DESC reverses NULLS behavior, workaround applied |
| Sort by calculation | **CAN IMPLEMENT** | Expression in ORDER BY | Requires SQL-side calculation |
| Sort by aggregate | **CAN IMPLEMENT** | Subquery/CTE approach | More complex implementation |

---

### 10. Distinct Features

| Feature | Status | XTDB SQL Support | Implementation Notes |
|---------|--------|------------------|---------------------|
| `DISTINCT` | **ALREADY DONE** | `SELECT DISTINCT` | Already implemented |
| `DISTINCT ON` | **CANNOT IMPLEMENT** | Not documented | PostgreSQL-specific feature |

---

### 11. Atomic Updates

| Feature | Status | XTDB SQL Support | Implementation Notes |
|---------|--------|------------------|---------------------|
| `expr(counter + 1)` | **CAN IMPLEMENT** | Expressions in UPDATE | XTDB UPDATE supports expressions |
| `atomic_update/3` | **CAN IMPLEMENT** | Same as above | Need to add to data_layer.ex |

**Implementation approach:**
```elixir
defp build_update_set([{field, {:expr, expression}} | rest], state) do
  {expr_sql, state} = expression_to_sql(expression, state)
  field_sql = quote_ident(field)
  ["#{field_sql} = #{expr_sql}" | build_update_set(rest, state)]
end
```

---

### 12. Other Features

| Feature | Status | XTDB SQL Support | Implementation Notes |
|---------|--------|------------------|---------------------|
| `fragment/1` | **ALREADY DONE** | Raw SQL | Already implemented |
| `error/1` | **NOT APPLICABLE** | N/A | Elixir-side validation, not SQL |
| `lazy/1` | **NOT APPLICABLE** | N/A | Elixir evaluation strategy |
| `parent/0` | **CAN IMPLEMENT** | Correlated subquery | For referencing outer query |

---

## Summary Table

### COMPLETED ✅

| Feature | Status | Notes |
|---------|--------|-------|
| `date_add/3` | ✅ Done | Temporal arithmetic with INTERVAL |
| `start_of_day/1` | ✅ Done | DATE_TRUNC(DAY, timestamp) |
| `string_position/2` | ✅ Done | With 0-based index adjustment |
| `string_trim/1` | ✅ Done | TRIM(str) |
| `round/1`, `round/2` | ✅ Done | ROUND(x) / ROUND(x, precision) |
| `rem/2` | ✅ Done | MOD(x, y) |

### NOT PROVIDED BY ASH (Cannot implement)

| Feature | Reason |
|---------|--------|
| `floor/1` | Ash.Query.Function.Floor doesn't exist |
| `ceil/1` | Ash.Query.Function.Ceil doesn't exist |
| `abs/1` | Ash.Query.Function.Abs doesn't exist |
| `datetime_add/3` | Ash.Query.Function.DatetimeAdd doesn't exist (use date_add) |

### REMAINING TO IMPLEMENT

| Feature | Priority | Complexity |
|---------|----------|------------|
| `count_nils/1` | Low | Medium |
| NULLS FIRST/LAST | Medium | Low |
| Sort by calculation | Medium | Medium |
| Sort by aggregate | Medium | High |
| Atomic updates | Low | Medium |
| Set operations (UNION, etc.) | Low | Medium |
| `ROW_NUMBER()` | Low | Medium |

### CANNOT IMPLEMENT (XTDB Limitation)

| Feature | Reason | Workaround |
|---------|--------|------------|
| `DISTINCT ON` | PostgreSQL-specific, not in XTDB | Use window function with ROW_NUMBER |
| `is_distinct_from/2` | Not documented in XTDB | Verbose null-safe comparison |
| `at/2` (array index) | No documented array access | None |
| `has/2` (array contains) | No array membership operators | None |
| `GetPath` (JSON traverse) | No JSON operators documented | May work with OBJECT if syntax exists |

### NOT APPLICABLE

| Feature | Reason |
|---------|--------|
| `error/1` | Elixir-side validation |
| `lazy/1` | Elixir evaluation strategy |

---

## Recommended Implementation Order

### Phase 1: Low-Hanging Fruit (Easy wins) - ✅ COMPLETED
1. ✅ `round/1`, `round/2` - Simple function mapping
2. ✅ `rem/2` - Maps to `MOD()`
3. ⏭️ `floor/1`, `ceil/1`, `abs/1` - SKIPPED: Ash doesn't provide these functions
4. ✅ `string_position/2` - Standard SQL POSITION (with 0-based adjustment)
5. ✅ `start_of_day/1` - DATE_TRUNC(DAY, ...) (XTDB uses unquoted keywords)
6. ✅ `string_trim/1` - Already implemented

### Phase 2: Date/Time Completion - ✅ COMPLETED
1. ✅ `date_add/3` - Temporal arithmetic with INTERVAL
2. ⏭️ `datetime_add/3` - SKIPPED: Ash doesn't provide this function (use date_add)

### Phase 3: Sort Enhancements
1. ✅ NULLS FIRST/LAST support - **DONE** (with XTDB quirk workaround)
2. ✅ Sort by calculation (inline expression) - **ALREADY IMPLEMENTED**
3. Sort by aggregate (subquery approach) - TODO

### Phase 4: Advanced Features
1. Atomic updates
2. Set operations
3. Window function basics (ROW_NUMBER)

---

## Verification Steps

For each feature, follow this process:

### Before Implementation

1. **Verify XTDB SQL support:**
   ```sql
   -- Test syntax directly in XTDB
   SELECT ROUND(3.14159, 2);
   SELECT POSITION('bar' IN 'foobar');
   SELECT DATE_TRUNC(DAY, CURRENT_TIMESTAMP);
   ```

2. **Check XTDB documentation** for syntax differences from PostgreSQL

### During Implementation

3. **Add SQL generation code** to `lib/ash_xtdb/query/filter.ex`

4. **Write integration tests** that:
   - Create test data
   - Execute Ash queries using the feature
   - Assert correct results from XTDB

### After Implementation (REQUIRED)

5. **Run full test suite:**
   ```bash
   mix test
   ```
   **Must show 0 failures** before marking feature complete.

6. **Verify edge cases are tested:**
   - NULL handling
   - Empty inputs
   - Type coercion
   - Nested/combined usage with other features

### Completion Criteria

A feature is **DONE** only when:
- [ ] SQL generation code is implemented
- [ ] Integration tests exist and pass
- [ ] `mix test` shows 0 failures
- [ ] Edge cases are covered

---

## Known XTDB Quirks

### 1. DESC NULLS FIRST/LAST Reversed

**Issue**: XTDB reverses the behavior of `NULLS FIRST` and `NULLS LAST` when used with `DESC` sort order.

**Expected (SQL Standard)**:
- `DESC NULLS FIRST` → NULLs at the beginning
- `DESC NULLS LAST` → NULLs at the end

**Actual XTDB Behavior**:
- `DESC NULLS FIRST` → NULLs at the end
- `DESC NULLS LAST` → NULLs at the beginning

**Workaround**: AshXTDB swaps the NULLS keywords for DESC sorts:
- `:desc_nils_first` generates `DESC NULLS LAST`
- `:desc_nils_last` generates `DESC NULLS FIRST`

**Test file**: `test/ash_xtdb/sort_nulls_test.exs`

### 2. DATE_TRUNC Uses Unquoted Keywords

**Issue**: XTDB uses unquoted unit keywords in `DATE_TRUNC`, not quoted strings.

**PostgreSQL**: `DATE_TRUNC('day', timestamp)`
**XTDB**: `DATE_TRUNC(DAY, timestamp)`

### 3. INTERVAL Syntax Differences

**Issue**: XTDB uses SQL standard interval syntax, not PostgreSQL style.

**PostgreSQL**: `INTERVAL '1 day'`
**XTDB**: `INTERVAL '1' DAY`

---

## References

- [XTDB Temporal Functions](https://docs.xtdb.com/reference/main/stdlib/temporal.html)
- [XTDB String Functions](https://docs.xtdb.com/reference/main/stdlib/string.html)
- [XTDB Numeric Functions](https://docs.xtdb.com/reference/main/stdlib/numeric.html)
- [XTDB Aggregate Functions](https://docs.xtdb.com/reference/main/stdlib/aggregates.html)
- [XTDB SQL Queries](https://docs.xtdb.com/reference/main/sql/queries.html)
- [XTDB Data Types](https://docs.xtdb.com/reference/main/data-types.html)
