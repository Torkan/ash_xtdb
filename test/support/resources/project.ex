# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.Project do
  @moduledoc """
  Test project resource for cross-cutting relationships.
  Projects belong to organizations and have many users via UserProject.
  """

  use Ash.Resource,
    domain: AshXTDB.Test.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo AshXTDB.TestRepo
    table "projects"
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :code, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :string do
      default "planning"
      public? true
    end

    attribute :budget, :integer do
      public? true
    end

    attribute :active, :boolean do
      default true
      public? true
    end

    attribute :organization_id, :uuid do
      allow_nil? false
      public? true
    end
  end

  relationships do
    belongs_to :organization, AshXTDB.Test.Organization do
      source_attribute :organization_id
      destination_attribute :id
      define_attribute? false
    end

    has_many :user_projects, AshXTDB.Test.UserProject do
      destination_attribute :project_id
    end

    many_to_many :members, AshXTDB.Test.User do
      through AshXTDB.Test.UserProject
      source_attribute_on_join_resource :project_id
      destination_attribute_on_join_resource :user_id
    end
  end

  aggregates do
    count :member_count, :members
    count :active_member_count, :members do
      filter expr(active == true)
    end
    sum :total_budget_allocated, :user_projects, :hours_allocated
  end

  calculations do
    calculate :name_lower, :string, expr(string_downcase(name))
    calculate :code_upper, :string, expr(string_upcase(code))
    calculate :is_active_project, :boolean, expr(active == true and status != "completed")
    calculate :budget_category, :string, expr(
      cond do
        is_nil(budget) -> "Unbudgeted"
        budget < 10000 -> "Small"
        budget < 100000 -> "Medium"
        budget < 1000000 -> "Large"
        true -> "Enterprise"
      end
    )
    calculate :status_priority, :integer, expr(
      cond do
        status == "active" -> 1
        status == "planning" -> 2
        status == "on_hold" -> 3
        status == "completed" -> 4
        true -> 5
      end
    )
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
