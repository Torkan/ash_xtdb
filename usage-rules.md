# AshXTDB Usage Rules for AI Assistants

This document provides comprehensive guidance for AI assistants working with projects that use `ash_xtdb` - an Ash Framework data layer for XTDB v2.

## Overview

`ash_xtdb` connects Ash Framework resources to XTDB v2 via the pgwire protocol (Postgrex). XTDB is a bitemporal database that automatically tracks both valid time (when data is valid in the real world) and system time (when data was recorded).

## Understanding "Schemaless" in ash_xtdb

XTDB is schemaless at the database level, but **ash_xtdb provides application-level schema enforcement**. This is a critical concept to understand.

### What "Schemaless" Means

| Aspect | PostgreSQL | XTDB |
|--------|------------|------|
| Table creation | `CREATE TABLE` required | Auto-created on first INSERT |
| Column types | Enforced by database | Not enforced |
| NOT NULL | Enforced by database | Not enforced |
| UNIQUE constraints | Enforced by database | Not enforced |
| Foreign keys | Enforced by database | Not enforced |
| Schema migrations | Required for changes | Not needed |

### How ash_xtdb Provides Schema Safety

When you query `User`, ash_xtdb generates:
```sql
SELECT t."_id", t.email, t.name, t.age, t.active FROM users t
```

The columns are determined by your Ash resource definition, NOT by what's in the database. This means:

1. **SELECTs are schema-driven**: Only columns defined in your resource are queried
2. **INSERTs are schema-driven**: Only changeset data matching attributes is inserted
3. **Type casting**: Values are cast to expected types on read
4. **Validations**: Ash validations run before writes

### Building Stable Applications

**DO rely on:**
- Ash resource definitions as your schema
- Ash validations for data integrity (`allow_nil?: false`, custom validations)
- Ash identities for uniqueness (checked at application level)
- Ash relationships for referential integrity (loaded through Ash)

**DO NOT rely on:**
- Database-level type enforcement
- Database-level constraints
- Database-level uniqueness checks

### Schema Evolution

When you change your Ash resource:

```elixir
# Before
attributes do
  attribute :name, :string
end

# After - added new attribute
attributes do
  attribute :name, :string
  attribute :nickname, :string  # NEW
end
```

**What happens:**
- New INSERTs will include `nickname`
- Existing rows don't have `nickname` - queries return `nil` for it
- No migration needed, but existing data is unchanged

**Handling missing data:**
```elixir
# Option 1: Allow nil (default)
attribute :nickname, :string

# Option 2: Provide default for new records
attribute :nickname, :string, default: "Unknown"

# Option 3: Backfill existing data
User
|> Ash.Query.filter(is_nil(nickname))
|> Ash.bulk_update!(:set_nickname, %{nickname: "Unknown"})
```

### Removing Attributes

When you remove an attribute from your resource:

```elixir
# Before
attributes do
  attribute :name, :string
  attribute :legacy_field, :string  # REMOVING THIS
end

# After
attributes do
  attribute :name, :string
  # legacy_field removed
end
```

**What happens:**
- New queries won't SELECT `legacy_field`
- Existing data still has `legacy_field` in XTDB (not deleted)
- The column is effectively ignored

**To actually remove data:**
```elixir
# XTDB doesn't support DROP COLUMN
# Data remains but is never read through Ash
```

### Protecting Against Bad Data

**Risk: External writes bypassing Ash**

If another system writes directly to XTDB:
```sql
-- External system inserts malformed data
INSERT INTO users (_id, email, age) VALUES ('123', 'not-an-email', 'not-a-number')
```

**Mitigations:**
1. Restrict XTDB access to your application only
2. Add defensive type checking in your code
3. Use `cast_value` behavior that handles unexpected types

**Risk: Type mismatches in existing data**

```elixir
# If database has age="thirty" but you expect integer
defp handle_user(%User{age: age} = user) when is_integer(age) do
  # This pattern match would fail
end

# Defensive approach
defp handle_user(%User{age: age} = user) do
  age = if is_integer(age), do: age, else: nil
  # Continue safely
end
```

### Best Practices for Schema Stability

1. **Always use Ash for writes** - Never write to XTDB directly
2. **Define comprehensive validations** - Don't rely on database constraints
3. **Use identities for uniqueness** - Ash checks before insert
4. **Handle nil gracefully** - Existing data may lack new fields
5. **Test with production-like data** - Ensure schema matches reality
6. **Document expected data shapes** - Help future maintainers

### Comparison: PostgreSQL vs XTDB Approach

**PostgreSQL workflow:**
```bash
# 1. Write migration
mix ecto.gen.migration add_nickname_to_users

# 2. Define schema change
alter table(:users) do
  add :nickname, :string
end

# 3. Run migration
mix ecto.migrate

# 4. Update Ash resource
attribute :nickname, :string
```

**XTDB workflow:**
```elixir
# 1. Update Ash resource (that's it!)
attribute :nickname, :string

# 2. Optionally backfill existing data
User
|> Ash.Query.filter(is_nil(nickname))
|> Ash.bulk_update!(:set_default_nickname, %{nickname: ""})
```

The XTDB approach is simpler for development but requires more discipline around data integrity.

## Setup and Configuration

### 1. Define a Repo

```elixir
defmodule MyApp.XTDBRepo do
  use AshXTDB.Repo,
    otp_app: :my_app
end
```

Configure in `config/config.exs`:
```elixir
config :my_app, MyApp.XTDBRepo,
  hostname: "localhost",
  port: 5432,
  database: "xtdb"
```

### 2. Define Resources

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo MyApp.XTDBRepo
    table "users"
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    attribute :age, :integer, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
```

### 3. Define a Domain

```elixir
defmodule MyApp.Domain do
  use Ash.Domain

  resources do
    resource MyApp.User
    resource MyApp.Post
  end
end
```

## XTDB-Specific Considerations

### Primary Key Mapping
- Ash uses `:id` for primary keys
- XTDB uses `_id` internally
- The mapping is automatic - always use `:id` in Elixir code

### Upsert Behavior
- XTDB's INSERT acts as an upsert by default
- Inserting a record with an existing `_id` updates it

### No Database Constraints
- XTDB doesn't enforce database constraints (unique, foreign keys, etc.)
- Use Ash validations and identities instead

### Schemaless
- No DDL migrations needed
- Tables are created automatically on first insert

## CRUD Operations

### Create
```elixir
User
|> Ash.Changeset.for_create(:create, %{email: "alice@example.com", name: "Alice"})
|> Ash.create!()
```

### Read
```elixir
# Read all
Ash.read!(User)

# With filter
User
|> Ash.Query.filter(age > 21)
|> Ash.read!()

# Single record
Ash.get!(User, id)
```

### Update
```elixir
user
|> Ash.Changeset.for_update(:update, %{name: "New Name"})
|> Ash.update!()
```

### Destroy
```elixir
Ash.destroy!(user)
```

## Filtering

### Basic Operators
```elixir
# Equality
Ash.Query.filter(User, name == "Alice")

# Comparison
Ash.Query.filter(User, age > 21)
Ash.Query.filter(User, age >= 21)
Ash.Query.filter(User, age < 65)
Ash.Query.filter(User, age <= 65)

# Not equal
Ash.Query.filter(User, status != "inactive")

# IN clause
Ash.Query.filter(User, id in ^[id1, id2, id3])

# NULL checks
Ash.Query.filter(User, is_nil(deleted_at))
Ash.Query.filter(User, not is_nil(email))
```

### String Matching (LIKE)
```elixir
# Contains (LIKE '%value%')
Ash.Query.filter(User, contains(name, "smith"))
```

### Range Queries (BETWEEN)
```elixir
# Use compound expressions for BETWEEN
Ash.Query.filter(User, age >= 18 and age <= 65)
```

### Boolean Logic
```elixir
Ash.Query.filter(User, active == true and age > 21)
Ash.Query.filter(User, status == "active" or status == "pending")
Ash.Query.filter(User, not (status == "deleted"))
```

## Sorting and Pagination

### Sorting
```elixir
User
|> Ash.Query.sort(:name)
|> Ash.Query.sort(name: :asc, age: :desc)
|> Ash.read!()
```

### Offset Pagination
```elixir
User
|> Ash.Query.limit(10)
|> Ash.Query.offset(20)
|> Ash.read!()
```

### Keyset Pagination
Configure in the resource:
```elixir
actions do
  read :read do
    pagination do
      keyset? true
      default_limit 25
    end
  end
end
```

Usage:
```elixir
{:ok, page} = Ash.read(User, page: [limit: 10])
{:ok, next_page} = Ash.read(User, page: [after: page.after, limit: 10])
```

## Relationships

### Defining Relationships
```elixir
defmodule MyApp.User do
  # ...

  relationships do
    has_many :posts, MyApp.Post do
      destination_attribute :user_id
    end
  end
end

defmodule MyApp.Post do
  # ...

  attributes do
    attribute :user_id, :uuid, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :user, MyApp.User do
      source_attribute :user_id
      destination_attribute :id
      define_attribute? false
    end
  end
end
```

### Loading Relationships
```elixir
# Simple load (bulk query)
User
|> Ash.Query.load(:posts)
|> Ash.read!()

# Load with limit per parent (uses NEST_MANY)
User
|> Ash.Query.load(posts: Ash.Query.limit(Post, 5))
|> Ash.read!()

# Load with sorting per parent
User
|> Ash.Query.load(posts: Post |> Ash.Query.sort(inserted_at: :desc) |> Ash.Query.limit(3))
|> Ash.read!()
```

### Filtering Through Relationships
```elixir
# Find users who have posts with specific title
User
|> Ash.Query.filter(posts.title == "Important Post")
|> Ash.read!()
```

### Many-to-Many Relationships
```elixir
defmodule MyApp.Post do
  relationships do
    many_to_many :tags, MyApp.Tag do
      through MyApp.PostTag
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :tag_id
    end
  end
end
```

## Aggregates

### Supported Aggregates
```elixir
# Count
Ash.aggregate!(User, :count)

# Count with filter
Ash.aggregate!(User, :count, query: Ash.Query.filter(User, active == true))

# Sum
Ash.aggregate!(Order, {:sum, :total})

# Average
Ash.aggregate!(User, {:avg, :age})

# Min/Max
Ash.aggregate!(Product, {:min, :price})
Ash.aggregate!(Product, {:max, :price})
```

### Statistical Aggregates (via raw SQL)
XTDB supports these but they're not exposed through Ash's aggregate API:
- `STDDEV_POP` - Population standard deviation
- `STDDEV_SAMP` - Sample standard deviation
- `VAR_POP` - Population variance
- `VAR_SAMP` - Sample variance
- `BOOL_AND` - Boolean AND aggregate
- `BOOL_OR` - Boolean OR aggregate

```elixir
# Execute via raw SQL if needed
{:ok, %{rows: [[stddev]]}} =
  MyApp.XTDBRepo.query("SELECT STDDEV_POP(t.age) FROM users t", [])
```

## Calculations

### Expression Calculations
```elixir
defmodule MyApp.User do
  calculations do
    calculate :full_name, :string, expr(first_name <> " " <> last_name)
    calculate :is_adult, :boolean, expr(age >= 18)
    calculate :years_until_retirement, :integer, expr(65 - age)
  end
end
```

Usage:
```elixir
User
|> Ash.Query.load(:full_name)
|> Ash.read!()
```

## Transactions

```elixir
Ash.transaction(fn ->
  user = Ash.create!(User, %{email: "test@example.com"})

  Post
  |> Ash.Changeset.for_create(:create, %{title: "First Post", user_id: user.id})
  |> Ash.create!()

  user
end)
```

Transactions support:
- Automatic rollback on error
- Nested transactions (savepoints)
- Mix of creates, updates, and destroys

## Multitenancy

### Attribute-Based Multitenancy
```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshXTDB.DataLayer

  multitenancy do
    strategy :attribute
    attribute :organization_id
  end

  attributes do
    attribute :organization_id, :uuid, allow_nil?: false
  end
end
```

Usage:
```elixir
Post
|> Ash.Query.set_tenant("org-uuid")
|> Ash.read!()
```

**Note**: Context-based multitenancy (PostgreSQL schemas) is NOT supported.

## Bulk Operations

### Bulk Create
```elixir
records = [
  %{email: "user1@example.com", name: "User 1"},
  %{email: "user2@example.com", name: "User 2"},
  %{email: "user3@example.com", name: "User 3"}
]

Ash.bulk_create!(records, User, :create)
```

### Bulk Update
```elixir
User
|> Ash.Query.filter(status == "pending")
|> Ash.bulk_update!(:activate, %{status: "active"})
```

### Bulk Destroy
```elixir
User
|> Ash.Query.filter(deleted_at < ^one_year_ago)
|> Ash.bulk_destroy!(:destroy)
```

## Bitemporal Queries

XTDB maintains two time dimensions:
- **Valid Time**: When data is valid in the real world (user-controlled)
- **System Time**: When data was recorded in the database (automatic)

### Valid Time Queries

```elixir
alias AshXTDB.Temporal

# Query as of a specific valid time
User
|> Temporal.as_of_valid_time(~U[2024-01-01 00:00:00Z])
|> Ash.read!()

# Query all valid time history
User
|> Temporal.for_all_valid_time()
|> Ash.read!()

# Query valid time range
User
|> Temporal.for_valid_time_between(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
|> Ash.read!()
```

### System Time Queries (Audit)

```elixir
# See what database looked like at a point in time
User
|> Temporal.as_of_system_time(~U[2024-01-01 00:00:00Z])
|> Ash.read!()

# Query complete audit history
User
|> Temporal.for_all_system_time()
|> Ash.read!()
```

### Combining Time Dimensions
```elixir
# What did we think was valid on June 1st, as of January 1st's knowledge?
User
|> Temporal.as_of_valid_time(~U[2024-06-01 00:00:00Z])
|> Temporal.as_of_system_time(~U[2024-01-01 00:00:00Z])
|> Ash.read!()
```

### Temporal Mutations

```elixir
# Insert with specific valid time
User
|> Ash.Changeset.for_create(:create, attrs)
|> Temporal.with_valid_from(~U[2024-01-01 00:00:00Z])
|> Temporal.with_valid_to(~U[2024-12-31 23:59:59Z])
|> Ash.create!()

# Shorthand for both
User
|> Ash.Changeset.for_create(:create, attrs)
|> Temporal.with_valid_time(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
|> Ash.create!()
```

### Partial Period Updates (FOR PORTION OF)
```elixir
# Update only for a portion of the valid time
user
|> Ash.Changeset.for_update(:update, %{status: "on_leave"})
|> Temporal.for_portion_of_valid_time(~U[2024-07-01 00:00:00Z], ~U[2024-07-31 23:59:59Z])
|> Ash.update!()
```

### GDPR Compliance (ERASE)
```elixir
# Permanently erase from all history (right to be forgotten)
Temporal.erase!(user)
```

**Warning**: ERASE is irreversible and removes all audit history.

## PATCH Statement (Upserts)

For bulk upsert operations:

```elixir
alias AshXTDB.Patch

# Simple upsert
Patch.execute(
  resource: User,
  records: [
    %{id: uuid1, email: "alice@example.com", name: "Alice"},
    %{id: uuid2, email: "bob@example.com", name: "Bob"}
  ]
)

# Upsert with valid time bounds
Patch.execute(
  resource: User,
  records: [%{id: uuid, name: "Updated Name"}],
  valid_from: ~U[2024-01-01 00:00:00Z],
  valid_to: ~U[2024-12-31 23:59:59Z]
)
```

PATCH behavior:
- Matching is always by `_id`
- Present keys override existing values
- Absent/null keys preserve existing values

## Custom XTDB Types

### Duration (ISO 8601)
```elixir
attribute :estimated_time, AshXTDB.Types.Duration
```

Format: `P[n]Y[n]M[n]DT[n]H[n]M[n]S`
- `"PT1H30M"` - 1 hour 30 minutes
- `"P1D"` - 1 day
- `"P1Y2M3DT4H5M6S"` - 1 year, 2 months, 3 days, 4 hours, 5 minutes, 6 seconds

**Important**: XTDB v2 only supports time-based durations (PT format). Date-based durations like `P1Y2M` are NOT supported for SQL execution.

### Interval
```elixir
attribute :repeat_interval, AshXTDB.Types.Interval
```

Represents a time interval with years, months, days, hours, minutes, seconds.

### Period
```elixir
attribute :validity_period, AshXTDB.Types.Period
```

Represents a time range with `from` and `to` DateTime values.

### URI
```elixir
attribute :website, AshXTDB.Types.URI
```

Stores and validates URIs.

## Window Functions

Window functions are supported via raw SQL (not through Ash Query API):

```elixir
# ROW_NUMBER (supported)
sql = """
SELECT t.name, t.age,
       ROW_NUMBER() OVER (ORDER BY t.age DESC) AS rank
FROM users t
"""
{:ok, result} = MyApp.XTDBRepo.query(sql, [])

# With PARTITION BY
sql = """
SELECT t.name, t.department_id,
       ROW_NUMBER() OVER (PARTITION BY t.department_id ORDER BY t.salary DESC) AS dept_rank
FROM employees t
"""
```

**Note**: RANK() and aggregate window functions (SUM OVER, AVG OVER) are NOT yet implemented in XTDB v2.

## Common Table Expressions (CTEs)

CTEs are supported via raw SQL:

```elixir
sql = """
WITH active_users AS (
  SELECT * FROM users WHERE active = true
)
SELECT * FROM active_users WHERE age > 21
"""
{:ok, result} = MyApp.XTDBRepo.query(sql, [])
```

## Set Operations

```elixir
# UNION
sql = """
SELECT email FROM users WHERE role = 'admin'
UNION
SELECT email FROM users WHERE role = 'moderator'
"""

# UNION ALL (keeps duplicates)
sql = """
SELECT email FROM active_users
UNION ALL
SELECT email FROM pending_users
"""

# INTERSECT
sql = """
SELECT user_id FROM orders
INTERSECT
SELECT user_id FROM reviews
"""

# EXCEPT
sql = """
SELECT user_id FROM all_users
EXCEPT
SELECT user_id FROM banned_users
"""
```

## Lateral Joins (NEST_MANY/NEST_ONE)

When loading relationships with limits, offsets, or per-parent filters, ash_xtdb uses XTDB's NEST_MANY/NEST_ONE:

```elixir
# This uses NEST_MANY internally
User
|> Ash.Query.load(posts: Post |> Ash.Query.limit(5) |> Ash.Query.sort(:inserted_at))
|> Ash.read!()
```

Generated SQL:
```sql
SELECT t._id, t.name,
       NEST_MANY(SELECT n._id, n.title
                 FROM posts n
                 WHERE n.user_id = t._id
                 ORDER BY n.inserted_at
                 FETCH FIRST 5 ROWS ONLY) AS posts
FROM users t
```

Simple loads without limits use bulk queries instead (more efficient for unlimited loads).

## Unsupported Features

The following are NOT supported:

1. **Row Locking**: `FOR UPDATE`, `FOR SHARE` - XTDB doesn't support row-level locks
2. **Context Multitenancy**: PostgreSQL schema-based isolation
3. **Database Constraints**: Unique, foreign key, check constraints (use Ash validations)
4. **RANK() Window Function**: Not yet implemented in XTDB v2
5. **Aggregate Window Functions**: `SUM() OVER`, `AVG() OVER` not yet implemented
6. **Date-based Durations**: `P1Y2M3D` format not supported (only `PT` time format works)

## Performance Tips

1. **Use keyset pagination** for large datasets instead of offset pagination
2. **Load relationships with limits** when you don't need all related records
3. **Use bulk operations** for batch inserts/updates
4. **Filter early** - apply filters before loading relationships
5. **Select only needed fields** using `Ash.Query.select/2`

## Debugging

Enable debug logging to see generated SQL:

```elixir
# In config/dev.exs or config/test.exs
config :logger, level: :debug
```

SQL queries are logged as:
```
[debug] AshXTDB SQL: SELECT ... with params: [...]
```

## Error Handling

XTDB errors are converted to Ash errors:

```elixir
case Ash.create(User, attrs) do
  {:ok, user} -> handle_success(user)
  {:error, %Ash.Error.Invalid{} = error} -> handle_validation_error(error)
  {:error, error} -> handle_other_error(error)
end
```
