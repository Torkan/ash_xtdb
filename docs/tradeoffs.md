# Exhaustive Comparison: AshPostgres vs AshXTDB

## Executive Summary

| Aspect | AshPostgres | AshXTDB |
|--------|-------------|---------|
| **Maturity** | Production-ready (v2.6.28) | Early release (v0.1.0) |
| **Primary Use Case** | General-purpose OLTP | Temporal/audit-heavy applications |
| **Underlying DB** | PostgreSQL | XTDB (bitemporal database) |
| **Migration Support** | Full automatic migrations | No migrations (schemaless) |
| **Temporal Queries** | Manual implementation | Native bitemporal support |

---

## AshPostgres

### Pros

#### 1. **Maturity & Ecosystem**
- Production-hardened over many years with extensive bug fixes
- Large community and widespread adoption
- Extensive documentation with guides for every feature
- Well-tested with complex real-world scenarios

#### 2. **Migration System**
- Automatic migration generation from resource definitions
- Snapshot-based migration tracking
- Support for tenant-specific migrations
- Rollback capabilities
- Version control friendly

#### 3. **Full PostgreSQL Feature Access**
- **Custom indexes**: GIN, GiST, BRIN, B-tree with custom options
- **Check constraints**: Database-level validation with custom messages
- **Foreign key constraints**: With configurable ON DELETE/ON UPDATE
- **Unique constraints**: Database-enforced uniqueness
- **Partitioned tables**: Range, list, and hash partitioning support
- **Extensions**: ltree, tsvector, uuid-ossp, citext, and more

#### 4. **Advanced Query Features**
- **Full-text search**: Native tsvector/tsquery support
- **Fragment expressions**: Raw SQL for complex queries
- **Recursive CTEs**: Via manual relationships with ltree
- **Window functions**: Full support through fragments
- **Lateral joins**: Native support for per-parent scoping

#### 5. **Schema-Based Multitenancy**
- Complete tenant isolation via PostgreSQL schemas
- Automatic schema creation/management
- Tenant-specific migrations
- Strong security boundaries

#### 6. **Attribute-Based Multitenancy**
- Filter-based tenant isolation
- Automatic tenant scoping

#### 7. **Polymorphic Resources**
- Share tables across multiple resources
- Configurable foreign key behavior
- Migration support for polymorphic patterns

#### 8. **Atomic Actions**
- Database-level atomic updates
- Optimistic locking support
- Transaction hooks

#### 9. **Performance Optimizations**
- Connection pooling via Ecto
- Prepared statements
- Query plan caching
- Index hints

#### 10. **Type System**
- Full PostgreSQL type mapping
- Custom types (Ltree, Tsvector, Timestamptz)
- JSONB support with operators
- Array types with operators

#### 11. **Tooling**
- `mix ash_postgres.generate_migrations`
- `mix ash_postgres.create`
- `mix ash_postgres.migrate`
- Resource generators

### Cons

#### 1. **No Native Temporal Queries**
- Point-in-time queries require manual implementation
- Audit trails need explicit design
- Historical data requires custom tables/triggers

#### 2. **GDPR Compliance Complexity**
- "Right to be forgotten" requires manual implementation
- Must cascade deletes through all historical/audit tables
- No built-in "erase from all history" capability

#### 3. **Migration Overhead**
- Schema changes require migrations
- Migration conflicts in team environments
- Large migrations can cause downtime
- Cannot easily change history

#### 4. **Schema Rigidity**
- Columns must be predefined
- Schema changes require deployment
- Adding optional fields still needs migration

#### 5. **Bitemporal Data Modeling**
- Valid time + system time requires two separate tracking systems
- Complex trigger setup for historical queries
- No query syntax for "as of" queries

---

## AshXTDB

### Pros

#### 1. **Native Bitemporal Queries**
- **Valid Time (Application Time)**:
  - `as_of_valid_time(timestamp)` - Query data as it was/will be valid
  - `for_all_valid_time()` - Get complete historical versions
  - `for_valid_time_between(from, to)` - Range queries
- **System Time (Audit/Transaction Time)**:
  - `as_of_system_time(timestamp)` - Database state at any moment
  - `for_all_system_time()` - Complete audit log
  - `for_system_time_between(from, to)` - Audit trail ranges
- **Combined bitemporal queries**: Chain both dimensions

#### 2. **Built-in Audit Trail**
- Every change automatically tracked with system time
- No triggers or additional tables needed
- Query historical state trivially
- Complete transaction history

#### 3. **GDPR Compliance - ERASE**
- `AshXTDB.Changeset.erase!(record)` permanently removes from ALL history
- True "right to be forgotten" compliance
- Different from DELETE (which creates tombstone)
- Irreversible by design

#### 4. **Temporal Mutations**
- `with_valid_from(timestamp)` - Set future validity
- `with_valid_to(timestamp)` - Set expiration
- `with_valid_time(from, to)` - Bounded validity windows
- `for_portion_of_valid_time(from, to)` - Update only time slices
- `setting_valid_time(from, to)` - Explicit time bounds

#### 5. **Schemaless Design**
- No migrations needed
- Add attributes without deployment
- XTDB auto-indexes all columns
- Schema flexibility

#### 6. **PATCH Statement**
- Native upsert with temporal bounds
- Key-level merge semantics
- Records syntax for bulk operations

#### 7. **Immutable Architecture**
- MVCC model prevents data corruption
- No row locking needed (optimistic concurrency)
- Consistent reads without blocking

#### 8. **Complete CRUD Support**
- All standard Ash operations work
- Automatic UUID primary key mapping to `_id`
- Validations and changesets fully supported

#### 9. **Relationship Support**
- belongs_to, has_many, many_to_many
- NEST_MANY/NEST_ONE for efficient loading
- Per-parent scoped relationship loading
- Filter through relationships

#### 10. **Full Aggregate Support**
- count, sum, avg, min, max
- exists, first, list
- Statistical: stddev_pop, stddev_samp, var_pop, var_samp
- Boolean: bool_and, bool_or

#### 11. **Pagination**
- Keyset pagination (cursor-based)
- Offset pagination
- Both work with temporal queries

#### 12. **Attribute-Based Multitenancy**
- Automatic tenant filtering
- Tenant attribute auto-set on creates
- Updates/deletes scoped to tenant

### Cons

#### 1. **No Schema-Based Multitenancy**
- XTDB is schemaless - no PostgreSQL schema isolation
- Only attribute-based tenant filtering available
- Weaker isolation guarantees

#### 2. **No Database-Level Constraints**
- No enforced unique constraints (use Ash validations)
- No foreign key constraints (referential integrity via Ash)
- No check constraints at database level

#### 3. **No Full-Text Search**
- No tsvector/tsquery support
- Must use external search solutions (Elasticsearch, etc.)

#### 4. **No Custom Indexes**
- XTDB auto-indexes everything
- Cannot create specialized indexes (GIN, GiST, etc.)
- No index optimization for specific query patterns

#### 5. **No Migrations**
- No version-controlled schema evolution
- No rollback capability
- Schema must be managed in application code

#### 6. **Limited Row Locking**
- No `FOR UPDATE`, `FOR SHARE` (XTDB uses MVCC)
- Some pessimistic locking patterns not possible

#### 7. **Primary Key Restrictions**
- Must map to XTDB's required `_id` column
- Cannot update primary keys

#### 8. **INSERT Semantics**
- INSERT acts as upsert (overwrites on duplicate `_id`)
- May surprise developers expecting traditional SQL

#### 9. **Transaction Limitations**
- XTDB does not support multi-statement atomic transactions via pgwire
- `BEGIN`/`COMMIT` causes protocol errors when mixing `SELECT` and DML
- AshXTDB uses `repo.run()` (connection checkout) not `repo.transaction()` — no rollback
- Each DML statement auto-commits immediately
- Nested "transactions" reuse the outer connection (no sub-transactions)

#### 10. **Expression-Based Calculations**
- Evaluated in Elixir after record fetch (not in database)
- Less efficient for complex calculations on large datasets

#### 11. **Connection Protocol**
- Limited pgwire protocol support
- No pg_catalog type discovery
- Simple query protocol only

#### 12. **Maturity**
- v0.1.0 - early release
- Smaller community
- Less battle-tested in production
- Fewer examples and documentation

#### 13. **Ecosystem**
- XTDB itself is less mature than PostgreSQL
- Fewer DBA tools
- Less hosting options
- Smaller talent pool

#### 14. **Performance Uncertainty**
- Less optimization documentation
- Auto-indexing may not be optimal for all patterns
- Historical queries may slow as history grows

---

## Feature Comparison Matrix

| Feature | AshPostgres | AshXTDB |
|---------|-------------|---------|
| **CRUD Operations** | ✅ Full | ✅ Full |
| **Filtering** | ✅ Full | ✅ Full |
| **Sorting** | ✅ Full | ✅ Full |
| **Pagination (Offset)** | ✅ | ✅ |
| **Pagination (Keyset)** | ✅ | ✅ |
| **Aggregates** | ✅ Full | ✅ Full |
| **Relationships** | ✅ Full | ✅ Full |
| **Calculations** | ✅ In-DB | ⚠️ In-Elixir |
| **Transactions** | ✅ Full | ⚠️ Limited |
| **Bulk Operations** | ✅ Full | ✅ Full |
| **Multitenancy (Attribute)** | ✅ | ✅ |
| **Multitenancy (Schema)** | ✅ | ❌ |
| **Migrations** | ✅ Automatic | ❌ None |
| **Custom Indexes** | ✅ | ❌ Auto-only |
| **Check Constraints** | ✅ | ❌ |
| **Foreign Keys** | ✅ | ❌ |
| **Unique Constraints (DB)** | ✅ | ❌ |
| **Full-Text Search** | ✅ tsvector | ❌ |
| **Partitioned Tables** | ✅ | ❌ |
| **Polymorphic Resources** | ✅ | ❌ |
| **Atomic Actions** | ✅ Full | ⚠️ Limited |
| **Row Locking** | ✅ | ❌ MVCC only |
| **Raw SQL (Fragments)** | ✅ | ⚠️ Limited |
| **Ltree Hierarchies** | ✅ | ❌ |
| **Point-in-Time Queries** | ❌ Manual | ✅ Native |
| **System Time (Audit)** | ❌ Manual | ✅ Native |
| **Valid Time (Application)** | ❌ Manual | ✅ Native |
| **Bitemporal Queries** | ❌ Manual | ✅ Native |
| **GDPR Erase** | ❌ Manual | ✅ Native |
| **Temporal Updates** | ❌ Manual | ✅ Native |

---

## When to Choose Each

### Choose **AshPostgres** When:

1. **You need a traditional relational database** with proven reliability
2. **Full-text search** is a requirement
3. **Schema-based multitenancy** is needed for strong tenant isolation
4. **Database constraints** (FK, unique, check) are important for data integrity
5. **Complex indexing strategies** are required for performance
6. **Partitioned tables** are needed for large datasets
7. **Team familiarity** with PostgreSQL matters
8. **Ecosystem maturity** - need DBA tools, hosting options, talent pool
9. **Migration-based deployment** workflows are established
10. **Pessimistic locking** patterns are required

### Choose **AshXTDB** When:

1. **Temporal queries are core** to your application
2. **Audit trail requirements** are extensive (compliance, finance, legal)
3. **GDPR "right to be forgotten"** must be truly complete
4. **Historical data queries** ("show me state as of date X") are frequent
5. **Bitemporal modeling** is required (valid time + system time)
6. **Schema flexibility** is needed (frequently changing data models)
7. **Immutability guarantees** are important
8. **Time-travel debugging** would be valuable
9. **Event sourcing patterns** align with your architecture
10. **Future validity** (scheduling data to become valid later) is needed

### Hybrid Approach

Consider using **both** in the same Ash application:
- AshPostgres for resources needing traditional RDBMS features
- AshXTDB for resources requiring temporal capabilities

Ash's data layer abstraction makes this feasible, though you'd need to manage relationships across data layers carefully.

---

## Summary

**AshPostgres** is the safe, mature choice for most applications. It provides the full power of PostgreSQL with excellent Ash integration, automatic migrations, and a proven ecosystem.

**AshXTDB** is compelling when temporal data is central to your application. The native bitemporal support, built-in audit trails, and GDPR-compliant erasure are features that would require substantial custom development in PostgreSQL. However, you trade database-level constraints, custom indexing, full-text search, and ecosystem maturity.
