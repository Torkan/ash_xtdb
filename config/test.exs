# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

import Config

config :ash_xtdb, AshXTDB.TestRepo,
  hostname: "localhost",
  port: 5433,
  database: "xtdb"

config :logger, level: :warning
