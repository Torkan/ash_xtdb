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
