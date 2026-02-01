# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.UserWithCalculations do
  @moduledoc """
  Test user resource with calculations for XTDB integration tests.
  """

  use Ash.Resource,
    domain: AshXTDB.Test.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo AshXTDB.TestRepo
    table "users_with_calculations"
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :string do
      allow_nil? false
      public? true
    end

    attribute :first_name, :string do
      public? true
    end

    attribute :last_name, :string do
      public? true
    end

    attribute :age, :integer do
      public? true
    end
  end

  calculations do
    calculate :full_name, :string, expr(first_name <> " " <> last_name)
    calculate :age_plus_ten, :integer, expr(age + 10)
  end

  actions do
    defaults [:read, create: :*, update: :*]

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end
end
