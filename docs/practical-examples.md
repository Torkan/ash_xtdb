# Practical Examples: PostgreSQL + XTDB

Real-world scenarios demonstrating the dual-database architecture with PostgreSQL
for current state and XTDB for historical queries.

## Healthcare - Out-of-Order Event Processing

Handle prescription and medication order events from external partners that arrive
late or out of order, while maintaining a historically accurate timeline.

### The Problem

External pharmacy partners send webhooks for:
- Prescription creation
- Order confirmation
- Shipping updates
- Delivery confirmation

When partner systems have outages, events arrive late and often out of chronological
order. For example, you might receive a "delivered" event before the "shipped" event.

**XTDB's solution:** Use valid time (`_valid_from`) to record when events *actually
occurred* (from the webhook payload), while system time automatically tracks when
we *recorded* them. This gives us two distinct timelines.

### Resources

```elixir
defmodule MyHealth.Schemas.PrescriptionAttributes do
  defmacro __using__(_) do
    quote do
      attribute :prescription_number, :string, allow_nil?: false, public?: true
      attribute :patient_id, :uuid, allow_nil?: false, public?: true
      attribute :prescriber_id, :uuid, allow_nil?: false, public?: true
      attribute :medication_name, :string, allow_nil?: false, public?: true
      attribute :dosage, :string, public?: true
      attribute :quantity, :integer, public?: true
      attribute :refills_remaining, :integer, default: 0, public?: true
      attribute :status, :atom, default: :pending, public?: true
      # Valid statuses: :pending, :confirmed, :processing, :shipped, :delivered, :cancelled

      attribute :prescribed_at, :utc_datetime, public?: true
      attribute :confirmed_at, :utc_datetime, public?: true
      attribute :shipped_at, :utc_datetime, public?: true
      attribute :delivered_at, :utc_datetime, public?: true
      attribute :tracking_number, :string, public?: true
      attribute :partner_reference_id, :string, public?: true

      timestamps()
    end
  end
end

defmodule MyHealth.Prescription do
  use Ash.Resource,
    domain: MyHealth.Domain,
    data_layer: AshPostgres.DataLayer,
    notifiers: [MyHealth.Notifiers.XTDBSync]

  postgres do
    repo MyHealth.Repo
    table "prescriptions"
  end

  attributes do
    uuid_primary_key :id
    use MyHealth.Schemas.PrescriptionAttributes
  end

  identities do
    identity :unique_prescription_number, [:prescription_number]
    identity :partner_reference, [:partner_reference_id]
  end

  actions do
    defaults [:read, create: :*, update: :*]

    # Standard actions update PostgreSQL (current state)
    update :confirm do
      argument :confirmed_at, :utc_datetime, allow_nil?: false
      change set_attribute(:status, :confirmed)
      change set_attribute(:confirmed_at, arg(:confirmed_at))
    end

    update :ship do
      argument :shipped_at, :utc_datetime, allow_nil?: false
      argument :tracking_number, :string

      change set_attribute(:status, :shipped)
      change set_attribute(:shipped_at, arg(:shipped_at))
      change set_attribute(:tracking_number, arg(:tracking_number))
    end

    update :deliver do
      argument :delivered_at, :utc_datetime, allow_nil?: false
      change set_attribute(:status, :delivered)
      change set_attribute(:delivered_at, arg(:delivered_at))
    end
  end
end
```

### Webhook Handler with Valid Time

```elixir
defmodule MyHealth.Webhooks.PharmacyPartner do
  @moduledoc """
  Handles webhooks from pharmacy partners.

  Key insight: The `event_timestamp` from the webhook payload tells us when
  the event ACTUALLY happened. We use this as the valid time in XTDB,
  regardless of when we receive and process the webhook.
  """

  alias AshXTDB.Temporal

  def handle_webhook(%{"event_type" => type, "payload" => payload, "event_timestamp" => ts}) do
    # Parse the actual event time from the webhook
    {:ok, event_time, _} = DateTime.from_iso8601(ts)

    case type do
      "prescription.created" -> handle_prescription_created(payload, event_time)
      "order.confirmed" -> handle_order_confirmed(payload, event_time)
      "order.shipped" -> handle_order_shipped(payload, event_time)
      "order.delivered" -> handle_order_delivered(payload, event_time)
      _ -> {:error, :unknown_event_type}
    end
  end

  defp handle_prescription_created(payload, event_time) do
    attrs = %{
      prescription_number: payload["prescription_number"],
      patient_id: payload["patient_id"],
      prescriber_id: payload["prescriber_id"],
      medication_name: payload["medication_name"],
      dosage: payload["dosage"],
      quantity: payload["quantity"],
      refills_remaining: payload["refills"],
      status: :pending,
      prescribed_at: event_time,
      partner_reference_id: payload["reference_id"]
    }

    # Create in PostgreSQL (current state)
    {:ok, prescription} =
      MyHealth.Prescription
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create()

    # The XTDBSync notifier will replicate to XTDB with valid_from = event_time
    # This ensures the historical record reflects when it was prescribed,
    # not when we received the webhook

    {:ok, prescription}
  end

  defp handle_order_confirmed(payload, event_time) do
    prescription = get_prescription!(payload["prescription_number"])

    # Update PostgreSQL with current state
    {:ok, updated} =
      prescription
      |> Ash.Changeset.for_update(:confirm, %{confirmed_at: event_time})
      |> Ash.update()

    # Sync to XTDB with the actual confirmation time as valid_from
    sync_to_xtdb_with_valid_time(updated, event_time)

    {:ok, updated}
  end

  defp handle_order_shipped(payload, event_time) do
    prescription = get_prescription!(payload["prescription_number"])

    {:ok, updated} =
      prescription
      |> Ash.Changeset.for_update(:ship, %{
        shipped_at: event_time,
        tracking_number: payload["tracking_number"]
      })
      |> Ash.update()

    sync_to_xtdb_with_valid_time(updated, event_time)

    {:ok, updated}
  end

  defp handle_order_delivered(payload, event_time) do
    prescription = get_prescription!(payload["prescription_number"])

    {:ok, updated} =
      prescription
      |> Ash.Changeset.for_update(:deliver, %{delivered_at: event_time})
      |> Ash.update()

    sync_to_xtdb_with_valid_time(updated, event_time)

    {:ok, updated}
  end

  defp get_prescription!(prescription_number) do
    MyHealth.Prescription
    |> Ash.Query.filter(prescription_number == ^prescription_number)
    |> Ash.read_one!()
  end

  defp sync_to_xtdb_with_valid_time(record, event_time) do
    # This inserts into XTDB with _valid_from set to the actual event time
    # System time is automatically set to "now" (when we're recording it)
    MyHealth.XTDBSyncWorker.sync_with_valid_time(record, event_time)
  end
end
```

### XTDB Sync Worker with Valid Time

```elixir
defmodule MyHealth.XTDBSyncWorker do
  @moduledoc """
  Syncs records to XTDB with explicit valid time.

  This allows us to record events with their actual occurrence time,
  even when processing webhooks that arrived late or out of order.
  """

  use Oban.Worker, queue: :xtdb_sync

  alias AshXTDB.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"record" => record, "valid_from" => valid_from_iso}}) do
    {:ok, valid_from, _} = DateTime.from_iso8601(valid_from_iso)

    table = "prescriptions"
    record_map = Map.new(record, fn {k, v} -> {String.to_atom(k), v} end)

    # Build INSERT with explicit _valid_from
    {sql, params} = Query.build_insert_with_valid_from(
      table,
      record_map,
      MyHealth.History.Prescription,
      valid_from
    )

    case MyHealth.XTDBRepo.query(sql, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def sync_with_valid_time(record, %DateTime{} = valid_from) do
    record_map =
      record
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> Map.new(fn {k, v} -> {to_string(k), serialize_value(v)} end)

    %{record: record_map, valid_from: DateTime.to_iso8601(valid_from)}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(value), do: value
end
```

### Query Use Cases

```elixir
defmodule MyHealth.Prescriptions do
  alias AshXTDB.Temporal

  @doc """
  Get the current state of a prescription (PostgreSQL - fast lookup).
  """
  def get_current(prescription_id) do
    Ash.get!(MyHealth.Prescription, prescription_id)
  end

  @doc """
  Get the prescription state as it actually was at a specific time.

  Uses VALID TIME - gives the historically accurate state regardless of
  when we recorded the data.

  Example: If we received the "shipped" webhook after the "delivered" webhook,
  querying valid time for a moment after shipping will correctly show
  status = :shipped, even though we recorded :delivered first.
  """
  def state_at(%DateTime{} = point_in_time, prescription_id) do
    MyHealth.History.Prescription
    |> Ash.Query.filter(id == ^prescription_id)
    |> Temporal.as_of_valid_time(point_in_time)
    |> Ash.read_one()
  end

  @doc """
  Get the prescription state as we knew it at a specific time.

  Uses SYSTEM TIME - shows what our system believed to be true at that moment.

  Useful for debugging: "What did we think the status was when we made that decision?"
  """
  def knowledge_at(%DateTime{} = system_point, prescription_id) do
    MyHealth.History.Prescription
    |> Ash.Query.filter(id == ^prescription_id)
    |> Temporal.as_of_system_time(system_point)
    |> Ash.read_one()
  end

  @doc """
  Get the complete timeline of a prescription's actual history.

  Ordered by VALID TIME - the events as they actually occurred.
  """
  def actual_timeline(prescription_id) do
    MyHealth.History.Prescription
    |> Ash.Query.filter(id == ^prescription_id)
    |> Temporal.for_all_valid_time()
    |> Ash.read!()
    |> Enum.sort_by(& &1.valid_time_start)
    |> Enum.map(fn version ->
      %{
        status: version.status,
        occurred_at: version.valid_time_start,
        recorded_at: version.system_time_start
      }
    end)
  end

  @doc """
  Get the timeline of when we recorded events (for debugging/auditing).

  Ordered by SYSTEM TIME - when we actually processed webhooks.
  """
  def recording_timeline(prescription_id) do
    MyHealth.History.Prescription
    |> Ash.Query.filter(id == ^prescription_id)
    |> Temporal.for_all_system_time()
    |> Ash.read!()
    |> Enum.sort_by(& &1.system_time_start)
    |> Enum.map(fn version ->
      %{
        status: version.status,
        occurred_at: version.valid_time_start,
        recorded_at: version.system_time_start,
        recording_delay: DateTime.diff(version.system_time_start, version.valid_time_start, :hour)
      }
    end)
  end

  @doc """
  Find prescriptions where events were recorded significantly out of order.

  Useful for identifying partner integration issues.
  """
  def find_out_of_order_recordings(hours_threshold \\ 24) do
    # Query all prescription history
    MyHealth.History.Prescription
    |> Temporal.for_all_system_time()
    |> Ash.read!()
    |> Enum.filter(fn version ->
      delay_hours = DateTime.diff(version.system_time_start, version.valid_time_start, :hour)
      delay_hours > hours_threshold
    end)
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {prescription_id, versions} ->
      max_delay =
        versions
        |> Enum.map(fn v -> DateTime.diff(v.system_time_start, v.valid_time_start, :hour) end)
        |> Enum.max()

      %{
        prescription_id: prescription_id,
        max_recording_delay_hours: max_delay,
        affected_events: length(versions)
      }
    end)
  end
end
```

### Real-World Scenario

```elixir
# Partner system was down from Jan 15-22, 2025.
# On Jan 23, we receive a flood of webhooks out of order:

# 10:00 AM - We receive "delivered" event (actually happened Jan 20)
MyHealth.Webhooks.PharmacyPartner.handle_webhook(%{
  "event_type" => "order.delivered",
  "event_timestamp" => "2025-01-20T14:30:00Z",
  "payload" => %{"prescription_number" => "RX-12345", ...}
})

# 10:01 AM - We receive "shipped" event (actually happened Jan 18)
MyHealth.Webhooks.PharmacyPartner.handle_webhook(%{
  "event_type" => "order.shipped",
  "event_timestamp" => "2025-01-18T09:00:00Z",
  "payload" => %{"prescription_number" => "RX-12345", "tracking_number" => "1Z999..."}
})

# 10:02 AM - We receive "confirmed" event (actually happened Jan 16)
MyHealth.Webhooks.PharmacyPartner.handle_webhook(%{
  "event_type" => "order.confirmed",
  "event_timestamp" => "2025-01-16T11:00:00Z",
  "payload" => %{"prescription_number" => "RX-12345"}
})

# Now let's query the prescription:

# PostgreSQL shows current state (delivered)
MyHealth.Prescriptions.get_current(prescription_id)
# → %Prescription{status: :delivered, ...}

# XTDB valid time query: "What was the status on Jan 17?"
MyHealth.Prescriptions.state_at(~U[2025-01-17 12:00:00Z], prescription_id)
# → %Prescription{status: :confirmed}  ✓ Correct! Even though we recorded this LAST

# XTDB valid time query: "What was the status on Jan 19?"
MyHealth.Prescriptions.state_at(~U[2025-01-19 12:00:00Z], prescription_id)
# → %Prescription{status: :shipped}  ✓ Correct! Shows shipped, not delivered

# XTDB system time query: "What did we know at 10:00:30 AM on Jan 23?"
MyHealth.Prescriptions.knowledge_at(~U[2025-01-23 10:00:30Z], prescription_id)
# → %Prescription{status: :delivered}  (We only knew about delivered at this point)

# Get the actual timeline (ordered by when events occurred)
MyHealth.Prescriptions.actual_timeline(prescription_id)
# → [
#     %{status: :pending,   occurred_at: ~U[2025-01-15 ...], recorded_at: ~U[2025-01-15 ...]},
#     %{status: :confirmed, occurred_at: ~U[2025-01-16 ...], recorded_at: ~U[2025-01-23 10:02 ...]},
#     %{status: :shipped,   occurred_at: ~U[2025-01-18 ...], recorded_at: ~U[2025-01-23 10:01 ...]},
#     %{status: :delivered, occurred_at: ~U[2025-01-20 ...], recorded_at: ~U[2025-01-23 10:00 ...]}
#   ]

# Get the recording timeline (ordered by when we recorded them)
MyHealth.Prescriptions.recording_timeline(prescription_id)
# → [
#     %{status: :pending,   occurred_at: ~U[2025-01-15 ...], recorded_at: ~U[2025-01-15 ...], recording_delay: 0},
#     %{status: :delivered, occurred_at: ~U[2025-01-20 ...], recorded_at: ~U[2025-01-23 10:00 ...], recording_delay: 68},
#     %{status: :shipped,   occurred_at: ~U[2025-01-18 ...], recorded_at: ~U[2025-01-23 10:01 ...], recording_delay: 121},
#     %{status: :confirmed, occurred_at: ~U[2025-01-16 ...], recorded_at: ~U[2025-01-23 10:02 ...], recording_delay: 167}
#   ]
```

### Key Benefits

| Capability | Without Bitemporal | With XTDB Bitemporal |
|------------|-------------------|---------------------|
| Correct historical timeline | ❌ Events ordered by recording time | ✓ Events ordered by actual occurrence |
| Answer "What was status on date X?" | ❌ May show wrong status | ✓ Always correct |
| Debug integration issues | ❌ Hard to trace | ✓ Compare valid vs system time |
| Audit trail of recordings | ❌ Lost | ✓ System time preserved |
| Handle out-of-order events | ❌ Complex custom logic | ✓ Built-in |

---

## Summary

**Key insight:** Valid time lets you query business state at any point in history
(when events *actually occurred*), while system time provides an immutable audit
trail of when changes were *recorded in your system*.

This separation is essential when:
- External systems send events late or out of order
- You need to reconstruct historical state for compliance/audits
- You need to debug "what did we know and when did we know it?"
