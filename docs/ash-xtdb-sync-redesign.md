# AshXTDB Sync Redesign: Oban-based Async Sync

## Problem Statement

The current `AshXTDB.SyncResource` extension syncs data to XTDB synchronously in `after_action` hooks that run inside PostgreSQL transactions. This is fundamentally broken:

1. **False atomicity**: Two separate databases (PostgreSQL + XTDB) can never participate in a true atomic transaction. The synchronous approach pretends they can.
2. **Production failures**: XTDB connection errors (stale connections, timeouts) propagate up and roll back the entire PostgreSQL transaction, making basic operations like user creation fail.
3. **Transaction incompatibility**: XTDB's pgwire protocol rejects `SELECT` inside DML transactions, and `repo.transaction()` sends `BEGIN`/`COMMIT` which causes protocol errors.

The honest model is **eventual consistency**: PostgreSQL is the source of truth, XTDB receives synced data asynchronously via Oban jobs that are inserted inside the same PostgreSQL transaction (rolled back together if the transaction fails).

## Architecture

### How it works

```
PostgreSQL Transaction
├── 1. Ash action executes (create/update/destroy)
├── 2. after_action hook fires (SyncHook)
├── 3. SyncHook inserts Oban job into oban_jobs table ← same PG transaction
└── 4. Transaction commits (or rolls back — taking the Oban job with it)

... later ...

Oban Worker picks up job
├── 5. Reads job args (action type, record data, timestamps)
├── 6. Executes XTDB DML (INSERT or DELETE with temporal metadata)
└── 7. Done (or retry on failure)
```

**Key guarantee**: The Oban job is inserted inside the PostgreSQL transaction. If the transaction rolls back, the job disappears. XTDB only gets synced for committed data.

### Sync Adapter abstraction

```elixir
defmodule AshXTDB.SyncAdapter do
  @moduledoc """
  Behaviour for XTDB sync adapters.

  AshXTDB ships with a built-in Oban adapter. Implement this behaviour
  for custom sync strategies (e.g., Broadway, GenStage, or direct HTTP).
  """

  @callback enqueue_sync(
    history_resource :: module(),
    action_type :: :create | :update | :destroy,
    data :: map(),
    context :: %{
      action_name: atom(),
      actor: term(),
      tenant: term(),
      valid_from: DateTime.t() | nil,
      valid_to: DateTime.t() | nil
    }
  ) :: :ok | {:error, term()}
end
```

### Configuration

```elixir
# Default: Built-in Oban adapter
config :ash_xtdb,
  sync_adapter: {AshXTDB.SyncAdapters.Oban, oban: Oban, queue: :xtdb_sync}

# Custom: Any module implementing AshXTDB.SyncAdapter
config :ash_xtdb,
  sync_adapter: MyApp.CustomXTDBSync
```

The host project must configure their Oban queue with **max_concurrency: 1** to guarantee ordered processing:

```elixir
config :my_app, Oban,
  queues: [
    default: 10,
    xtdb_sync: 1  # CRITICAL: single concurrency for temporal ordering
  ]
```

## XTDB Temporal DML — Test Results

Extensive testing of XTDB 2.1.0 pgwire confirmed the following behaviors that drive the sync algorithm design:

### INSERT behavior

| Scenario | Result | Implication |
|---|---|---|
| Unbounded INSERT (`_valid_from` only) | Overwrites ALL future versions | Safe only when processing in temporal order |
| Bounded INSERT (`_valid_from` + `_valid_to`) | Splices into gap, preserves other versions | Always safe, but requires knowing the upper bound |
| Duplicate INSERT (same data + time) | New system-time version; current view unchanged | Retries are safe |

### DELETE behavior

| Scenario | Result | Implication |
|---|---|---|
| `DELETE FOR PORTION OF VALID_TIME FROM T` (open-ended) | Truncates at T, removes everything after | Clean, correct for destroy sync |
| `DELETE FOR PORTION OF VALID_TIME FROM T TO T2` | Removes [T, T2), leaves artifact at T2 | Avoid — use open-ended form |
| DELETE on non-existent record | Silent no-op | **Dangerous** if DELETE processes before CREATE |
| Plain DELETE | Sets `_valid_to` to current processing time | Not suitable — timestamp should reflect event time |

### Out-of-order processing

| Scenario | Correct? | Why |
|---|---|---|
| CREATE(T1) → UPDATE(T2) → DELETE(T3) | Yes | Normal order, all operations work |
| CREATE(T1) → DELETE(T3) → UPDATE(T2) | Yes, with bounded INSERT | Guard SELECT finds `_valid_to=T3`, uses bounded INSERT [T2,T3) |
| DELETE(T3) → CREATE(T1) → UPDATE(T2) | **NO** | DELETE is a no-op (record doesn't exist), then CREATE makes record [T1,∞), DELETE is permanently lost |

**Conclusion**: Out-of-order processing is NOT safe. The single-concurrency Oban queue guarantees insertion-order processing, which matches PostgreSQL commit order.

## Sync Algorithm

### With single-concurrency queue (guaranteed ordering)

Since jobs process in insertion order and there's only one worker, the algorithm is simple:

**For CREATE / UPDATE:**
```sql
-- Unbounded INSERT — safe because ordering is guaranteed
INSERT INTO history_table (_id, field1, field2, ..., _valid_from)
VALUES ($1, $2, $3, ..., $timestamp)
```

**For DESTROY:**
```sql
-- Open-ended temporal DELETE — truncates history at the event time
DELETE FROM history_table
FOR PORTION OF VALID_TIME FROM $timestamp
WHERE _id = $1
```

### `_valid_from` timestamp strategy

| Action type | `_valid_from` source |
|---|---|
| create | `inserted_at` from the PostgreSQL record |
| update | `updated_at` from the PostgreSQL record |
| destroy | UTC timestamp captured at the time of the Ash destroy action |

This ensures XTDB's temporal history reflects when changes actually happened in PostgreSQL, not when the Oban job processed.

### Retry safety

- **CREATE/UPDATE retry**: Duplicate INSERT creates a new system-time version but the current view is identical. Safe.
- **DESTROY retry**: DELETE on already-deleted time range is a no-op. Safe.
- Oban's built-in retry with exponential backoff handles transient XTDB failures.

## Oban Worker

```elixir
defmodule AshXTDB.SyncWorker do
  use Oban.Worker,
    queue: :xtdb_sync,  # overridden by adapter config
    max_attempts: 10,
    priority: 0

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "sync_type" => sync_type,
      "history_resource" => history_resource_string,
      "record_data" => data,
      "valid_from" => valid_from,
      "tenant" => tenant
    } = args

    history_resource = String.to_existing_atom(history_resource_string)

    case sync_type do
      type when type in ["create", "update"] ->
        upsert_to_xtdb(history_resource, data, valid_from, tenant)

      "destroy" ->
        delete_from_xtdb(history_resource, data, valid_from, tenant)
    end
  end
end
```

## Modified SyncHook

The `SyncHook` changes from calling XTDB directly to dispatching through the configured adapter:

```elixir
# Before (dangerous):
defp default_sync(history_resource, action_type, record, context) do
  # Direct XTDB call inside PostgreSQL transaction
  history_resource
  |> Ash.Changeset.for_create(:sync, attrs, opts)
  |> Ash.create(opts)
end

# After (safe):
defp default_sync(history_resource, action_type, record, context) do
  {adapter, adapter_opts} = get_sync_adapter()
  adapter.enqueue_sync(history_resource, action_type, data, context, adapter_opts)
end
```

## Implementation Phases

### Phase 1: Fix `transaction/4` (ship independently, unblocks production)

- [ ] Change `DataLayer.Transactions.transaction/4` to use `repo.run()` instead of `repo.transaction()`
- [ ] XTDB doesn't support multi-statement atomic transactions; `run` is semantically correct
- [ ] `rollback/2` should raise a clear error explaining XTDB limitations
- [ ] Update `in_transaction?/1` accordingly
- [ ] Add tests verifying queries work inside `run`

This alone fixes the production stale-connection crash, independent of the sync redesign.

### Phase 2: Sync adapter abstraction

- [ ] Define `AshXTDB.SyncAdapter` behaviour
- [ ] Add application config: `config :ash_xtdb, sync_adapter: {module, opts}`
- [ ] Modify `SyncHook.default_sync/4` to dispatch through the configured adapter
- [ ] Remove the old direct sync code path

### Phase 3: Built-in Oban adapter

- [ ] Add Oban as a dependency (optional or required — TBD)
- [ ] Implement `AshXTDB.SyncAdapters.Oban` implementing the behaviour
- [ ] Implement `AshXTDB.SyncWorker` Oban worker
- [ ] Handle data serialization (UUIDs, DateTimes → strings for JSON)
- [ ] Handle `String.to_existing_atom/1` for history resource module resolution
- [ ] Pass tenant through job args
- [ ] Extract `_valid_from` from record timestamps

### Phase 4: Delete handling

- [ ] Implement temporal DELETE in the worker: `DELETE FOR PORTION OF VALID_TIME FROM T`
- [ ] The History resource needs a `:delete_sync` action that generates this SQL
- [ ] Capture the destroy timestamp in the SyncHook (before the record is gone)
- [ ] Verify idempotency of DELETE retries

### Phase 5: Documentation & migration

- [ ] Document the sync adapter config
- [ ] Document Oban queue requirements (max_concurrency: 1)
- [ ] Document the `_valid_from` timestamp strategy
- [ ] Provide a mix task for initial backfill (sync all PostgreSQL records to XTDB)
- [ ] Add a health check tool (compare PG vs XTDB record counts per resource)
- [ ] Update CLAUDE.md in ash_xtdb with new architecture notes

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Oban job permanently fails after all retries | Low | Medium | Dead letter monitoring; backfill mix task for recovery |
| XTDB data drifts from PostgreSQL | Low | Medium | Periodic reconciliation job; backfill tool |
| Single-concurrency bottleneck | Very Low | Low | MissionHub has ~50 users; upgrade to partitioned queues if ever needed |
| Out-of-order within same PG transaction | None | N/A | Same `scheduled_at`, processed by insertion `id` order |
| Module atom not found (`to_existing_atom`) | None | N/A | History modules are compiled at boot, atoms exist |

## Future Enhancements (out of scope)

- **Per-record partitioned queues**: For high-throughput apps, use Oban Pro or custom partitioning to allow concurrency while maintaining per-record ordering
- **Guard SELECT fallback**: For concurrent processing, use the tested guard approach (SELECT existing `_valid_to` → bounded vs unbounded INSERT)
- **Batch sync**: Combine multiple sync operations from the same transaction into a single XTDB statement batch
- **Drift detection worker**: Periodic Oban job that compares PostgreSQL and XTDB record counts and reports discrepancies
