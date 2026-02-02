# Plan: Port ash_sql Features to AshXTDB

## Overview

Port remaining ash_sql functionality to AshXTDB with cleaner architecture that could benefit upstream refactoring of ash_sql itself.

**Current State**: AshXTDB is already remarkably complete (234 tests passing) with CRUD, filtering, relationships, aggregates, lateral joins, transactions, bulk operations, calculations, and XTDB-specific temporal queries.

**Goal**: Fill gaps in expression handling and advanced features while establishing patterns for potential ash_sql upstream contributions.

---

## Gap Analysis

| Feature | ash_sql | AshXTDB | Priority |
|---------|---------|---------|----------|
| Basic operators (==, <, >, etc.) | ✓ | ✓ | Done |
| String functions | ✓ | ✓ | Done |
| Arithmetic operators | ✓ | ✓ | Done |
| extract_cases (nested if/cond) | ✓ | ✓ | Done |
| Fragment (raw SQL) | ✓ | ✗ | High |
| GetPath (JSON traversal) | ✓ | ✗ | High |
| Date/Time functions | ✓ | Partial | Medium |
| Round/Rem | ✓ | ✗ | Medium |
| SQL-side calculations | ✓ | ✗ (Elixir-side) | Medium |
| Sort on calculations | ✓ | ✗ | Medium |
| Sort on aggregates | ✓ | ✗ | Medium |
| DISTINCT ON | ✓ | ✗ | Medium |
| Atomic updates | ✓ | ✗ | Low |
| Set operations (UNION, etc.) | ✓ | ✗ | Low |

---

## Phased Implementation

### Phase 1: Expression Engine Enhancement (High Priority)

**Goal**: Extend filter.ex with missing operators and functions.

**Files to modify**:
- `lib/ash_xtdb/query/filter.ex` - Add new expression handlers

**Features to add**:

1. **Fragment support** - Raw SQL with parameter binding
   ```elixir
   # Example: fragment("? || ?", field1, field2)
   ```

2. **GetPath** - JSON/JSONB traversal
   ```elixir
   # Example: get_path(data, [:user, :name])
   # SQL: data->'user'->>'name'
   ```

3. **Date/Time functions**:
   - `now()` → `CURRENT_TIMESTAMP`
   - `today()` → `CURRENT_DATE`
   - `ago(duration)` → `CURRENT_TIMESTAMP - INTERVAL '...'`
   - `from_now(duration)` → `CURRENT_TIMESTAMP + INTERVAL '...'`
   - `date_add(date, duration)` → date arithmetic
   - `datetime_add(datetime, duration)` → timestamp arithmetic

4. **Math functions**:
   - `round(value, precision)` → `ROUND(value, precision)`
   - `rem(a, b)` → `MOD(a, b)`

**Pattern from ash_sql**: Study `deps/ash_sql/lib/expr.ex` lines 700-1000 for function handling patterns.

**Tests**: Create `test/ash_xtdb/expression_functions_test.exs`

---

### Phase 2: SQL-Side Calculations (Medium Priority)

**Goal**: Push simple calculations to SQL SELECT instead of Elixir evaluation.

**Files to modify**:
- `lib/ash_xtdb/data_layer.ex` - Detect SQL-evaluable calculations
- `lib/ash_xtdb/query.ex` - Add calculation expressions to SELECT

**Approach**:
1. Analyze calculation expression for SQL compatibility
2. If compatible: add to SELECT clause as `calc_name AS "calc_name"`
3. If not compatible: fall back to current Elixir evaluation

**Benefits**: Reduces data transfer, enables filtering/sorting by calculations in same query.

**Tests**: Extend `test/ash_xtdb/calculations_test.exs`

---

### Phase 3: Sort Enhancements (Medium Priority)

**Goal**: Support sorting on calculations and aggregates.

**Files to create/modify**:
- `lib/ash_xtdb/query/sort.ex` (new) - Dedicated sort handling
- `lib/ash_xtdb/query.ex` - Integrate sort module

**Features**:
1. Sort by calculation expression (inline in ORDER BY)
2. Sort by aggregate (requires join to aggregate subquery)
3. Window function support for complex ordering

**Pattern from ash_sql**: Study `deps/ash_sql/lib/sort.ex` for aggregate binding lookup.

**Tests**: Create `test/ash_xtdb/advanced_sort_test.exs`

---

### Phase 4: Distinct Enhancements (Medium Priority)

**Goal**: DISTINCT ON with proper sort alignment.

**Files to create/modify**:
- `lib/ash_xtdb/query/distinct.ex` (new) - Distinct handling
- `lib/ash_xtdb/query.ex` - Integrate distinct module

**XTDB consideration**: Verify DISTINCT ON syntax support in XTDB SQL.

**Tests**: Create `test/ash_xtdb/distinct_test.exs`

---

### Phase 5: Advanced Features (Low Priority)

**Atomic updates**:
- Support expressions in UPDATE SET clause
- Example: `Ash.Changeset.atomic_update(changeset, :counter, expr(counter + 1))`

**Set operations**:
- UNION, UNION ALL, INTERSECT, EXCEPT
- Integration with Ash's combination queries

---

## Module Organization

Current structure is good. Add:
```
lib/ash_xtdb/
  query/
    filter.ex      # Existing - enhance with Phase 1
    sort.ex        # New - Phase 3
    distinct.ex    # New - Phase 4
    nested.ex      # Existing - keep as is
```

---

## Testing Strategy

1. **Unit tests**: SQL string generation for each new function/operator
2. **Integration tests**: Execute against XTDB, verify results
3. **Edge cases**: NULL handling, empty arrays, type coercion
4. **Regression**: Ensure existing 234 tests continue passing

---

## Verification

After each phase:
1. Run `mix test` - all tests should pass
2. Run `mix check` - no warnings or errors
3. Test specific feature manually with `project_eval`
4. Add comprehensive tests for new functionality

---

## Critical Files

**To modify**:
- `/Users/tgk/src/ash_xtdb/lib/ash_xtdb/query/filter.ex` - Expression handling
- `/Users/tgk/src/ash_xtdb/lib/ash_xtdb/query.ex` - Query building
- `/Users/tgk/src/ash_xtdb/lib/ash_xtdb/data_layer.ex` - Calculation integration

**Reference (ash_sql patterns)**:
- `/Users/tgk/src/ash_xtdb/deps/ash_sql/lib/expr.ex` - Expression patterns
- `/Users/tgk/src/ash_xtdb/deps/ash_sql/lib/sort.ex` - Sort patterns
- `/Users/tgk/src/ash_xtdb/deps/ash_sql/lib/aggregate.ex` - Aggregate patterns

---

## Recommended Starting Point

**Phase 1, Feature 1: Fragment support**

This is high-value and self-contained:
1. Add `defp expression_to_sql(%Ash.Query.Function.Fragment{...}, state)` handler
2. Support `raw:` and `expr:` arguments
3. Handle parameter binding correctly
4. Test with various fragment patterns
