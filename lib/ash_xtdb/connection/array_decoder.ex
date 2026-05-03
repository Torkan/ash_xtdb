# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Connection.ArrayDecoder do
  @moduledoc """
  Parses PostgreSQL's text-format array representation into a list of strings.

  The format is documented at
  https://www.postgresql.org/docs/current/arrays.html#ARRAYS-IO and looks like:

      {1,2,3}                  -> ["1", "2", "3"]
      {"a","b"}                -> ["a", "b"]
      {NULL,1}                 -> [nil, "1"]
      {"a,b","with \"quote\""} -> ["a,b", "with \"quote\""]
      {}                       -> []

  Only one-dimensional arrays are decoded — this is what XTDB emits for
  Ash's `{:array, T}` attributes. Element values are returned as raw
  strings; the caller is responsible for casting each element to its
  Elixir type using the array's element OID.
  """

  @doc """
  Parses a Postgres array literal. Returns a list of strings (or `nil`
  for unquoted `NULL` elements). Raises `ArgumentError` if the input is
  not a recognizable array literal.
  """
  @spec parse(binary()) :: [binary() | nil]
  def parse("{}"), do: []

  def parse(<<"{", rest::binary>>) do
    case split_elements(rest, "", [], :unquoted) do
      {:ok, elements} -> elements
      {:error, reason} -> raise ArgumentError, "invalid array literal: #{reason}"
    end
  end

  def parse(other) do
    raise ArgumentError, "expected array literal starting with '{', got: #{inspect(other)}"
  end

  # State machine over the bytes after the opening '{'.
  #   :unquoted — between elements or inside an unquoted element
  #   :quoted   — inside a "..." element
  #   :escaped  — just saw '\' inside a quoted element; next byte is literal
  #
  # `acc` accumulates the current element's bytes; `elements` is the
  # reversed list of completed elements.

  defp split_elements(<<"}">>, acc, elements, :unquoted) do
    {:ok, Enum.reverse([finalize_unquoted(acc) | elements])}
  end

  defp split_elements(<<",", rest::binary>>, acc, elements, :unquoted) do
    split_elements(rest, "", [finalize_unquoted(acc) | elements], :unquoted)
  end

  defp split_elements(<<"\"", rest::binary>>, "", elements, :unquoted) do
    split_elements(rest, "", elements, :quoted)
  end

  defp split_elements(<<"\\", rest::binary>>, acc, elements, :quoted) do
    split_elements(rest, acc, elements, :escaped)
  end

  defp split_elements(<<c, rest::binary>>, acc, elements, :escaped) do
    split_elements(rest, <<acc::binary, c>>, elements, :quoted)
  end

  defp split_elements(<<"\"", rest::binary>>, acc, elements, :quoted) do
    # Closing quote: emit the element as-is (preserving empty strings) and
    # expect either ',' or '}' next.
    case rest do
      <<",", more::binary>> -> split_elements(more, "", [acc | elements], :unquoted)
      <<"}">> -> {:ok, Enum.reverse([acc | elements])}
      _ -> {:error, "unexpected bytes after closing quote: #{inspect(rest)}"}
    end
  end

  defp split_elements(<<c, rest::binary>>, acc, elements, state)
       when state in [:unquoted, :quoted] do
    split_elements(rest, <<acc::binary, c>>, elements, state)
  end

  defp split_elements(<<>>, _acc, _elements, _state) do
    {:error, "unterminated array literal"}
  end

  # Postgres represents NULL as the unquoted literal `NULL` (case-insensitive
  # in input, always uppercase in output). Empty unquoted segments don't
  # occur in valid input; we let them through as empty strings rather than
  # erroring, since the cast step will surface any real type mismatch.
  defp finalize_unquoted("NULL"), do: nil
  defp finalize_unquoted(bin), do: bin
end
