defmodule AshXTDB.SyncAdapters.ObanTest do
  use ExUnit.Case, async: true

  alias AshXTDB.SyncAdapters.Oban, as: ObanAdapter

  describe "enqueue_sync/5" do
    test "returns error when Oban is not running" do
      result =
        ObanAdapter.enqueue_sync(
          SomeModule.History,
          :create,
          %{id: "abc-123", name: "test"},
          %{action_name: :create, actor: nil, tenant: nil, valid_from: nil, valid_to: nil},
          oban: NonExistentOban, queue: :xtdb_sync
        )

      assert {:error, message} = result
      assert message =~ "Oban not running"
    end
  end
end
