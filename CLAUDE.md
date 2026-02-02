# Claude Code Instructions for AshXTDB

## Documentation Lookup

When looking up documentation for any package dependencies in this project, use the `usage_rules` mix tasks instead of web searches or other methods:

### Look up module or function docs

```bash
mix usage_rules.docs <Module>
mix usage_rules.docs <Module.function/arity>
```

Examples:
- `mix usage_rules.docs Ash.Resource`
- `mix usage_rules.docs Ash.Query.filter/2`
- `mix usage_rules.docs Spark.Dsl`

### Search documentation

```bash
mix usage_rules.search_docs "search term"
```

To search specific packages:
```bash
mix usage_rules.search_docs "search term" -p ash -p spark
```

This searches hexdocs and returns results in markdown format. The search uses the versions of dependencies specified in this project's mix.lock.

## Testing Code Changes

When testing code changes interactively, use `mcp__tidewave__project_eval` instead of `mix run` or `mix test`. The `project_eval` tool:

1. **Forces recompilation** of changed modules before execution
2. **Runs code in the project context** with all dependencies available
3. **Captures IO output** for debugging with `IO.puts`/`IO.inspect`

Example usage for testing a function after editing it:
```elixir
# In project_eval, the module will be recompiled automatically
alias MyModule
result = MyModule.my_function(args)
IO.inspect(result, label: "Result")
```

This is much faster than running `mix compile --force && mix run -e '...'` and avoids shell escaping issues.

If the module doesn't seem to reflect your changes, force recompilation first:
```elixir
IEx.Helpers.recompile()
```

## Strategic Approach: SQL Generation & ash_sql

### Context

AshXTDB generates SQL directly rather than using an Ecto adapter. This is because:
1. XTDB has specific SQL requirements (temporal queries, `_id` handling, dialect differences)
2. Building a full Ecto adapter is complex and would still require XTDB customizations
3. Direct SQL generation gives us full control over XTDB-specific features

### Relationship with ash_sql

We aim to support all ash_sql functionality that's applicable to XTDB. However, rather than depending on ash_sql directly (which is tightly coupled to Ecto), we **port and reimplement** the functionality with these goals:

1. **Cleaner architecture**: ash_sql's codebase is complex and hard to navigate. Our implementations should be well-organized, with clear separation of concerns and thorough documentation.

2. **Reduced Ecto coupling**: Implement SQL generation in a way that doesn't depend on `Ecto.Query.dynamic()` or other Ecto internals.

3. **Upstream potential**: Structure the code so it could potentially serve as the foundation for refactoring ash_sql itself, making ash_sql usable for databases without Ecto adapters.

### Implementation Guidelines

When porting functionality from ash_sql:

- **Study ash_sql's approach** first (in `deps/ash_sql/lib/`), understand the patterns and edge cases it handles
- **Reimplement cleanly** with clear module boundaries and documentation
- **Use descriptive function names** and add comments explaining the "why" not just the "what"
- **Write comprehensive tests** that cover the edge cases ash_sql handles
- **Keep functions small and focused** - if a function is doing multiple things, split it

### Features Ported from ash_sql

- [x] `extract_cases` pattern - flattening nested If/cond into single CASE statements
- [x] Aggregate handling (count, sum, exists) - with limitations, see below
- [x] Sort by aggregates (LEFT JOIN subquery pattern)
- [x] Sort by calculations (inline expressions)
- [x] DISTINCT ON (via ROW_NUMBER window function)
- [x] Window functions (ROW_NUMBER, RANK, etc.)
- [x] Atomic updates with expressions
- [x] Nested exists (2 levels working, 3+ levels have issues)
- [ ] Complex subqueries and lateral joins
- [ ] Type coercion and casting (partial - boolean coercion has issues)

Reference: `deps/ash_sql/lib/expr.ex` contains the core expression handling logic.

## Known Limitations

See `docs/known-limitations.md` for a comprehensive list of discovered limitations including:

- Aggregate filters inside nested exists clauses
- Three-level nested exists (especially through join tables)
- Many-to-many relationship exists filters (from the "many" side)
- Boolean type coercion returning "t"/"f" strings
- XTDB limitation: SELECT not allowed in DML transactions

When encountering query issues, check if they match known limitations before debugging.
