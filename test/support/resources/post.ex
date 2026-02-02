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

    attribute :category_id, :uuid do
      public? true
    end

    attribute :view_count, :integer do
      default 0
      public? true
    end

    attribute :published, :boolean do
      default false
      public? true
    end
  end

  relationships do
    belongs_to :user, AshXTDB.Test.User do
      source_attribute :user_id
      destination_attribute :id
      define_attribute? false
    end

    belongs_to :category, AshXTDB.Test.Category do
      source_attribute :category_id
      destination_attribute :id
      define_attribute? false
    end

    has_many :comments, AshXTDB.Test.Comment do
      destination_attribute :post_id
    end

    many_to_many :tags, AshXTDB.Test.Tag do
      through AshXTDB.Test.PostTag
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :tag_id
    end
  end

  aggregates do
    count :comment_count, :comments
    count :approved_comment_count, :comments do
      filter expr(approved == true)
    end
    count :tag_count, :tags
    sum :total_likes, :comments, :likes
  end

  calculations do
    calculate :title_lower, :string, expr(string_downcase(title))
    calculate :has_body, :boolean, expr(not is_nil(body))
    calculate :preview, :string, expr(if(is_nil(body), title, body))
    calculate :title_length, :integer, expr(string_length(title))
    calculate :is_popular, :boolean, expr(view_count >= 100)
    calculate :engagement_level, :string, expr(
      cond do
        view_count >= 1000 -> "Viral"
        view_count >= 100 -> "Popular"
        view_count >= 10 -> "Active"
        true -> "New"
      end
    )
    calculate :is_complete, :boolean, expr(
      not is_nil(body) and published == true and not is_nil(category_id)
    )
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
