# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.User do
  @moduledoc """
  Test user resource for XTDB integration tests.
  """

  use Ash.Resource,
    domain: AshXTDB.Test.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo AshXTDB.TestRepo
    table "users"
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      public? true
    end

    attribute :age, :integer do
      public? true
    end

    attribute :active, :boolean do
      default true
      public? true
    end

    attribute :organization_id, :uuid do
      public? true
    end
  end

  relationships do
    belongs_to :organization, AshXTDB.Test.Organization do
      source_attribute :organization_id
      destination_attribute :id
      define_attribute? false
    end

    has_many :posts, AshXTDB.Test.Post do
      destination_attribute :user_id
    end
  end

  actions do
    defaults create: :*, update: :*

    read :read do
      primary? true

      pagination do
        keyset? true
        offset? true
        countable true
        required? false
      end
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end
end
