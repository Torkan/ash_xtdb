# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.Tag do
  @moduledoc """
  Test tag resource for many-to-many relationship tests.
  """

  use Ash.Resource,
    domain: AshXTDB.Test.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo AshXTDB.TestRepo
    table "tags"
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :color, :string do
      public? true
    end

    attribute :priority, :integer do
      default 0
      public? true
    end
  end

  relationships do
    many_to_many :posts, AshXTDB.Test.Post do
      through AshXTDB.Test.PostTag
      source_attribute_on_join_resource :tag_id
      destination_attribute_on_join_resource :post_id
    end
  end

  aggregates do
    count :post_count, :posts

    count :published_post_count, :posts do
      filter expr(published == true)
    end
  end

  calculations do
    calculate :name_lower, :string, expr(string_downcase(name))
    calculate :name_length, :integer, expr(string_length(name))
    calculate :is_featured, :boolean, expr(priority >= 100)

    calculate :display_name,
              :string,
              expr(
                if(
                  is_nil(color),
                  name,
                  "[" <> color <> "] " <> name
                )
              )
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
