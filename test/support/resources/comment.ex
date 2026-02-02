# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.Comment do
  @moduledoc """
  Test comment resource for deep nesting tests.
  Comments belong to posts and users, enabling 4-level traversals.
  """

  use Ash.Resource,
    domain: AshXTDB.Test.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo AshXTDB.TestRepo
    table "comments"
  end

  attributes do
    uuid_primary_key :id

    attribute :content, :string do
      allow_nil? false
      public? true
    end

    attribute :approved, :boolean do
      default false
      public? true
    end

    attribute :likes, :integer do
      default 0
      public? true
    end

    attribute :post_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :author_id, :uuid do
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

    belongs_to :author, AshXTDB.Test.User do
      source_attribute :author_id
      destination_attribute :id
      define_attribute? false
    end
  end

  calculations do
    calculate :content_length, :integer, expr(string_length(content))
    calculate :is_popular, :boolean, expr(likes >= 10)
    calculate :status, :string, expr(if(approved, "approved", "pending"))
    calculate :preview, :string, expr(
      if(string_length(content) > 50,
        string_slice(content, 0, 47) <> "...",
        content
      )
    )
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
