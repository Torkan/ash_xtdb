# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.TestRepo do
  @moduledoc """
  Test repository for XTDB integration tests.
  """

  use AshXTDB.Repo, otp_app: :ash_xtdb
end
