# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Types do
  @moduledoc """
  Type mapping between Ash types and XTDB types.

  XTDB is schemaless, so this module primarily handles:
  - Value encoding for SQL parameters
  - Value decoding from query results
  """

  @doc """
  Encodes an Ash value for use as a SQL parameter.
  """
  @spec encode(term(), Ash.Type.t()) :: term()
  def encode(nil, _type), do: nil

  def encode(value, Ash.Type.UUID) when is_binary(value), do: value
  def encode(value, Ash.Type.UUIDv7) when is_binary(value), do: value

  def encode(%DateTime{} = value, Ash.Type.DateTime), do: value
  def encode(%DateTime{} = value, Ash.Type.UtcDatetime), do: value
  def encode(%DateTime{} = value, Ash.Type.UtcDatetimeUsec), do: value

  def encode(%NaiveDateTime{} = value, Ash.Type.NaiveDatetime), do: value
  def encode(%Date{} = value, Ash.Type.Date), do: value
  def encode(%Time{} = value, Ash.Type.Time), do: value

  def encode(value, Ash.Type.Integer) when is_integer(value), do: value
  def encode(value, Ash.Type.Float) when is_float(value), do: value
  def encode(value, Ash.Type.Decimal) when is_struct(value, Decimal), do: value

  def encode(value, Ash.Type.Boolean) when is_boolean(value), do: value
  def encode(value, Ash.Type.String) when is_binary(value), do: value
  def encode(value, Ash.Type.Atom) when is_atom(value), do: Atom.to_string(value)

  def encode(value, Ash.Type.Map) when is_map(value), do: value
  def encode(value, {:array, _inner_type}) when is_list(value), do: value

  # Default pass-through
  def encode(value, _type), do: value

  @doc """
  Decodes an XTDB value to an Ash type.
  """
  @spec decode(term(), Ash.Type.t()) :: term()
  def decode(nil, _type), do: nil

  def decode(value, Ash.Type.Atom) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> String.to_atom(value)
  end

  # Most types pass through since Postgrex handles decoding
  def decode(value, _type), do: value
end
