# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.Organization do
  @moduledoc """
  Test organization resource for relationship tests.
  """

  use Ash.Resource,
    domain: AshXTDB.Test.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo AshXTDB.TestRepo
    table "organizations"
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :industry, :string do
      public? true
    end
  end

  relationships do
    has_many :users, AshXTDB.Test.User do
      destination_attribute :organization_id
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
