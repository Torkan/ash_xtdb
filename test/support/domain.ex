# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Test.Domain do
  @moduledoc """
  Test domain for XTDB integration tests.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshXTDB.Test.User
    resource AshXTDB.Test.Organization
    resource AshXTDB.Test.Post
    resource AshXTDB.Test.Tag
    resource AshXTDB.Test.PostTag
    resource AshXTDB.Test.UserWithCalculations
    resource AshXTDB.Test.PostWithTenant
  end
end
