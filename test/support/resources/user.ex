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

    has_many :comments, AshXTDB.Test.Comment do
      destination_attribute :author_id
    end

    has_many :user_projects, AshXTDB.Test.UserProject do
      destination_attribute :user_id
    end

    many_to_many :projects, AshXTDB.Test.Project do
      through AshXTDB.Test.UserProject
      source_attribute_on_join_resource :user_id
      destination_attribute_on_join_resource :project_id
    end
  end

  aggregates do
    count :post_count, :posts
    count :comment_count, :comments
    count :project_count, :projects
    count :published_post_count, :posts do
      filter expr(published == true)
    end
  end

  calculations do
    calculate :display_name, :string, expr(if(is_nil(name), email, name))
    calculate :name_lower, :string, expr(string_downcase(name))
    calculate :is_adult, :boolean, expr(age >= 18)
    calculate :age_bracket, :string,
      expr(
        cond do
          age < 18 -> "Minor"
          age < 30 -> "Young Adult"
          age < 50 -> "Middle Age"
          true -> "Senior"
        end
      )
    calculate :name_length, :integer, expr(string_length(name))
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
