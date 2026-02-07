# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.Transactions do
  @moduledoc """
  Transaction support for XTDB data layer.

  XTDB does not support multi-statement atomic transactions via pgwire.
  Sending `BEGIN`/`COMMIT` causes protocol errors when mixing `SELECT` and DML.

  Instead of `repo.transaction()`, we use `repo.run()` which checks out a
  connection from the pool without starting a database transaction. This gives
  Ash a consistent connection for the duration of the "transaction" callback
  without pretending XTDB supports real transactions.

  ## Rollback

  Since there is no real database transaction, `rollback/2` raises an error.
  XTDB operations are not rollback-safe — each statement executes immediately.
  """

  alias AshXTDB.DataLayer.Info

  @doc """
  Executes a function with a checked-out connection.

  Uses `repo.run()` instead of `repo.transaction()` because XTDB's pgwire
  protocol does not support `SELECT` inside DML transactions.

  The function still runs with a dedicated connection, but no `BEGIN`/`COMMIT`
  is sent to XTDB.
  """
  @spec transaction(Ash.Resource.t(), (-> any()), timeout() | nil, term()) ::
          {:ok, any()} | {:error, any()}
  def transaction(resource, func, _timeout, _reason) do
    repo = Info.repo!(resource)

    if repo.in_transaction?() do
      {:ok, func.()}
    else
      try do
        # repo.run() returns the function's result directly (no {:ok, ...} wrapping),
        # unlike repo.transaction() which wraps in {:ok, result} / {:error, reason}.
        repo.run(fn ->
          try do
            {:ok, func.()}
          catch
            :throw, {:ash_rollback, value} ->
              {:error, value}
          end
        end)
      rescue
        e ->
          {:error, Ash.Error.to_ash_error(e, __STACKTRACE__)}
      end
    end
  end

  @doc """
  Raises an error — XTDB does not support transactional rollback.

  XTDB's pgwire protocol does not support multi-statement transactions,
  so there is nothing to roll back. Each DML statement executes immediately.
  """
  @spec rollback(Ash.Resource.t(), term()) :: no_return()
  def rollback(_resource, _value) do
    raise """
    XTDB does not support transactional rollback.

    XTDB's pgwire protocol executes each DML statement immediately — there is
    no BEGIN/COMMIT transaction to roll back. If you need atomic operations
    across multiple records, consider using XTDB's native transaction API
    or restructuring your logic to handle partial failures.
    """
  end

  @doc """
  Checks if the current process has a checked-out connection.
  """
  @spec in_transaction?(Ash.Resource.t()) :: boolean()
  def in_transaction?(resource) do
    repo = Info.repo!(resource)
    repo.in_transaction?()
  end
end
