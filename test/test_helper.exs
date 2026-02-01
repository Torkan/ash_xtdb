# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

ExUnit.start()

# Start the test repo
{:ok, _} = AshXTDB.TestRepo.start_link()
