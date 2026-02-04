# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.Errors do
  @moduledoc """
  Error handling and conversion for XTDB data layer.

  Converts database errors (Postgrex, DBConnection) into Ash error types
  for consistent error handling throughout the application.

  ## Error Codes

  The following PostgreSQL error codes are specifically handled:

  - `08000`, `08003` - Connection errors
  - `42601` - Syntax error
  - `42P01` - Undefined table
  - `42703` - Undefined column
  - `42804` - Data type mismatch

  Other errors are converted using `Ash.Error.to_ash_error/1`.
  """

  alias Ash.Error.Query.InvalidQuery

  @doc """
  Converts a database error to an Ash error.

  ## Examples

      iex> error = %Postgrex.Error{postgres: %{code: "42P01", message: "table not found"}}
      iex> to_ash_error(error)
      %Ash.Error.Invalid{...}
  """
  @spec to_ash_error(term()) :: Ash.Error.t()

  def to_ash_error(%Postgrex.Error{postgres: %{code: code, message: message}} = error) do
    case code do
      # Connection errors
      "08000" ->
        Ash.Error.Unknown.exception(
          errors: ["XTDB connection error: #{message}"]
        )

      "08003" ->
        Ash.Error.Unknown.exception(
          errors: ["XTDB connection does not exist: #{message}"]
        )

      # Syntax errors
      "42601" ->
        Ash.Error.Invalid.exception(
          errors: [
            InvalidQuery.exception(
              query: nil,
              message: "SQL syntax error: #{message}"
            )
          ]
        )

      # Undefined table
      "42P01" ->
        Ash.Error.Invalid.exception(
          errors: [
            InvalidQuery.exception(
              query: nil,
              message: "Table does not exist: #{message}"
            )
          ]
        )

      # Undefined column
      "42703" ->
        Ash.Error.Invalid.exception(
          errors: [
            InvalidQuery.exception(
              query: nil,
              message: "Column does not exist: #{message}"
            )
          ]
        )

      # Data type mismatch
      "42804" ->
        Ash.Error.Invalid.exception(
          errors: [
            InvalidQuery.exception(
              query: nil,
              message: "Data type mismatch: #{message}"
            )
          ]
        )

      # Default: convert to Ash error
      _ ->
        Ash.Error.to_ash_error(error)
    end
  end

  def to_ash_error(%Postgrex.Error{} = error) do
    Ash.Error.to_ash_error(error)
  end

  def to_ash_error(%DBConnection.ConnectionError{message: message}) do
    Ash.Error.Unknown.exception(errors: ["Database connection error: #{message}"])
  end

  # Already an Ash error - return as-is to avoid double-wrapping
  def to_ash_error(%{__struct__: module} = error) when is_struct(error) do
    if ash_error?(module) do
      error
    else
      if is_exception(error) do
        Ash.Error.to_ash_error(error)
      else
        Ash.Error.Unknown.exception(errors: [inspect(error)])
      end
    end
  end

  def to_ash_error(error) when is_exception(error) do
    Ash.Error.to_ash_error(error)
  end

  def to_ash_error(error) do
    Ash.Error.Unknown.exception(errors: [inspect(error)])
  end

  # Check if a module is an Ash error class
  defp ash_error?(module) do
    # Ash errors implement the Splode.Error behaviour
    function_exported?(module, :splode, 0) and module.splode() == Ash.Error
  rescue
    _ -> false
  end
end
