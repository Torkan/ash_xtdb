# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Types.URI do
  @moduledoc """
  An Ash type for URI values.

  Stores and validates URIs. XTDB can store URIs as strings with optional
  validation and parsing support.

  ## Usage

      defmodule MyApp.Bookmark do
        use Ash.Resource

        attributes do
          attribute :url, AshXTDB.Types.URI
        end
      end

  ## Examples

      # Input can be a string
      "https://example.com/path?query=value"

      # Or a URI struct
      URI.parse("https://example.com")
  """

  use Ash.Type

  @impl Ash.Type
  def storage_type(_), do: :string

  @impl Ash.Type
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(%URI{} = uri, _) do
    {:ok, URI.to_string(uri)}
  end

  def cast_input(value, _) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: nil} ->
        {:error, message: "URI must have a scheme (e.g., http://, https://)"}

      %URI{} = uri ->
        {:ok, URI.to_string(uri)}
    end
  end

  def cast_input(_, _) do
    {:error, message: "URI must be a string or URI struct"}
  end

  @impl Ash.Type
  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(value, _) when is_binary(value), do: {:ok, value}
  def cast_stored(_, _), do: :error

  @impl Ash.Type
  def dump_to_native(nil, _), do: {:ok, nil}
  def dump_to_native(value, _) when is_binary(value), do: {:ok, value}
  def dump_to_native(%URI{} = uri, _), do: {:ok, URI.to_string(uri)}
  def dump_to_native(_, _), do: :error

  @doc """
  Parses a URI string into a URI struct.
  """
  @spec parse(String.t()) :: URI.t()
  def parse(value) when is_binary(value), do: URI.parse(value)

  @doc """
  Extracts the host from a URI string.
  """
  @spec host(String.t()) :: String.t() | nil
  def host(value) when is_binary(value) do
    URI.parse(value).host
  end

  @doc """
  Extracts the path from a URI string.
  """
  @spec path(String.t()) :: String.t() | nil
  def path(value) when is_binary(value) do
    URI.parse(value).path
  end

  @doc """
  Extracts the scheme from a URI string.
  """
  @spec scheme(String.t()) :: String.t() | nil
  def scheme(value) when is_binary(value) do
    URI.parse(value).scheme
  end

  @doc """
  Checks if the URI uses HTTPS.
  """
  @spec https?(String.t()) :: boolean()
  def https?(value) when is_binary(value) do
    URI.parse(value).scheme == "https"
  end
end
