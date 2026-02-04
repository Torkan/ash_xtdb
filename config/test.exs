# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

import Config

config :ash_xtdb, AshXTDB.TestRepo,
  hostname: "localhost",
  port: 5433,
  database: "ash_xtdb_test"

config :logger, level: :warning

config :ash_xtdb, repos: [AshXTDB.TestRepo]
