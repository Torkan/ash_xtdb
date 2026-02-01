# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2024-XX-XX

### Added

- **Core CRUD Operations**
  - Create, read, update, and destroy records
  - Automatic primary key mapping to XTDB's `_id` column
  - Upsert support (native to XTDB)

- **Query Features**
  - Filtering with operators: `==`, `!=`, `<`, `>`, `<=`, `>=`, `is_nil`, `in`
  - Boolean expressions: `and`, `or`, `not`
  - Sorting (ascending and descending)
  - Offset pagination
  - Keyset pagination
  - Distinct queries
  - Select specific fields

- **Relationships**
  - LEFT JOIN for `belongs_to` relationships
  - LEFT JOIN for `has_many` relationships
  - Filter through relationships

- **Aggregates**
  - `count` - Count records
  - `sum` - Sum numeric fields
  - `avg` - Average of numeric fields
  - `min` - Minimum value
  - `max` - Maximum value
  - `exists` - Check if related records exist
  - `first` - Get first related value
  - `list` - Get list of related values

- **Transactions**
  - Full transaction support with commit/rollback
  - Nested transaction support (reuses outer transaction)
  - Read/write transaction mode for DML operations

- **Bitemporal Features**
  - Valid time queries: `as_of_valid_time`, `for_all_valid_time`, `for_valid_time_between`
  - System time queries: `as_of_system_time`, `for_all_system_time`
  - Combined bitemporal queries
  - Temporal mutations: `with_valid_from`, `with_valid_to`, `with_valid_time`
  - GDPR compliance: `erase!/1` to permanently remove records from all history

- **Bulk Operations**
  - `bulk_create` for batch inserts
  - `update_query` for query-based updates
  - `destroy_query` for query-based deletes

- **Calculations**
  - Expression-based calculations
  - String concatenation
  - Arithmetic operations
  - Evaluated in Elixir after record fetch

- **Multitenancy**
  - Attribute-based tenant isolation
  - Automatic tenant filtering on reads
  - Tenant attribute set on creates

- **Infrastructure**
  - Postgrex-based connection via pgwire protocol
  - Telemetry integration for monitoring
  - Error classification for common Postgrex errors
  - Connection pooling support

### Notes

- This is the initial release of AshXTDB
- Requires XTDB v2 with pgwire protocol enabled
- See README.md for full documentation
