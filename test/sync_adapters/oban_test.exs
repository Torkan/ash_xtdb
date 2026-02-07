defmodule AshXTDB.SyncAdapters.ObanTest do
  use ExUnit.Case, async: true

  alias AshXTDB.SyncAdapters.Oban, as: ObanAdapter

  defmodule TestResource do
    use Ash.Resource,
      domain: AshXTDB.SyncAdapters.ObanTest.TestDomain,
      data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      defaults [:read, :create]
    end
  end

  defmodule TestDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshXTDB.SyncAdapters.ObanTest.TestResource
    end
  end

  describe "enqueue_sync/5" do
    test "returns error when Oban is not running" do
      result =
        ObanAdapter.enqueue_sync(
          SomeModule.History,
          :create,
          %{id: "abc-123", name: "test"},
          %{
            action_name: :create,
            actor: nil,
            tenant: nil,
            resource: TestResource,
            valid_from: nil,
            valid_to: nil
          },
          oban: NonExistentOban,
          queue: :xtdb_sync
        )

      assert {:error, message} = result
      assert message =~ "Oban not running"
    end
  end
end
