defmodule AshXTDB.SyncResourceTest do
  use ExUnit.Case, async: false

  defmodule SyncTracker do
    use Agent

    def start_link(_) do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def track(resource, action_type, data, context) do
      Agent.update(__MODULE__, fn calls ->
        [{resource, action_type, data, context} | calls]
      end)
      :ok
    end

    def get_calls do
      Agent.get(__MODULE__, & &1)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> [] end)
    end
  end

  defmodule TestDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshXTDB.SyncResourceTest.SyncedResource
      resource AshXTDB.SyncResourceTest.SkipActionResource
    end
  end

  defmodule SyncedResource do
    use Ash.Resource,
      domain: AshXTDB.SyncResourceTest.TestDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshXTDB.SyncResource]

    xtdb_sync do
      sync_function &AshXTDB.SyncResourceTest.SyncTracker.track/4
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        accept [:name]
      end

      update :update do
        accept [:name]
      end
    end
  end

  defmodule SkipActionResource do
    use Ash.Resource,
      domain: AshXTDB.SyncResourceTest.TestDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshXTDB.SyncResource]

    xtdb_sync do
      sync_function &AshXTDB.SyncResourceTest.SyncTracker.track/4
      skip_actions [:import]
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        accept [:name]
      end

      create :import do
        accept [:name]
      end
    end
  end

  setup do
    start_supervised!(SyncTracker)
    SyncTracker.reset()
    :ok
  end

  describe "sync hooks" do
    test "calls sync function on create" do
      {:ok, record} =
        SyncedResource
        |> Ash.Changeset.for_create(:create, %{name: "test"})
        |> Ash.create()

      calls = SyncTracker.get_calls()
      assert length(calls) == 1

      [{resource, action_type, data, context}] = calls
      assert resource == SyncedResource
      assert action_type == :create
      assert data.name == "test"
      assert data.id == record.id
      assert context.action_name == :create
    end

    test "calls sync function on update" do
      {:ok, record} =
        SyncedResource
        |> Ash.Changeset.for_create(:create, %{name: "test"})
        |> Ash.create()

      SyncTracker.reset()

      {:ok, updated} =
        record
        |> Ash.Changeset.for_update(:update, %{name: "updated"})
        |> Ash.update()

      calls = SyncTracker.get_calls()
      assert length(calls) == 1

      [{resource, action_type, data, context}] = calls
      assert resource == SyncedResource
      assert action_type == :update
      assert data.name == "updated"
      assert data.id == updated.id
      assert context.action_name == :update
    end

    test "calls sync function on destroy with primary key only" do
      {:ok, record} =
        SyncedResource
        |> Ash.Changeset.for_create(:create, %{name: "test"})
        |> Ash.create()

      record_id = record.id
      SyncTracker.reset()

      :ok = Ash.destroy!(record)

      calls = SyncTracker.get_calls()
      assert length(calls) == 1

      [{resource, action_type, data, context}] = calls
      assert resource == SyncedResource
      assert action_type == :destroy
      assert data == %{id: record_id}
      assert context.action_name == :destroy
    end
  end

  describe "skip_actions" do
    test "skips configured actions" do
      {:ok, _record} =
        SkipActionResource
        |> Ash.Changeset.for_create(:import, %{name: "imported"})
        |> Ash.create()

      calls = SyncTracker.get_calls()
      assert calls == []
    end

    test "still syncs non-skipped actions" do
      {:ok, _record} =
        SkipActionResource
        |> Ash.Changeset.for_create(:create, %{name: "created"})
        |> Ash.create()

      calls = SyncTracker.get_calls()
      assert length(calls) == 1
    end
  end

  describe "context skip" do
    test "skips sync when skip_xtdb_sync context is set" do
      {:ok, _record} =
        SyncedResource
        |> Ash.Changeset.for_create(:create, %{name: "test"})
        |> Ash.Changeset.set_context(%{skip_xtdb_sync: true})
        |> Ash.create()

      calls = SyncTracker.get_calls()
      assert calls == []
    end
  end

  describe "custom temporal values" do
    test "passes valid_from from context" do
      valid_from = ~U[2024-01-01 00:00:00Z]

      {:ok, _record} =
        SyncedResource
        |> Ash.Changeset.for_create(:create, %{name: "test"})
        |> Ash.Changeset.set_context(%{xtdb_valid_from: valid_from})
        |> Ash.create()

      [{_resource, _action_type, _data, context}] = SyncTracker.get_calls()
      assert context.valid_from == valid_from
    end

    test "passes valid_to from context" do
      valid_to = ~U[2024-12-31 23:59:59Z]

      {:ok, _record} =
        SyncedResource
        |> Ash.Changeset.for_create(:create, %{name: "test"})
        |> Ash.Changeset.set_context(%{xtdb_valid_to: valid_to})
        |> Ash.create()

      [{_resource, _action_type, _data, context}] = SyncTracker.get_calls()
      assert context.valid_to == valid_to
    end
  end

  describe "Info module" do
    test "sync_function returns the configured function" do
      assert {:ok, fun} = AshXTDB.SyncResource.Info.sync_function(SyncedResource)
      assert is_function(fun, 4)
    end

    test "skip_actions returns the configured list" do
      assert AshXTDB.SyncResource.Info.skip_actions(SkipActionResource) == [:import]
      assert AshXTDB.SyncResource.Info.skip_actions(SyncedResource) == []
    end

    test "sync_action? returns correct value" do
      assert AshXTDB.SyncResource.Info.sync_action?(SkipActionResource, :create) == true
      assert AshXTDB.SyncResource.Info.sync_action?(SkipActionResource, :import) == false
    end

    test "history_resource defaults to <Resource>.History" do
      # SyncedResource doesn't set history_resource, so it should default
      assert AshXTDB.SyncResource.Info.history_resource(SyncedResource) ==
               AshXTDB.SyncResourceTest.SyncedResource.History
    end
  end

  describe "default history resource" do
    defmodule DefaultSyncDomain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource AshXTDB.SyncResourceTest.DefaultSyncResource
      end
    end

    defmodule DefaultSyncResource do
      use Ash.Resource,
        domain: AshXTDB.SyncResourceTest.DefaultSyncDomain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshXTDB.SyncResource]

      # No xtdb_sync block - uses all defaults
      xtdb_sync do
        # Use custom function to avoid needing a real history resource
        sync_function &AshXTDB.SyncResourceTest.SyncTracker.track/4
      end

      attributes do
        uuid_primary_key :id
        attribute :name, :string, public?: true
      end

      actions do
        defaults [:read]

        create :create do
          accept [:name]
        end
      end
    end

    test "works with minimal configuration" do
      {:ok, record} =
        DefaultSyncResource
        |> Ash.Changeset.for_create(:create, %{name: "test"})
        |> Ash.create()

      calls = SyncTracker.get_calls()
      assert length(calls) == 1

      [{resource, action_type, data, _context}] = calls
      assert resource == DefaultSyncResource
      assert action_type == :create
      assert data.id == record.id
    end
  end
end
