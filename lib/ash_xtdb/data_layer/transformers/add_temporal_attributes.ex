# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.Transformers.AddTemporalAttributes do
  @moduledoc """
  Adds `_valid_from` and `_valid_to` temporal attributes to XTDB resources.

  These attributes are populated by XTDB for bitemporal queries and are
  not writable by the application.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def after?(_), do: false

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(_), do: false

  def transform(dsl) do
    valid_from_public? =
      Transformer.get_option(dsl, [:xtdb], :valid_from_public?, false)

    valid_to_public? =
      Transformer.get_option(dsl, [:xtdb], :valid_to_public?, false)

    valid_from_attr = build_temporal_attribute(:_valid_from, valid_from_public?)
    valid_to_attr = build_temporal_attribute(:_valid_to, valid_to_public?)

    dsl =
      dsl
      |> Transformer.add_entity([:attributes], valid_from_attr)
      |> Transformer.add_entity([:attributes], valid_to_attr)

    {:ok, dsl}
  end

  defp build_temporal_attribute(name, public?) do
    %Ash.Resource.Attribute{
      name: name,
      type: Ash.Type.UtcDatetimeUsec,
      public?: public?,
      writable?: false,
      generated?: true,
      allow_nil?: true,
      primary_key?: false,
      always_select?: false,
      select_by_default?: true,
      filterable?: true,
      sortable?: true,
      constraints: [],
      description: "XTDB bitemporal #{name} timestamp"
    }
  end
end
