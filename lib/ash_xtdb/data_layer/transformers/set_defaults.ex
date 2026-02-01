# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.Transformers.SetDefaults do
  @moduledoc """
  Sets default values for the XTDB data layer configuration.
  """

  use Spark.Dsl.Transformer

  def transform(dsl) do
    {:ok, dsl}
  end
end
