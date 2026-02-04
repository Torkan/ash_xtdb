defmodule AshXTDB.TemporalAttributesTest do
  use ExUnit.Case, async: true

  defmodule TestDomain do
    use Ash.Domain

    resources do
      resource AshXTDB.TemporalAttributesTest.PublicTemporalResource
      resource AshXTDB.TemporalAttributesTest.PrivateTemporalResource
    end
  end

  defmodule PublicTemporalResource do
    use Ash.Resource,
      domain: AshXTDB.TemporalAttributesTest.TestDomain,
      data_layer: AshXTDB.DataLayer

    xtdb do
      repo AshXTDB.TestRepo
      table "public_temporal"
      valid_from_public?(true)
      valid_to_public?(true)
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end
  end

  defmodule PrivateTemporalResource do
    use Ash.Resource,
      domain: AshXTDB.TemporalAttributesTest.TestDomain,
      data_layer: AshXTDB.DataLayer

    xtdb do
      repo AshXTDB.TestRepo
      table "private_temporal"
      # defaults: valid_from_public? false, valid_to_public? false
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end
  end

  describe "temporal attributes" do
    test "adds _valid_from and _valid_to attributes" do
      attrs = Ash.Resource.Info.attributes(PublicTemporalResource)
      attr_names = Enum.map(attrs, & &1.name)

      assert :_valid_from in attr_names
      assert :_valid_to in attr_names
    end

    test "temporal attributes have correct type" do
      valid_from = Ash.Resource.Info.attribute(PublicTemporalResource, :_valid_from)
      valid_to = Ash.Resource.Info.attribute(PublicTemporalResource, :_valid_to)

      assert valid_from.type == Ash.Type.UtcDatetimeUsec
      assert valid_to.type == Ash.Type.UtcDatetimeUsec
    end

    test "temporal attributes are not writable" do
      valid_from = Ash.Resource.Info.attribute(PublicTemporalResource, :_valid_from)
      valid_to = Ash.Resource.Info.attribute(PublicTemporalResource, :_valid_to)

      assert valid_from.writable? == false
      assert valid_to.writable? == false
    end

    test "respects valid_from_public? true setting" do
      valid_from = Ash.Resource.Info.attribute(PublicTemporalResource, :_valid_from)
      assert valid_from.public? == true
    end

    test "respects valid_to_public? true setting" do
      valid_to = Ash.Resource.Info.attribute(PublicTemporalResource, :_valid_to)
      assert valid_to.public? == true
    end

    test "defaults to private when not specified" do
      valid_from = Ash.Resource.Info.attribute(PrivateTemporalResource, :_valid_from)
      valid_to = Ash.Resource.Info.attribute(PrivateTemporalResource, :_valid_to)

      assert valid_from.public? == false
      assert valid_to.public? == false
    end

    test "Info helpers return correct values" do
      assert AshXTDB.DataLayer.Info.valid_from_public?(PublicTemporalResource) == true
      assert AshXTDB.DataLayer.Info.valid_to_public?(PublicTemporalResource) == true

      assert AshXTDB.DataLayer.Info.valid_from_public?(PrivateTemporalResource) == false
      assert AshXTDB.DataLayer.Info.valid_to_public?(PrivateTemporalResource) == false
    end
  end
end
