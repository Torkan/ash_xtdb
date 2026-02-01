# Dual-Database Architecture: PostgreSQL + XTDB

Use PostgreSQL for current state with schema enforcement, and XTDB as the
bitemporal source of truth for historical queries and audit trails.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Application Layer                            │
│                         (Ash Framework)                             │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        │                       │                       │
        ▼                       ▼                       │
┌───────────────┐       ┌───────────────┐               │
│  PostgreSQL   │       │     Oban      │               │
│(Current State)│       │  (Job Queue)  │               │
├───────────────┤       ├───────────────┤               │
│ • CRUD ops    │       │ • XTDB sync   │               │
│ • Constraints │       │ • Retries     │               │
│ • Indexes     │──────▶│ • Batching    │               │
│ • FK integrity│ same  │ • Monitoring  │               │
│ • Fast OLTP   │ txn   └───────┬───────┘               │
└───────────────┘               │                       │
                                │ async                 │
                                ▼                       │
                        ┌───────────────┐               │
                        │     XTDB      │◀──────────────┘
                        │   (History)   │    temporal queries
                        ├───────────────┤
                        │ • Bitemporal  │
                        │ • System time │
                        │ • Valid time  │
                        │ • Time-travel │
                        │ • Audit log   │
                        └───────────────┘
```

## Why This Pattern?

| Capability | PostgreSQL | XTDB |
|------------|------------|------|
| Current state queries | ✓ Fast, indexed | Possible but slower |
| Schema enforcement | ✓ Database-level | Application-level |
| Constraints (FK, UNIQUE) | ✓ Enforced | Not enforced |
| "State at time X?" | Manual audit tables | ✓ Built-in |
| "When did this change?" | Manual triggers | ✓ System time |
| "What did we know at time X?" | Very complex | ✓ Native |
| GDPR erasure | Delete + audit cleanup | ✓ ERASE command |

**Key insight:** PostgreSQL validates all data before it reaches XTDB. This means:
- Constraints prevent bad data from entering the system
- XTDB stores only valid, constraint-checked data
- XTDB's lack of constraints is irrelevant - data is pre-validated

## Implementation

### Step 1: Configure Oban

```elixir
# mix.exs
defp deps do
  [
    {:oban, "~> 2.17"},
    # ... other deps
  ]
end

# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [xtdb_sync: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},  # 7 days
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ]

# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    MyApp.XTDBRepo,
    {Oban, Application.fetch_env!(:my_app, Oban)},
    # ...
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Step 2: Create Shared Attribute Modules

Keep attribute definitions DRY between PostgreSQL and XTDB resources:

```elixir
defmodule MyApp.Schemas.UserAttributes do
  @moduledoc "Shared attribute definitions for User"

  defmacro __using__(_) do
    quote do
      attribute :email, :string, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
      attribute :age, :integer, public?: true
      attribute :status, :atom, default: :active, public?: true

      timestamps()
    end
  end
end

defmodule MyApp.Schemas.PostAttributes do
  defmacro __using__(_) do
    quote do
      attribute :title, :string, allow_nil?: false, public?: true
      attribute :body, :string, public?: true
      attribute :user_id, :uuid, allow_nil?: false, public?: true

      timestamps()
    end
  end
end
```

### Step 3: Define PostgreSQL Resources

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    notifiers: [MyApp.Notifiers.XTDBSync]

  postgres do
    repo MyApp.Repo
    table "users"
  end

  attributes do
    uuid_primary_key :id
    use MyApp.Schemas.UserAttributes
  end

  identities do
    identity :unique_email, [:email]
  end

  relationships do
    has_many :posts, MyApp.Post
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule MyApp.Post do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    notifiers: [MyApp.Notifiers.XTDBSync]

  postgres do
    repo MyApp.Repo
    table "posts"

    references do
      reference :user, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id
    use MyApp.Schemas.PostAttributes
  end

  relationships do
    belongs_to :user, MyApp.User do
      source_attribute :user_id
      allow_nil? false
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
```

### Step 4: Define XTDB History Resources

```elixir
defmodule MyApp.History.User do
  use Ash.Resource,
    domain: MyApp.History.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo MyApp.XTDBRepo
    table "users"
  end

  attributes do
    uuid_primary_key :id
    use MyApp.Schemas.UserAttributes
  end

  relationships do
    has_many :posts, MyApp.History.Post do
      destination_attribute :user_id
    end
  end

  actions do
    defaults [:read]  # Read-only for history
  end
end

defmodule MyApp.History.Post do
  use Ash.Resource,
    domain: MyApp.History.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo MyApp.XTDBRepo
    table "posts"
  end

  attributes do
    uuid_primary_key :id
    use MyApp.Schemas.PostAttributes
  end

  relationships do
    belongs_to :user, MyApp.History.User do
      source_attribute :user_id
      define_attribute? false
    end
  end

  actions do
    defaults [:read]
  end
end

defmodule MyApp.History.Domain do
  use Ash.Domain

  resources do
    resource MyApp.History.User
    resource MyApp.History.Post
  end
end
```

### Step 5: Create the XTDB Sync Notifier

```elixir
defmodule MyApp.Notifiers.XTDBSync do
  @moduledoc """
  Notifier that enqueues XTDB sync jobs for all data changes.

  The job is enqueued in the same PostgreSQL transaction as the data change,
  ensuring that if the transaction rolls back, the job is also rolled back.
  """
  use Ash.Notifier

  require Logger

  @impl true
  def notify(%Ash.Notifier.Notification{} = notification) do
    # Skip if no data (e.g., failed action)
    if notification.data do
      enqueue_sync_job(notification)
    end

    :ok
  end

  defp enqueue_sync_job(notification) do
    %{
      action: to_string(notification.action.type),
      resource: to_string(notification.resource),
      record_id: get_record_id(notification.data),
      data: serialize_record(notification.data),
      changed_attributes: get_changed_attributes(notification)
    }
    |> MyApp.Workers.XTDBSync.new()
    |> Oban.insert!()
  end

  defp get_record_id(record) do
    Map.get(record, :id) |> to_string()
  end

  defp serialize_record(record) do
    record
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__struct__])
    |> Map.reject(fn {_k, v} -> match?(%Ash.NotLoaded{}, v) end)
    |> Jason.encode!()
  end

  defp get_changed_attributes(%{action: %{type: :destroy}}), do: []
  defp get_changed_attributes(%{changeset: changeset}) do
    changeset.attributes
    |> Map.keys()
    |> Enum.map(&to_string/1)
  end
end
```

### Step 6: Create the Oban Worker

```elixir
defmodule MyApp.Workers.XTDBSync do
  @moduledoc """
  Oban worker that syncs data changes to XTDB.

  Handles retries automatically - if XTDB is temporarily unavailable,
  jobs will be retried with exponential backoff.
  """
  use Oban.Worker,
    queue: :xtdb_sync,
    max_attempts: 10,
    unique: [
      period: 60,
      keys: [:resource, :record_id],
      states: [:available, :scheduled, :executing]
    ]

  require Logger

  @impl true
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    %{
      "action" => action,
      "resource" => resource_name,
      "record_id" => record_id,
      "data" => data_json
    } = args

    Logger.debug("XTDB sync: #{action} #{resource_name} #{record_id} (attempt #{attempt})")

    resource = resource_module(resource_name)
    table = xtdb_table(resource)
    data = Jason.decode!(data_json)

    result = case action do
      "create" -> sync_create(table, data, resource)
      "update" -> sync_update(table, data, resource)
      "destroy" -> sync_destroy(table, record_id)
    end

    case result do
      :ok ->
        Logger.debug("XTDB sync success: #{action} #{resource_name} #{record_id}")
        :ok

      {:error, error} ->
        Logger.error("XTDB sync failed: #{action} #{resource_name} #{record_id}: #{inspect(error)}")
        {:error, error}
    end
  end

  defp sync_create(table, data, resource) do
    record = atomize_keys(data)
    {sql, params} = AshXTDB.Query.build_insert(table, record, resource)
    execute_sql(sql, params)
  end

  defp sync_update(table, data, resource) do
    # XTDB INSERT acts as upsert, creating new temporal version
    sync_create(table, data, resource)
  end

  defp sync_destroy(table, record_id) do
    sql = "DELETE FROM #{table} WHERE #{table}.\"_id\" = $1"
    execute_sql(sql, [record_id])
  end

  defp execute_sql(sql, params) do
    inlined_sql = AshXTDB.Query.inline_params(sql, params)

    case MyApp.XTDBRepo.query(inlined_sql, []) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp resource_module(resource_name) do
    String.to_existing_atom(resource_name)
  end

  defp xtdb_table(resource) do
    # Map MyApp.User -> "users", etc.
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> Kernel.<>("s")
  end

  defp atomize_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end
end
```

### Step 7: Create Query API with Clear Routing

```elixir
defmodule MyApp.Users do
  @moduledoc """
  User operations with clear separation between current state and history.

  Current state operations use PostgreSQL (fast, indexed, constrained).
  Historical operations use XTDB (bitemporal, time-travel, audit).
  """

  alias AshXTDB.Temporal

  # ===========================================================================
  # Current State (PostgreSQL)
  # ===========================================================================

  @doc "Get a user by ID"
  def get(id), do: Ash.get(MyApp.User, id)
  def get!(id), do: Ash.get!(MyApp.User, id)

  @doc "List users with optional filters"
  def list(opts \\ []) do
    MyApp.User
    |> apply_filters(opts)
    |> Ash.read()
  end

  @doc "Create a new user"
  def create(attrs) do
    MyApp.User
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create()
  end

  @doc "Update a user"
  def update(user, attrs) do
    user
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update()
  end

  @doc "Delete a user"
  def delete(user), do: Ash.destroy(user)

  # ===========================================================================
  # Historical Queries (XTDB)
  # ===========================================================================

  @doc """
  Get the user as they existed at a specific point in valid time.

  ## Example

      # What was the user's data on January 1st?
      Users.at_time(user_id, ~U[2024-01-01 00:00:00Z])
  """
  def at_time(id, %DateTime{} = timestamp) do
    MyApp.History.User
    |> Ash.Query.filter(id == ^id)
    |> Temporal.as_of_valid_time(timestamp)
    |> Ash.read_one()
  end

  @doc """
  Get the complete history of a user (all versions).

  Returns a list of all versions, ordered by system time.
  """
  def history(id) do
    MyApp.History.User
    |> Ash.Query.filter(id == ^id)
    |> Temporal.for_all_system_time()
    |> Ash.read()
  end

  @doc """
  Get changes to a user within a time range.

  ## Example

      # What changed in the last 30 days?
      Users.changes_between(user_id,
        DateTime.add(DateTime.utc_now(), -30, :day),
        DateTime.utc_now()
      )
  """
  def changes_between(id, %DateTime{} = from, %DateTime{} = to) do
    MyApp.History.User
    |> Ash.Query.filter(id == ^id)
    |> Temporal.for_system_time_between(from, to)
    |> Ash.read()
  end

  @doc """
  Answer: "What did we know about this user at a specific point in time?"

  This queries what the system knew at `knowledge_time` about the user's
  state at `valid_time`. Useful for auditing and compliance.

  ## Example

      # On January 15th, what did we think the user's data was on January 1st?
      Users.knowledge_at(user_id,
        knowledge_time: ~U[2024-01-15 00:00:00Z],
        valid_time: ~U[2024-01-01 00:00:00Z]
      )
  """
  def knowledge_at(id, knowledge_time: kt, valid_time: vt) do
    MyApp.History.User
    |> Ash.Query.filter(id == ^id)
    |> Temporal.as_of_system_time(kt)
    |> Temporal.as_of_valid_time(vt)
    |> Ash.read_one()
  end

  @doc """
  Get audit trail for compliance reporting.

  Returns all changes with metadata about when they were recorded.
  """
  def audit_trail(id, opts \\ []) do
    since = Keyword.get(opts, :since, DateTime.add(DateTime.utc_now(), -90, :day))

    MyApp.History.User
    |> Ash.Query.filter(id == ^id)
    |> Temporal.for_system_time_between(since, DateTime.utc_now())
    |> Ash.read()
  end

  @doc """
  GDPR: Permanently erase user from all history.

  This removes the user from both PostgreSQL and XTDB, including all
  historical versions. This is irreversible.
  """
  def erase!(user) do
    # First, delete from PostgreSQL
    Ash.destroy!(user)

    # Then, erase from XTDB (removes all history)
    Temporal.erase!(%MyApp.History.User{id: user.id})
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp apply_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:email, email}, q -> Ash.Query.filter(q, email == ^email)
      {:status, status}, q -> Ash.Query.filter(q, status == ^status)
      {:age_gte, age}, q -> Ash.Query.filter(q, age >= ^age)
      {:limit, limit}, q -> Ash.Query.limit(q, limit)
      _, q -> q
    end)
  end
end
```

## Monitoring and Reliability

### Sync Health Monitoring

```elixir
defmodule MyApp.XTDBSyncHealth do
  @moduledoc "Monitor XTDB sync health and alert on issues"

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_check()
    {:ok, %{}}
  end

  def handle_info(:check, state) do
    check_sync_health()
    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check, :timer.minutes(5))
  end

  defp check_sync_health do
    # Check for failed jobs
    failed_count = count_failed_jobs()
    if failed_count > 0 do
      Logger.error("XTDB sync: #{failed_count} jobs permanently failed")
      # Send alert (e.g., PagerDuty, Slack)
    end

    # Check for job backlog
    pending_count = count_pending_jobs()
    if pending_count > 1000 do
      Logger.warning("XTDB sync: #{pending_count} jobs pending (backlog)")
    end

    # Check sync lag (oldest pending job)
    case oldest_pending_job() do
      nil -> :ok
      %{inserted_at: inserted_at} ->
        lag_seconds = DateTime.diff(DateTime.utc_now(), inserted_at)
        if lag_seconds > 300 do
          Logger.warning("XTDB sync lag: #{lag_seconds}s")
        end
    end
  end

  defp count_failed_jobs do
    import Ecto.Query
    MyApp.Repo.one(
      from j in Oban.Job,
      where: j.queue == "xtdb_sync" and j.state == "discarded",
      select: count()
    )
  end

  defp count_pending_jobs do
    import Ecto.Query
    MyApp.Repo.one(
      from j in Oban.Job,
      where: j.queue == "xtdb_sync" and j.state in ["available", "scheduled"],
      select: count()
    )
  end

  defp oldest_pending_job do
    import Ecto.Query
    MyApp.Repo.one(
      from j in Oban.Job,
      where: j.queue == "xtdb_sync" and j.state in ["available", "scheduled"],
      order_by: [asc: j.inserted_at],
      limit: 1
    )
  end
end
```

### Data Reconciliation

```elixir
defmodule MyApp.Workers.ReconcileXTDB do
  @moduledoc """
  Periodic job to detect data divergence between PostgreSQL and XTDB.

  Run daily to ensure sync is working correctly.
  """
  use Oban.Worker, queue: :maintenance

  require Logger

  @impl true
  def perform(_job) do
    reconcile_users()
    reconcile_posts()
    :ok
  end

  defp reconcile_users do
    pg_count = MyApp.Repo.aggregate(MyApp.User, :count)

    {:ok, %{rows: [[xtdb_count]]}} =
      MyApp.XTDBRepo.query("SELECT COUNT(DISTINCT t.\"_id\") FROM users t", [])

    if pg_count != xtdb_count do
      Logger.error("""
      Data divergence detected in users table!
      PostgreSQL: #{pg_count}
      XTDB: #{xtdb_count}
      Difference: #{abs(pg_count - xtdb_count)}
      """)

      # Could trigger automatic repair here
    else
      Logger.info("Users reconciliation OK: #{pg_count} records")
    end
  end

  defp reconcile_posts do
    pg_count = MyApp.Repo.aggregate(MyApp.Post, :count)

    {:ok, %{rows: [[xtdb_count]]}} =
      MyApp.XTDBRepo.query("SELECT COUNT(DISTINCT t.\"_id\") FROM posts t", [])

    if pg_count != xtdb_count do
      Logger.error("Data divergence in posts: PG=#{pg_count}, XTDB=#{xtdb_count}")
    end
  end
end
```

## Schema Evolution

When you need to add, modify, or remove attributes:

### Adding a New Attribute

```elixir
# 1. Add to shared attributes module
defmodule MyApp.Schemas.UserAttributes do
  defmacro __using__(_) do
    quote do
      attribute :email, :string, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
      attribute :nickname, :string, public?: true  # NEW
    end
  end
end

# 2. Generate PostgreSQL migration
# mix ash_postgres.generate_migrations
# This creates: ALTER TABLE users ADD COLUMN nickname VARCHAR

# 3. Run migration
# mix ecto.migrate

# 4. XTDB needs nothing - schemaless!
# New records will have nickname, old records return nil for it

# 5. Optionally backfill existing records
MyApp.User
|> Ash.Query.filter(is_nil(nickname))
|> Ash.bulk_update!(:set_nickname, %{nickname: ""})
# This also syncs to XTDB via the notifier
```

### Removing an Attribute

```elixir
# 1. Remove from shared attributes module

# 2. Generate PostgreSQL migration (drops column)

# 3. XTDB: Data remains but is never selected
# Historical queries still have access to old values via raw SQL if needed
```

### Backfilling with Bitemporal Awareness

When adding a non-nullable field, you need to understand how backfilling affects
XTDB's two time dimensions differently.

**Scenario:** Add a required `status` field with default value `"active"`.

```
Timeline:
─────────────────────────────────────────────────────────────────►
2020-01-01              2024-01-01              2024-06-01 (today)
    │                       │                       │
    │                       │                       └─ We run backfill
    │                       └─ User was created
    └─ Valid time we backdate to
```

**Step 1: PostgreSQL migration with default**

```elixir
# priv/repo/migrations/20240601_add_status_to_users.exs
def change do
  alter table(:users) do
    add :status, :string, null: false, default: "active"
  end
end
```

This updates all existing PostgreSQL rows immediately.

**Step 2: Backfill XTDB with backdated valid_time**

```elixir
defmodule MyApp.Workers.BackfillStatus do
  @moduledoc """
  Backfill the new 'status' field to XTDB with backdated valid_time.

  This makes the field appear to have "always" existed in valid-time queries,
  while system-time queries preserve the audit trail showing when we actually
  made the change.
  """
  use Oban.Worker, queue: :maintenance

  # Backdate to before any data existed
  @backfill_valid_from ~U[2020-01-01 00:00:00Z]

  def perform(_job) do
    MyApp.User
    |> Ash.read!()
    |> Enum.each(&backfill_record/1)

    :ok
  end

  defp backfill_record(user) do
    # Build record map with all current values including new field
    record = %{
      _id: user.id,
      email: user.email,
      name: user.name,
      status: user.status,  # Now has the default value from PG
      _valid_from: @backfill_valid_from
    }

    {sql, params} = AshXTDB.Query.build_insert("users", record, MyApp.User)
    inlined_sql = AshXTDB.Query.inline_params(sql, params)

    MyApp.XTDBRepo.query(inlined_sql, [])
  end
end
```

**What XTDB stores after backfill:**

| Version | status | valid_from | valid_to | system_from | system_to |
|---------|--------|------------|----------|-------------|-----------|
| v1 (original) | NULL | 2024-01-01 | ∞ | 2024-01-01 | 2024-06-01 |
| v2 (backfill) | 'active' | 2020-01-01 | ∞ | 2024-06-01 | ∞ |

**Query behavior after backfill:**

```elixir
alias AshXTDB.Temporal

# VALID TIME QUERY: "What was the user's status on 2023-01-01?"
# Uses latest system knowledge (v2) → sees status = 'active'
MyApp.History.User
|> Ash.Query.filter(id == ^user_id)
|> Temporal.as_of_valid_time(~U[2023-01-01 00:00:00Z])
|> Ash.read_one!()
# → %User{status: "active", ...}

# SYSTEM TIME QUERY: "What did our system show on 2024-03-01?"
# Uses knowledge as of 2024-03-01 (v1) → sees status = nil
MyApp.History.User
|> Ash.Query.filter(id == ^user_id)
|> Temporal.as_of_system_time(~U[2024-03-01 00:00:00Z])
|> Ash.read_one!()
# → %User{status: nil, ...}

# COMBINED QUERY: "On 2024-03-01, what did we think the status was on 2023-01-01?"
# Uses 2024-03-01 knowledge about 2023-01-01 state → sees status = nil
MyApp.History.User
|> Ash.Query.filter(id == ^user_id)
|> Temporal.as_of_system_time(~U[2024-03-01 00:00:00Z])
|> Temporal.as_of_valid_time(~U[2023-01-01 00:00:00Z])
|> Ash.read_one!()
# → %User{status: nil, ...}

# AFTER BACKFILL: "Today, what do we think the status was on 2023-01-01?"
# Uses today's knowledge (v2) about 2023-01-01 state → sees status = 'active'
MyApp.History.User
|> Ash.Query.filter(id == ^user_id)
|> Temporal.as_of_valid_time(~U[2023-01-01 00:00:00Z])
|> Ash.read_one!()
# → %User{status: "active", ...}
```

**Why this matters for compliance:**

| Question | Query Type | Result |
|----------|------------|--------|
| "What is the user's current status?" | Current state (PG) | `"active"` |
| "What was their status on any past date?" | Valid time | `"active"` (backfilled) |
| "What did your system show on 2024-03-01?" | System time | `nil` (original) |
| "When did you add the status field?" | System time range | 2024-06-01 |

The **system time dimension is immutable** - it always shows exactly what was
recorded and when. This provides an honest audit trail even when you backfill
data for application convenience.

**Choosing backfill valid_from:**

```elixir
# Option 1: Backdate to "beginning of time" - field appears to always exist
@backfill_valid_from ~U[2000-01-01 00:00:00Z]

# Option 2: Use each record's creation date - more accurate history
defp backfill_record(user) do
  record = %{
    _id: user.id,
    status: user.status,
    _valid_from: user.inserted_at  # Use original creation time
  }
  # ...
end

# Option 3: Use the migration date - honest about when field was added
@backfill_valid_from ~U[2024-06-01 00:00:00Z]  # Today
```

Choose based on your compliance requirements:
- **Option 1**: Best for application queries, field "always" existed
- **Option 2**: Preserves original record timeline
- **Option 3**: Most honest, but valid-time queries before this date return nil

## Testing

```elixir
defmodule MyApp.XTDBSyncTest do
  use MyApp.DataCase
  use Oban.Testing, repo: MyApp.Repo

  alias MyApp.Users

  describe "sync to XTDB" do
    test "creating a user enqueues sync job" do
      {:ok, user} = Users.create(%{email: "test@example.com", name: "Test"})

      assert_enqueued(
        worker: MyApp.Workers.XTDBSync,
        args: %{
          action: "create",
          resource: "Elixir.MyApp.User",
          record_id: user.id
        }
      )
    end

    test "sync job writes to XTDB" do
      {:ok, user} = Users.create(%{email: "test@example.com", name: "Test"})

      # Execute the job synchronously
      assert {:ok, _} = perform_job(MyApp.Workers.XTDBSync, %{
        action: "create",
        resource: "Elixir.MyApp.User",
        record_id: to_string(user.id),
        data: Jason.encode!(%{id: user.id, email: user.email, name: user.name})
      })

      # Verify in XTDB
      {:ok, history_user} = Users.at_time(user.id, DateTime.utc_now())
      assert history_user.email == "test@example.com"
    end

    test "update creates new XTDB version" do
      {:ok, user} = Users.create(%{email: "test@example.com", name: "Original"})
      Oban.drain_queue(queue: :xtdb_sync)

      {:ok, updated} = Users.update(user, %{name: "Updated"})
      Oban.drain_queue(queue: :xtdb_sync)

      # Current state
      assert updated.name == "Updated"

      # History shows both versions
      {:ok, versions} = Users.history(user.id)
      names = Enum.map(versions, & &1.name)
      assert "Original" in names
      assert "Updated" in names
    end
  end
end
```

## Summary

This architecture provides:

1. **PostgreSQL for current state** - Fast queries, schema enforcement, constraints
2. **XTDB for complete history** - Bitemporal queries, audit trail, time-travel
3. **Oban for reliable sync** - Transactional job enqueue, retries, monitoring
4. **Clear API boundaries** - Developers know which database to query
5. **Shared schemas** - DRY attribute definitions

**Trade-offs:**
- Eventual consistency (XTDB lags by job processing time)
- Additional infrastructure (Oban, monitoring)
- Two resources per entity (PostgreSQL + XTDB history)

**Best for:**
- Applications with compliance/audit requirements
- Systems that need to answer "what did we know when" questions
- Teams comfortable with dual-database complexity
