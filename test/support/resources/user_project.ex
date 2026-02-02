# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.UserProject do
  @moduledoc """
  Join table for User <-> Project many-to-many relationship.
  Includes additional attributes like role and hours_allocated.
  """

  use Ash.Resource,
    domain: AshXTDB.Test.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo AshXTDB.TestRepo
    table "user_projects"
  end

  attributes do
    uuid_primary_key :id

    attribute :user_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :project_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :role, :string do
      default "member"
      public? true
    end

    attribute :hours_allocated, :integer do
      default 0
      public? true
    end

    attribute :active, :boolean do
      default true
      public? true
    end
  end

  relationships do
    belongs_to :user, AshXTDB.Test.User do
      source_attribute :user_id
      destination_attribute :id
      define_attribute? false
    end

    belongs_to :project, AshXTDB.Test.Project do
      source_attribute :project_id
      destination_attribute :id
      define_attribute? false
    end
  end

  calculations do
    calculate :is_lead, :boolean, expr(role in ["lead", "manager", "owner"])
    calculate :commitment_level, :string, expr(
      cond do
        hours_allocated >= 40 -> "Full-time"
        hours_allocated >= 20 -> "Part-time"
        hours_allocated >= 5 -> "Contributing"
        true -> "Minimal"
      end
    )
    calculate :role_priority, :integer, expr(
      cond do
        role == "owner" -> 1
        role == "manager" -> 2
        role == "lead" -> 3
        role == "senior" -> 4
        role == "member" -> 5
        true -> 6
      end
    )
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
