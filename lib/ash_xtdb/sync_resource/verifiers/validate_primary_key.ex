# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SyncResource.Verifiers.ValidatePrimaryKey do
  @moduledoc """
  Validates that resources using `AshXTDB.SyncResource` have a single primary key.

  XTDB requires a single `_id` column as the primary key.
  Composite primary keys are not supported.
  """

  use Spark.Dsl.Verifier

  def verify(dsl) do
    case Ash.Resource.Info.primary_key(dsl) do
      [] ->
        {:error,
         Spark.Error.DslError.exception(
           path: [:attributes],
           message: "AshXTDB.SyncResource requires a primary key, but none was defined."
         )}

      [_field] ->
        :ok

      fields ->
        {:error,
         Spark.Error.DslError.exception(
           path: [:attributes],
           message:
             "AshXTDB.SyncResource requires a single primary key, " <>
               "but a composite key was found: #{inspect(fields)}. " <>
               "XTDB only supports a single _id column."
         )}
    end
  end
end
