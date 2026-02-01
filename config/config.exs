# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

import Config

config :ash, disable_async?: true

config :logger, level: :warning

import_config "#{config_env()}.exs"
