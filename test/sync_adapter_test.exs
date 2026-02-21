defmodule AshXTDB.SyncAdapterTest do
  use ExUnit.Case, async: false

  alias AshXTDB.SyncResource.Changes.SyncHook

  describe "get_sync_adapter/0" do
    test "defaults to Oban adapter when no config" do
      original = Application.get_env(:ash_xtdb, :sync_adapter)

      try do
        Application.delete_env(:ash_xtdb, :sync_adapter)
        assert {AshXTDB.SyncAdapters.Oban, []} = SyncHook.get_sync_adapter()
      after
        if original, do: Application.put_env(:ash_xtdb, :sync_adapter, original)
      end
    end

    test "reads {module, opts} tuple from config" do
      original = Application.get_env(:ash_xtdb, :sync_adapter)

      try do
        Application.put_env(
          :ash_xtdb,
          :sync_adapter,
          {AshXTDB.SyncAdapters.Oban, oban: MyApp.Oban, queue: :custom}
        )

        assert {AshXTDB.SyncAdapters.Oban, [oban: MyApp.Oban, queue: :custom]} =
                 SyncHook.get_sync_adapter()
      after
        if original do
          Application.put_env(:ash_xtdb, :sync_adapter, original)
        else
          Application.delete_env(:ash_xtdb, :sync_adapter)
        end
      end
    end

    test "reads bare module from config" do
      original = Application.get_env(:ash_xtdb, :sync_adapter)

      try do
        Application.put_env(:ash_xtdb, :sync_adapter, AshXTDB.SyncAdapters.Oban)

        assert {AshXTDB.SyncAdapters.Oban, []} = SyncHook.get_sync_adapter()
      after
        if original do
          Application.put_env(:ash_xtdb, :sync_adapter, original)
        else
          Application.delete_env(:ash_xtdb, :sync_adapter)
        end
      end
    end
  end

  defmodule TestAdapter do
    @behaviour AshXTDB.SyncAdapter

    @impl true
    def enqueue_sync(history_resource, action_type, data, context, opts) do
      send(opts[:test_pid], {:enqueued, history_resource, action_type, data, context})
      :ok
    end
  end

  defmodule AdapterTestDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshXTDB.SyncAdapterTest.AdapterTestResource
    end
  end

  defmodule AdapterTestResource do
    use Ash.Resource,
      domain: AshXTDB.SyncAdapterTest.AdapterTestDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshXTDB.SyncResource]

    xtdb_sync do
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

  describe "SyncAdapter behaviour" do
    test "custom adapter receives correct arguments" do
      original = Application.get_env(:ash_xtdb, :sync_adapter)

      try do
        Application.put_env(
          :ash_xtdb,
          :sync_adapter,
          {TestAdapter, test_pid: self()}
        )

        {:ok, record} =
          AdapterTestResource
          |> Ash.Changeset.for_create(:create, %{name: "adapter_test"})
          |> Ash.create()

        assert_received {:enqueued, history_resource, :create, data, context}
        assert history_resource == AshXTDB.SyncAdapterTest.AdapterTestResource.History
        assert data.name == "adapter_test"
        assert data._id == record.id
        assert context.action_name == :create
      after
        if original do
          Application.put_env(:ash_xtdb, :sync_adapter, original)
        else
          Application.delete_env(:ash_xtdb, :sync_adapter)
        end
      end
    end
  end
end
