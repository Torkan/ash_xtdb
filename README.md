# AshXTDB

[![Hex.pm](https://img.shields.io/hexpm/v/ash_xtdb.svg)](https://hex.pm/packages/ash_xtdb)
[![Hexdocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ash_xtdb)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An [Ash](https://ash-hq.org/) DataLayer for [XTDB](https://xtdb.com/) v2 with first-class bitemporal query support.

## Features

- **Full CRUD Operations**: Create, read, update, and destroy with complete Ash integration
- **Query Features**: Filtering, sorting, pagination (offset & keyset), distinct, select
- **Relationships**: JOINs for belongs_to and has_many relationships
- **Aggregates**: count, sum, avg, min, max, exists, first, list
- **Transactions**: Full transaction support with commit/rollback
- **Bitemporal Queries**: Query across valid time and system time dimensions
- **Calculations**: Expression-based calculations
- **Multitenancy**: Attribute-based tenant isolation
- **Bulk Operations**: Efficient batch inserts and query-based updates
- **GDPR Compliance**: ERASE operations to permanently remove data from all history

## Installation

Add `ash_xtdb` to your dependencies:

```elixir
def deps do
  [
    {:ash_xtdb, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Start XTDB

```bash
docker run -p 5432:5432 xtdb/xtdb
```

### 2. Define a Repo

```elixir
defmodule MyApp.XTDBRepo do
  use AshXTDB.Repo, otp_app: :my_app
end
```

Configure the connection in `config/config.exs`:

```elixir
config :my_app, MyApp.XTDBRepo,
  hostname: "localhost",
  port: 5432,
  database: "xtdb"
```

Add the repo to your application supervision tree:

```elixir
def start(_type, _args) do
  children = [
    MyApp.XTDBRepo
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### 3. Define a Domain

```elixir
defmodule MyApp.Domain do
  use Ash.Domain

  resources do
    resource MyApp.User
  end
end
```

### 4. Define a Resource

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
    attribute :email, :string, allow_nil?: false
    attribute :name, :string
    attribute :age, :integer
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
```

### 5. Use Your Resources

```elixir
# Create
user = MyApp.User
|> Ash.Changeset.for_create(:create, %{email: "alice@example.com", name: "Alice", age: 30})
|> Ash.create!()

# Read
users = MyApp.User |> Ash.read!()

# Query with filters
adults = MyApp.User
|> Ash.Query.filter(age >= 18)
|> Ash.Query.sort(name: :asc)
|> Ash.read!()

# Update
user
|> Ash.Changeset.for_update(:update, %{name: "Alice Smith"})
|> Ash.update!()

# Delete
Ash.destroy!(user)
```

## Bitemporal Queries

XTDB's unique bitemporal capabilities are exposed via `AshXTDB.Temporal`:

### Valid Time Queries

Query data as it was/will be valid at specific points in time:

```elixir
# Query data as it was valid on a specific date
MyApp.User
|> AshXTDB.Temporal.as_of_valid_time(~U[2024-01-01 00:00:00Z])
|> Ash.read!()

# Query all historical versions
MyApp.User
|> AshXTDB.Temporal.for_all_valid_time()
|> Ash.read!()

# Query data valid within a time range
MyApp.User
|> AshXTDB.Temporal.for_valid_time_between(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
|> Ash.read!()
```

### System Time Queries

Query the database state as it existed at a specific system time (for auditing):

```elixir
# Query what the database contained at a specific moment
MyApp.User
|> AshXTDB.Temporal.as_of_system_time(~U[2024-06-01 12:00:00Z])
|> Ash.read!()

# Query all system time versions (full audit trail)
MyApp.User
|> AshXTDB.Temporal.for_all_system_time()
|> Ash.read!()
```

### Bitemporal Queries

Combine valid time and system time for full bitemporal queries:

```elixir
MyApp.User
|> AshXTDB.Temporal.as_of_valid_time(~U[2024-01-01 00:00:00Z])
|> AshXTDB.Temporal.as_of_system_time(~U[2024-06-01 12:00:00Z])
|> Ash.read!()
```

### Temporal Mutations

Control the valid time range when creating or updating records:

```elixir
# Create a record valid from a specific date
MyApp.User
|> Ash.Changeset.for_create(:create, %{email: "bob@example.com", name: "Bob"})
|> AshXTDB.Temporal.with_valid_from(~U[2024-06-01 00:00:00Z])
|> Ash.create!()

# Create a record with a specific valid time range
MyApp.User
|> Ash.Changeset.for_create(:create, %{email: "temp@example.com", name: "Temp User"})
|> AshXTDB.Temporal.with_valid_time(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
|> Ash.create!()
```

### GDPR Compliance (ERASE)

Permanently remove a record from all history:

```elixir
AshXTDB.Temporal.erase!(user)
```

## Pagination

Both offset and keyset pagination are supported. Enable in your read action:

```elixir
read :read do
  primary? true

  pagination do
    keyset? true
    offset? true
    countable true
    required? false
  end
end
```

### Offset Pagination

```elixir
page = MyApp.User
|> Ash.Query.sort(name: :asc)
|> Ash.read!(page: [limit: 10, offset: 20])

page.results  # The records
page.more?    # Are there more records?
```

### Keyset Pagination

```elixir
# First page
first_page = MyApp.User
|> Ash.Query.sort(name: :asc)
|> Ash.read!(page: [limit: 10])

# Next page using cursor
next_page = MyApp.User
|> Ash.Query.sort(name: :asc)
|> Ash.read!(page: [limit: 10, after: List.last(first_page.results).__metadata__.keyset])
```

## Multitenancy

Attribute-based multitenancy is supported:

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo MyApp.XTDBRepo
    table "posts"
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string
    attribute :org_id, :string, allow_nil?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
```

Usage:

```elixir
# Create with tenant
MyApp.Post
|> Ash.Changeset.for_create(:create, %{title: "My Post"})
|> Ash.Changeset.set_tenant("org1")
|> Ash.create!()

# Read tenant's records (automatically filtered)
Ash.read!(MyApp.Post, tenant: "org1")
```

## Calculations

Expression-based calculations are evaluated in Elixir after record fetch:

```elixir
defmodule MyApp.User do
  # ... xtdb and attributes config ...

  calculations do
    calculate :full_name, :string, expr(first_name <> " " <> last_name)
    calculate :age_plus_ten, :integer, expr(age + 10)
  end
end

# Load calculations
MyApp.User
|> Ash.Query.load([:full_name, :age_plus_ten])
|> Ash.read!()
```

## Aggregates

All standard aggregate types are supported:

```elixir
# Count
Ash.count!(MyApp.User)

# Aggregates on related resources
defmodule MyApp.Author do
  # ... config ...

  aggregates do
    count :post_count, :posts
    sum :total_views, :posts, :view_count
    avg :avg_rating, :posts, :rating
    min :earliest_post, :posts, :created_at
    max :latest_post, :posts, :created_at
    exists :has_published, :posts, filter: expr(published == true)
    first :first_post_title, :posts, :title, sort: [created_at: :asc]
    list :post_titles, :posts, :title
  end
end
```

## Transactions

Full transaction support with automatic commit/rollback:

```elixir
Ash.bulk_create!(users, MyApp.User, :create, transaction: :all)
```

## Telemetry

AshXTDB emits telemetry events for monitoring:

- `[:ash_xtdb, :query]` - Query execution
- `[:ash_xtdb, :create]` - Record creation
- `[:ash_xtdb, :update]` - Record updates
- `[:ash_xtdb, :destroy]` - Record deletion

Each event includes duration, result status, and resource information.

## XTDB-Specific Considerations

| Aspect | PostgreSQL | XTDB |
|--------|------------|------|
| Primary key | Any column | `_id` required (auto-mapped) |
| INSERT | Standard | Acts as upsert |
| UPDATE | Can update PK | Cannot update `_id` |
| Constraints | DB-enforced | None (use Ash validations) |
| Transactions | Full isolation | Writes not visible mid-tx |
| Schema | DDL required | Schemaless (no migrations) |
| Time dimensions | 1 (current) | 2 (valid + system) |
| History | Manual audit | Automatic |
| GDPR deletion | Soft delete | ERASE (permanent) |

## Lateral Join Support

Lateral joins allow loading relationships with per-parent scoping, such as "first 5 posts per user":

```elixir
# Load first 3 posts per user
User
|> Ash.Query.load(posts: Ash.Query.limit(Post, 3))
|> Ash.read!()

# Load posts with offset and limit per user
User
|> Ash.Query.load(posts: Post |> Ash.Query.sort(:title) |> Ash.Query.offset(2) |> Ash.Query.limit(3))
|> Ash.read!()

# Works with many-to-many relationships too
Post
|> Ash.Query.load(tags: Ash.Query.limit(Tag, 5))
|> Ash.read!()
```

### Implementation Strategies

By default, AshXTDB uses iteration (N+1 queries) for lateral joins. For resources where
XTDB supports `NEST_MANY`/`NEST_ONE` syntax, you can enable an optimized single-query approach:

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo MyApp.XTDBRepo
    table "users"
    use_nested_subqueries true  # Enable NEST_MANY/NEST_ONE optimization
  end

  # ...
end
```

When enabled, the data layer generates XTDB-native nested subqueries:

```sql
SELECT t._id, t.name,
       NEST_MANY(SELECT n._id, n.title
                 FROM posts n
                 WHERE n.user_id = t._id
                 FETCH FIRST 3 ROWS ONLY) AS posts
FROM users t
```

**Note**: NEST_MANY/NEST_ONE support depends on your XTDB version. The default iteration
approach is recommended for compatibility.

## Unsupported Features

Due to XTDB's architecture, some features are not available:

- **Row locking** (`FOR UPDATE`, `FOR SHARE`) - XTDB uses MVCC
- **Context-based multitenancy** - No PostgreSQL-style schemas
- **Database constraints** - XTDB is schemaless; use Ash validations
- **Full-text search** - No `tsvector`/`tsquery` support
- **Custom indexes** - XTDB auto-indexes all columns

## Connection Pooling

AshXTDB uses Postgrex for database connections. Configure pooling in your repo config:

```elixir
config :my_app, MyApp.XTDBRepo,
  hostname: "localhost",
  port: 5432,
  database: "xtdb",
  pool_size: 10
```

## License

MIT License - see [LICENSE](LICENSE) for details.
