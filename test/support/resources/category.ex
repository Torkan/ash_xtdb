# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.Category do
  @moduledoc """
  Test category resource for hierarchical categorization.
  Categories can have parent categories (self-referential) and contain posts.
  """

  use Ash.Resource,
    domain: AshXTDB.Test.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo AshXTDB.TestRepo
    table "categories"
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :active, :boolean do
      default true
      public? true
    end

    attribute :priority, :integer do
      default 0
      public? true
    end

    attribute :parent_id, :uuid do
      public? true
    end
  end

  relationships do
    belongs_to :parent, __MODULE__ do
      source_attribute :parent_id
      destination_attribute :id
      define_attribute? false
    end

    has_many :children, __MODULE__ do
      destination_attribute :parent_id
    end

    has_many :posts, AshXTDB.Test.Post do
      destination_attribute :category_id
    end
  end

  aggregates do
    count :post_count, :posts
    count :child_count, :children

    count :active_post_count, :posts do
      filter expr(not is_nil(body))
    end
  end

  calculations do
    calculate :name_lower, :string, expr(string_downcase(name))
    calculate :is_root, :boolean, expr(is_nil(parent_id))

    calculate :display_name,
              :string,
              expr(
                if(
                  is_nil(description),
                  name,
                  name <> " - " <> description
                )
              )

    calculate :priority_level,
              :string,
              expr(
                cond do
                  priority >= 100 -> "Critical"
                  priority >= 50 -> "High"
                  priority >= 10 -> "Medium"
                  true -> "Low"
                end
              )
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
