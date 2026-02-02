# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SimpleQuery do
  @moduledoc """
  Query struct for XTDB simple query protocol.

  This struct wraps SQL statements for execution through DBConnection.
  Parameters are inlined into the SQL string during execution since
  XTDB only supports the simple query protocol.
  """

  defstruct [:statement, :name]

  @type t :: %__MODULE__{
          statement: String.t(),
          name: String.t() | nil
        }

  @doc """
  Creates a new simple query.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(statement, opts \\ []) do
    %__MODULE__{
      statement: statement,
      name: Keyword.get(opts, :name)
    }
  end

  defimpl DBConnection.Query do
    def parse(query, _opts), do: query

    def describe(query, _opts), do: query

    def encode(_query, params, _opts) do
      # Parameters are passed through - they'll be inlined in handle_execute
      params
    end

    def decode(_query, result, _opts) do
      # Result is already a Postgrex.Result, pass through
      result
    end
  end

  defimpl String.Chars do
    def to_string(%{statement: statement}) do
      statement
    end
  end
end
