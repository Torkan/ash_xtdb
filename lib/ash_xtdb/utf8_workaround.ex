# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.UTF8Workaround do
  @moduledoc """
  Workaround for XTDB's 4-byte UTF-8 character handling bug.

  XTDB has a bug in their PostgreSQL wire protocol where 4-byte UTF-8 characters
  (emojis, some CJK characters, mathematical symbols, etc.) cause SQL truncation.
  This module provides encoding/decoding functions to work around this issue.

  ## How It Works

  - **Encoding**: Before sending data to XTDB, 4-byte UTF-8 characters (codepoints > U+FFFF)
    are converted to escape sequences in the format `\\u{XXXXXX}`.
  - **Decoding**: When reading data from XTDB, these escape sequences are converted
    back to the original characters.

  ## Escape Format

  The format `\\u{XXXXXX}` is used because:
  - It's similar to Elixir's own Unicode escape syntax
  - It won't conflict with JSON's `\\uXXXX` (which only handles BMP characters)
  - It can represent any Unicode codepoint (including > U+FFFF)
  - It's unlikely to appear naturally in user data

  ## Examples

      iex> AshXTDB.UTF8Workaround.encode("Hello 😀")
      "Hello \\\\u{1F600}"

      iex> AshXTDB.UTF8Workaround.decode("Hello \\\\u{1F600}")
      "Hello 😀"

  ## Affected Characters

  This affects any Unicode codepoint above U+FFFF, including:
  - Most emoji (😀 = U+1F600)
  - Some CJK ideographs in Extension B and beyond
  - Mathematical symbols
  - Historic scripts
  - Musical notation
  """

  @escape_regex ~r/\\u\{([0-9A-Fa-f]+)\}/

  # ============================================================================
  # Single Value Encoding/Decoding
  # ============================================================================

  @doc """
  Encodes 4-byte UTF-8 characters to escape sequences.

  Converts any Unicode codepoint > U+FFFF to the format `\\u{XXXXXX}`.
  Characters in the Basic Multilingual Plane (BMP, U+0000 to U+FFFF) are left unchanged.

  ## Examples

      iex> AshXTDB.UTF8Workaround.encode("Hello 😀 World")
      "Hello \\\\u{1F600} World"

      iex> AshXTDB.UTF8Workaround.encode("No emojis here")
      "No emojis here"

      iex> AshXTDB.UTF8Workaround.encode(nil)
      nil
  """
  @spec encode(String.t() | nil) :: String.t() | nil
  def encode(nil), do: nil

  def encode(string) when is_binary(string) do
    string
    |> String.codepoints()
    |> Enum.map(&encode_codepoint/1)
    |> Enum.join()
  end

  @doc """
  Decodes escape sequences back to original UTF-8 characters.

  Converts `\\u{XXXXXX}` escape sequences back to their original Unicode characters.

  ## Examples

      iex> AshXTDB.UTF8Workaround.decode("Hello \\\\u{1F600} World")
      "Hello 😀 World"

      iex> AshXTDB.UTF8Workaround.decode("No escapes here")
      "No escapes here"

      iex> AshXTDB.UTF8Workaround.decode(nil)
      nil
  """
  @spec decode(String.t() | nil) :: String.t() | nil
  def decode(nil), do: nil

  def decode(string) when is_binary(string) do
    Regex.replace(@escape_regex, string, fn _full_match, hex_code ->
      hex_code
      |> String.to_integer(16)
      |> List.wrap()
      |> List.to_string()
    end)
  end

  # ============================================================================
  # Deep Encoding/Decoding for Nested Structures
  # ============================================================================

  @doc """
  Recursively encodes all strings in a nested data structure.

  Handles maps, lists, and nested combinations thereof.

  ## Examples

      iex> AshXTDB.UTF8Workaround.encode_deep(%{name: "Test 😀", tags: ["a", "b 🎉"]})
      %{name: "Test \\\\u{1F600}", tags: ["a", "b \\\\u{1F389}"]}
  """
  @spec encode_deep(term()) :: term()
  def encode_deep(nil), do: nil
  def encode_deep(string) when is_binary(string), do: encode(string)

  # Structs (DateTime, Date, etc.) should pass through unchanged
  def encode_deep(struct) when is_struct(struct), do: struct

  def encode_deep(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, encode_deep(value)} end)
  end

  def encode_deep(list) when is_list(list) do
    Enum.map(list, &encode_deep/1)
  end

  def encode_deep(other), do: other

  @doc """
  Recursively decodes all strings in a nested data structure.

  Handles maps, lists, and nested combinations thereof.

  ## Examples

      iex> AshXTDB.UTF8Workaround.decode_deep(%{name: "Test \\\\u{1F600}", tags: ["a", "b \\\\u{1F389}"]})
      %{name: "Test 😀", tags: ["a", "b 🎉"]}
  """
  @spec decode_deep(term()) :: term()
  def decode_deep(nil), do: nil
  def decode_deep(string) when is_binary(string), do: decode(string)

  # Structs (DateTime, Date, etc.) should pass through unchanged
  def decode_deep(struct) when is_struct(struct), do: struct

  def decode_deep(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, decode_deep(value)} end)
  end

  def decode_deep(list) when is_list(list) do
    Enum.map(list, &decode_deep/1)
  end

  def decode_deep(other), do: other

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Encode a single codepoint if it's above U+FFFF (4-byte UTF-8)
  defp encode_codepoint(codepoint) when is_binary(codepoint) do
    case String.to_charlist(codepoint) do
      [char] when char > 0xFFFF ->
        # Convert to \u{XXXXXX} format with uppercase hex
        "\\u{#{Integer.to_string(char, 16)}}"

      _ ->
        codepoint
    end
  end
end
