# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.PostTag do
  @moduledoc """
  Join table resource for Post <-> Tag many-to-many relationship.
  """

  use Ash.Resource,
    domain: AshXTDB.Test.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo AshXTDB.TestRepo
    table "post_tags"
  end

  attributes do
    uuid_primary_key :id

    attribute :post_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :tag_id, :uuid do
      allow_nil? false
      public? true
    end
  end

  relationships do
    belongs_to :post, AshXTDB.Test.Post do
      source_attribute :post_id
      destination_attribute :id
      define_attribute? false
    end

    belongs_to :tag, AshXTDB.Test.Tag do
      source_attribute :tag_id
      destination_attribute :id
      define_attribute? false
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
