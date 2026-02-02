# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.Info do
  @moduledoc """
  Introspection helpers for the AshXTDB DSL.
  """

  @doc """
  Returns the repo module configured for the resource.
  """
  @spec repo(Ash.Resource.t()) :: {:ok, module()} | :error
  def repo(resource) do
    Spark.Dsl.Extension.fetch_opt(resource, [:xtdb], :repo)
  end

  @doc """
  Returns the repo module configured for the resource or raises.
  """
  @spec repo!(Ash.Resource.t()) :: module()
  def repo!(resource) do
    case repo(resource) do
      {:ok, repo} -> repo
      :error -> raise "No repo configured for #{inspect(resource)}"
    end
  end

  @doc """
  Returns the table name configured for the resource.
  """
  @spec table(Ash.Resource.t()) :: {:ok, String.t()} | :error
  def table(resource) do
    Spark.Dsl.Extension.fetch_opt(resource, [:xtdb], :table)
  end

  @doc """
  Returns the table name configured for the resource or raises.
  """
  @spec table!(Ash.Resource.t()) :: String.t()
  def table!(resource) do
    case table(resource) do
      {:ok, table} -> table
      :error -> raise "No table configured for #{inspect(resource)}"
    end
  end

  @doc """
  Returns whether the `_valid_from` attribute is public.
  """
  @spec valid_from_public?(Ash.Resource.t()) :: boolean()
  def valid_from_public?(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:xtdb], :valid_from_public?, false)
  end

  @doc """
  Returns whether the `_valid_to` attribute is public.
  """
  @spec valid_to_public?(Ash.Resource.t()) :: boolean()
  def valid_to_public?(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:xtdb], :valid_to_public?, false)
  end
end
