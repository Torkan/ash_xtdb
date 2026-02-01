# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.PostWithTenant do
  @moduledoc """
  Test post resource with attribute-based multitenancy.
  """

  use Ash.Resource,
    domain: AshXTDB.Test.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo AshXTDB.TestRepo
    table "posts_with_tenant"
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :body, :string do
      public? true
    end

    attribute :org_id, :string do
      # allow_nil? true for multitenancy - Ash sets it from tenant
      allow_nil? true
      public? true
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
