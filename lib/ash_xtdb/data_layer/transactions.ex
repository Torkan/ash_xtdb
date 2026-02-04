# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.Transactions do
  @moduledoc """
  Transaction support for XTDB data layer.

  Provides transaction management using DBConnection's transaction support,
  with proper handling of nested transactions and rollbacks.

  ## Usage

  Transactions are typically managed through Ash's action lifecycle, but can
  also be used directly:

      AshXTDB.DataLayer.Transactions.transaction(resource, fn ->
        # operations here
      end)

  ## Nested Transactions

  If a transaction function is called while already inside a transaction,
  the inner function is simply executed (no nested transaction is created).
  This matches the behavior of most database systems.

  ## Rollback

  Use `rollback/2` to abort the current transaction:

      AshXTDB.DataLayer.Transactions.transaction(resource, fn ->
        case do_something() do
          {:ok, result} -> result
          {:error, reason} -> AshXTDB.DataLayer.Transactions.rollback(resource, reason)
        end
      end)
  """

  alias AshXTDB.DataLayer.Errors
  alias AshXTDB.DataLayer.Info

  @doc """
  Executes a function within a database transaction.

  ## Parameters

  - `resource` - The Ash resource (used to get the repo)
  - `func` - Zero-arity function to execute within the transaction
  - `timeout` - Transaction timeout (currently unused, reserved for future use)
  - `reason` - Transaction reason (currently unused, for debugging/tracing)

  ## Returns

  - `{:ok, result}` - Transaction completed successfully with result
  - `{:error, reason}` - Transaction failed or was rolled back
  """
  @spec transaction(Ash.Resource.t(), (-> any()), timeout() | nil, term()) ::
          {:ok, any()} | {:error, any()}
  def transaction(resource, func, _timeout, _reason) do
    repo = Info.repo!(resource)

    if in_transaction?(resource) do
      # Already in a transaction, just run the function
      {:ok, func.()}
    else
      # Use DBConnection transaction with proper pooling
      # We wrap in try/rescue to catch exceptions and convert to error tuples
      try do
        case repo.transaction(fn ->
               try do
                 func.()
               catch
                 :throw, {:ash_rollback, value} ->
                   repo.rollback({:ash_rollback, value})
               end
             end) do
          # Transaction completed - pass through the result
          # The inner func may return {:ok, result}, {:ok, result, changeset, notifications},
          # {:error, error}, or other values. We wrap in {:ok, ...} to indicate the
          # transaction itself succeeded.
          {:ok, result} ->
            {:ok, result}

          # Transaction was rolled back via throw
          {:error, {:ash_rollback, value}} ->
            {:error, value}

          # Connection error during transaction
          {:error, %DBConnection.ConnectionError{} = error} ->
            {:error, Errors.to_ash_error(error)}

          # Other rollback reasons (e.g., from repo.rollback)
          {:error, error} ->
            {:error, Errors.to_ash_error(error)}
        end
      rescue
        e ->
          {:error, Ash.Error.to_ash_error(e, __STACKTRACE__)}
      end
    end
  end

  @doc """
  Rolls back the current transaction with the given value.

  This will cause the enclosing `transaction/4` call to return `{:error, value}`.

  ## Parameters

  - `resource` - The Ash resource (used to get the repo)
  - `value` - The rollback reason/value

  ## Raises

  Raises if called outside of a transaction.
  """
  @spec rollback(Ash.Resource.t(), term()) :: no_return()
  def rollback(resource, value) do
    repo = Info.repo!(resource)
    repo.rollback(value)
  end

  @doc """
  Checks if the current process is inside a transaction.

  ## Parameters

  - `resource` - The Ash resource (used to get the repo)

  ## Returns

  `true` if inside a transaction, `false` otherwise.
  """
  @spec in_transaction?(Ash.Resource.t()) :: boolean()
  def in_transaction?(resource) do
    repo = Info.repo!(resource)
    repo.in_transaction?()
  end
end
