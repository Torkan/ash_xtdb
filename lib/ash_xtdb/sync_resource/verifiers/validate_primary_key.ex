# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SyncResource.Verifiers.ValidatePrimaryKey do
  @moduledoc """
  Validates that resources using `AshXTDB.SyncResource` have a single UUID primary key.

  XTDB requires a single `_id` column as the primary key. To ensure compatibility,
  synced resources must have exactly one primary key field of type `:uuid` or `:uuid_v7`.
  Composite primary keys are not supported.
  """

  use Spark.Dsl.Verifier

  @uuid_types [Ash.Type.UUID, :uuid, Ash.Type.UUIDv7, :uuid_v7]

  def verify(dsl) do
    pkey_fields = Ash.Resource.Info.primary_key(dsl)

    case pkey_fields do
      [] ->
        {:error,
         Spark.Error.DslError.exception(
           path: [:attributes],
           message: "AshXTDB.SyncResource requires a primary key, but none was defined."
         )}

      [field] ->
        validate_uuid_type(dsl, field)

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

  defp validate_uuid_type(dsl, field) do
    case Ash.Resource.Info.attribute(dsl, field) do
      %{type: type} when type in @uuid_types ->
        :ok

      %{type: type} ->
        {:error,
         Spark.Error.DslError.exception(
           path: [:attributes, field],
           message:
             "AshXTDB.SyncResource requires a UUID primary key " <>
               "(uuid_primary_key or uuid_v7_primary_key), " <>
               "but #{inspect(field)} has type #{inspect(type)}."
         )}

      nil ->
        {:error,
         Spark.Error.DslError.exception(
           path: [:attributes, field],
           message: "Primary key attribute #{inspect(field)} not found."
         )}
    end
  end
end
