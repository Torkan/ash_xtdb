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

    attribute :active, :boolean do
      default true
      public? true
    end

    attribute :employee_count, :integer do
      public? true
    end
  end

  relationships do
    has_many :users, AshXTDB.Test.User do
      destination_attribute :organization_id
    end

    has_many :projects, AshXTDB.Test.Project do
      destination_attribute :organization_id
    end
  end

  aggregates do
    count :user_count, :users
    count :active_user_count, :users do
      filter expr(active == true)
    end
    count :project_count, :projects
    count :active_project_count, :projects do
      filter expr(active == true)
    end
  end

  calculations do
    calculate :name_lower, :string, expr(string_downcase(name))
    calculate :industry_or_default, :string, expr(if(is_nil(industry), "Unknown", industry))
    calculate :name_with_industry, :string, expr(name <> " - " <> if(is_nil(industry), "N/A", industry))
    calculate :is_tech, :boolean, expr(industry == "Technology")
    calculate :name_length, :integer, expr(string_length(name))
    calculate :size_category, :string, expr(
      cond do
        is_nil(employee_count) -> "Unknown"
        employee_count < 50 -> "Small"
        employee_count < 200 -> "Medium"
        true -> "Large"
      end
    )
    calculate :is_active_tech, :boolean, expr(active == true and industry == "Technology")
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
