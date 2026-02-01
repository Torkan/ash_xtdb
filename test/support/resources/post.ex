# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.Post do
  @moduledoc """
  Test post resource for relationship tests.
  """

  use Ash.Resource,
    domain: AshXTDB.Test.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo AshXTDB.TestRepo
    table "posts"
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

    attribute :user_id, :uuid do
      allow_nil? false
      public? true
    end
  end

  relationships do
    belongs_to :user, AshXTDB.Test.User do
      source_attribute :user_id
      destination_attribute :id
      define_attribute? false
    end

    many_to_many :tags, AshXTDB.Test.Tag do
      through AshXTDB.Test.PostTag
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :tag_id
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
