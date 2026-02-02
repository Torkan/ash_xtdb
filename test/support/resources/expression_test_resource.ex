# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.ExpressionTestResource do
  @moduledoc """
  Test resource for expression function tests.
  Includes attributes for testing Fragment, GetPath, date/time, and math functions.
  """

  use Ash.Resource,
    domain: AshXTDB.Test.Domain,
    data_layer: AshXTDB.DataLayer

  xtdb do
    repo AshXTDB.TestRepo
    table "expression_test"
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      public? true
    end

    attribute :value, :float do
      public? true
    end

    attribute :count, :integer do
      public? true
    end

    attribute :created_at, :utc_datetime_usec do
      public? true
    end

    attribute :metadata, :map do
      public? true
    end
  end

  calculations do
    # Math calculations
    calculate :rounded_value, :float, expr(round(value))
    calculate :rounded_to_2, :float, expr(round(value, 2))
    calculate :count_mod_3, :integer, expr(rem(count, 3))

    # Fragment calculation - raw SQL
    calculate :name_upper, :string, expr(fragment("UPPER(?)", name))
    calculate :double_count, :integer, expr(fragment("? * 2", count))

    # GetPath calculation - nested data access
    # Access metadata[:role] using get_path
    calculate :metadata_role, :string, expr(get_path(metadata, [:role]))

    # Date/time calculations - these will be evaluated in Elixir by Ash
    # We test the SQL generation in the filter tests
  end

  actions do
    defaults [:read, create: :*, update: :*]

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end
end
