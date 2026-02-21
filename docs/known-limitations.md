# AshXTDB Known Limitations

This document tracks limitations in the AshXTDB implementation.

## XTDB-Specific Limitations (Not Fixable)

### 1. No Multi-Statement Transactions

**Status:** XTDB Limitation (Not Fixable)
**Discovered:** 2024 during atomic update implementation
**Severity:** Medium

**Description:**
XTDB's pgwire protocol does not support multi-statement atomic transactions. Specifically:

- `BEGIN`/`COMMIT` blocks reject any `SELECT` mixed with DML (`INSERT`/`UPDATE`/`DELETE`)
- There is no way to atomically execute multiple statements and roll them all back on failure
- Each DML statement executes and commits immediately

**Consequence — `repo.run()` instead of `repo.transaction()`:**

AshXTDB's `transaction/4` implementation uses `repo.run()` (which checks out a connection from the pool without sending `BEGIN`/`COMMIT`) rather than `repo.transaction()` (which sends `BEGIN`/`COMMIT` and causes protocol errors).

This means:
- `Ash.transaction([Resource], fn -> ... end)` provides a **consistent connection** for the duration of the callback, but does **not** provide atomicity
- If an error occurs partway through, earlier operations are **not rolled back** — they already committed
- `rollback/2` raises an error explaining this limitation

This is the honest model: XTDB operations are effectively auto-committed. For cross-database consistency (e.g., PostgreSQL + XTDB), use the async sync pattern with Oban jobs inserted in the PostgreSQL transaction (see `AshXTDB.SyncAdapter`).

**Impact on atomic updates:**
After atomic updates, the returned record contains the input values, not the computed atomic values. Callers must explicitly refetch if they need the updated values.

**Example:**
```elixir
{:ok, updated} =
  user
  |> Ash.Changeset.atomic_update(:age, Ash.Expr.expr(age + 1))
  |> Ash.update()

# updated.age is the OLD value, not age + 1
# Must refetch to get actual value:
[reloaded] = User |> Ash.Query.filter(id == ^user.id) |> Ash.read!()
reloaded.age  # This has the correct updated value
```

---

### 2. Multi-Level Aggregate Relationship Paths in Exists

**Status:** Limitation
**Severity:** Low

**Description:**
Aggregate references inside `exists()` clauses work for single-level relationship paths (e.g., `user_count` which traverses `:users`). Multi-level relationship paths (aggregates that traverse 2+ relationships) are not yet supported in this context and will fall back to `0`.

**Recommended Pattern:**
For multi-level cases, use nested `exists` instead of aggregate comparison:
```elixir
# Multi-level aggregate path (not yet supported):
# Organization |> Ash.Query.filter(exists(projects, deep_nested_count > 0))

# Use nested exists instead:
Organization
|> Ash.Query.filter(exists(projects, exists(members, true)))
```

---

## Fixed Limitations (Previously Not Working)

The following issues were fixed in 2026:

### ✅ Aggregate Filters Inside Exists Clauses

**Fixed in:** February 2026

**What was fixed:**
Aggregate references inside `exists()` clauses now generate inline correlated scalar subqueries instead of silently falling back to `0`.

**Example that now works:**
```elixir
# Projects whose organization has users
Project
|> Ash.Query.filter(exists(organization, user_count > 0))
|> Ash.read!()

# Organizations with users who have posts
Organization
|> Ash.Query.filter(exists(users, post_count > 0))
|> Ash.read!()

# Aggregates with filters also work
Project
|> Ash.Query.filter(exists(organization, active_user_count > 1))
|> Ash.read!()
```

**Implementation:**
- When an aggregate reference is not found in the root `aggregate_alias_map` and we're inside an EXISTS context (`in_exists?: true`), generate an inline `(SELECT COUNT(*)/SUM()/... FROM table WHERE correlation)` scalar subquery
- Aggregate filters (e.g., `count :active_users, filter: expr(active == true)`) are applied as additional WHERE conditions in the subquery
- Single-level relationship paths are supported; multi-level paths fall back to `0` with a warning

---

### ✅ Aggregate Filters at Top Level

**Fixed in:** February 2026

**What was fixed:**
Top-level aggregate filters now work correctly with complex boolean expressions.

**Example that now works:**
```elixir
User
|> Ash.Query.filter(post_count >= 2)
|> Ash.Query.sort(post_count: :desc)
|> Ash.read!()
```

**Implementation:**
- Added `build_aggregate_joins/1` that detects aggregates in both sort and filter clauses
- Generates LEFT JOIN subqueries with GROUP BY for each aggregate
- Filter module now receives `aggregate_alias_map` to resolve aggregate references

---

### ✅ Many-to-Many Relationship Exists Filters

**Fixed in:** February 2026

**What was fixed:**
Using `exists` to filter through many-to-many relationships now works correctly in both directions.

**Example that now works:**
```elixir
# Tags that have published posts (many-to-many via PostTag)
Tag
|> Ash.Query.filter(exists(posts, published == true))
|> Ash.read!()
```

**Implementation:**
- `build_exists_join_condition/3` now detects `:many_to_many` relationship type
- Generates through-table subquery correlation:
  ```sql
  dest."_id" IN (SELECT th.tag_id FROM post_tags th WHERE th.post_id = parent."_id")
  ```

---

### ✅ Three-Level+ Nested Exists

**Fixed in:** February 2026

**What was fixed:**
Deep nested exists chains (3+ levels) now work correctly.

**Example that now works:**
```elixir
# 4-level deep: org -> users -> posts -> comments
Organization
|> Ash.Query.filter(
  exists(users,
    exists(posts,
      exists(comments, approved == true)
    )
  )
)
|> Ash.read!()
```

**Implementation:**
- Proper alias tracking in `exists_to_sql/3` using incrementing `join_counter`
- Each nested level gets a unique alias (sub0, sub1, sub2, etc.)
- State properly restored after recursion while preserving params and join_counter

---

### ✅ Boolean Type Coercion

**Fixed in:** February 2026

**What was fixed:**
Boolean values from XTDB are now properly coerced to Elixir `true`/`false`.

**Implementation:**
- Added explicit boolean handling in `cast_value/2`
- `coerce_boolean/1` handles all XTDB string representations: "t", "f", "true", "false", "1", "0", etc.

---

## Features Working Correctly

For reference, these features were tested and work correctly:

- ✅ Two-level, three-level, and four-level nested exists
- ✅ Many-to-many exists filters in both directions
- ✅ Aggregate filters at top level (post_count >= N, etc.)
- ✅ Aggregate filters inside exists clauses (inline scalar subqueries)
- ✅ Aggregate sorting (ORDER BY post_count DESC)
- ✅ Exists with calculation filters on related resources
- ✅ DISTINCT ON with aggregate sorts
- ✅ Sort by multiple aggregates
- ✅ Sort by calculations
- ✅ Complex boolean expressions (AND/OR/NOT)
- ✅ Atomic updates with arithmetic expressions
- ✅ Atomic updates with conditional expressions (if/cond)
- ✅ Filtering by calculations
- ✅ Boolean type coercion from XTDB

---

## Investigation Notes

When investigating issues, useful debugging approaches:

1. **Check generated SQL:** Add logging to `AshXTDB.SQL.to_sql/2` to see the actual SQL being generated.

2. **Test SQL directly:** Run the generated SQL directly against XTDB to isolate whether the issue is SQL generation or query execution.

3. **Simplify the query:** Start with the simplest failing case and add complexity to identify the breaking point.

4. **Check ash_sql behavior:** Compare with how ash_sql/AshPostgres handles the same query pattern.
