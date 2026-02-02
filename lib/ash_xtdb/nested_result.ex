# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.NestedResult do
  @moduledoc """
  Transforms XTDB nested query results into Ash-compatible flat records.

  When using NEST_MANY/NEST_ONE, XTDB returns results with nested JSON arrays/objects.
  This module transforms those results into the flat format Ash expects, with
  `__lateral_join_source__` metadata for proper parent-child association.

  ## Example

  Given XTDB result:

      [
        %{_id: "user1", name: "Alice", posts: [%{_id: "p1", title: "Post 1"}]},
        %{_id: "user2", name: "Bob", posts: [%{_id: "p2", title: "Post 2"}, %{_id: "p3", title: "Post 3"}]}
      ]

  With nested subquery config:

      %{name: :posts, type: :nest_many, resource: Post}

  Calling `extract_nested/4` returns:

      [
        %Post{id: "p1", title: "Post 1", __lateral_join_source__: %{id: "user1"}},
        %Post{id: "p2", title: "Post 2", __lateral_join_source__: %{id: "user2"}},
        %Post{id: "p3", title: "Post 3", __lateral_join_source__: %{id: "user2"}}
      ]

  """

  @doc """
  Extracts nested relationship records from parent records.

  ## Parameters

    * `parent_records` - List of parent records with nested data
    * `nested_name` - Atom name of the nested field (e.g., :posts)
    * `nested_resource` - The Ash resource module for the nested records
    * `parent_resource` - The Ash resource module for the parent records

  ## Returns

  List of nested resource structs with `:__lateral_join_source__` metadata.
  """
  @spec extract_nested(list(map()), atom(), module(), module()) :: list(struct())
  def extract_nested(parent_records, nested_name, nested_resource, parent_resource) do
    pkey_attrs = Ash.Resource.Info.primary_key(parent_resource)

    Enum.flat_map(parent_records, fn parent ->
      nested_data = Map.get(parent, nested_name, [])
      parent_pkey = Map.take(parent, pkey_attrs)

      nested_list =
        case nested_data do
          nil -> []
          data when is_list(data) -> data
          data when is_map(data) -> [data]
        end

      Enum.map(nested_list, fn nested_attrs ->
        nested_attrs
        |> normalize_nested_attrs(nested_resource)
        |> Map.put(:__lateral_join_source__, parent_pkey)
        |> to_struct(nested_resource)
      end)
    end)
  end

  @doc """
  Transforms a list of raw row maps with nested JSON into structured results.

  This handles the case where XTDB returns nested data as JSON strings that
  need to be decoded.

  ## Parameters

    * `rows` - List of row maps from the database
    * `columns` - Column names from the result
    * `nested_configs` - List of nested subquery configurations

  ## Returns

  List of maps with nested JSON decoded into Elixir data structures.
  """
  @spec transform_rows(list(list()), list(String.t()), list(map())) :: list(map())
  def transform_rows(rows, columns, nested_configs) do
    column_atoms = Enum.map(columns, &String.to_atom/1)
    nested_names = MapSet.new(Enum.map(nested_configs, & &1.name))

    Enum.map(rows, fn row ->
      column_atoms
      |> Enum.zip(row)
      |> Enum.map(fn {col, val} ->
        if MapSet.member?(nested_names, col) do
          {col, decode_nested_value(val)}
        else
          {col, val}
        end
      end)
      |> Map.new()
    end)
  end

  @doc """
  Checks if a parent record has any nested data for the given field.
  """
  @spec has_nested?(map(), atom()) :: boolean()
  def has_nested?(parent, nested_name) do
    case Map.get(parent, nested_name) do
      nil -> false
      [] -> false
      _ -> true
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp normalize_nested_attrs(attrs, resource) when is_map(attrs) do
    # Map _id back to the primary key attribute
    pkey_attrs = Ash.Resource.Info.primary_key(resource)

    case pkey_attrs do
      [pkey] when pkey != :_id ->
        case Map.pop(attrs, :_id) do
          {nil, attrs} ->
            # Also check string key
            case Map.pop(attrs, "_id") do
              {nil, attrs} -> attrs
              {id_value, attrs} -> Map.put(attrs, pkey, id_value)
            end

          {id_value, attrs} ->
            Map.put(attrs, pkey, id_value)
        end

      _ ->
        attrs
    end
  end

  defp normalize_nested_attrs(attrs, _resource), do: attrs

  defp decode_nested_value(nil), do: []
  defp decode_nested_value([]), do: []
  defp decode_nested_value(list) when is_list(list), do: Enum.map(list, &decode_nested_item/1)
  defp decode_nested_value(map) when is_map(map), do: decode_nested_item(map)

  defp decode_nested_value(json) when is_binary(json) do
    case Jason.decode(json, keys: :atoms) do
      {:ok, decoded} when is_list(decoded) -> decoded
      {:ok, decoded} when is_map(decoded) -> [decoded]
      _ -> []
    end
  end

  defp decode_nested_item(item) when is_map(item) do
    # Convert string keys to atoms for consistency
    Map.new(item, fn
      {key, val} when is_binary(key) -> {String.to_atom(key), val}
      {key, val} -> {key, val}
    end)
  end

  defp decode_nested_item(item), do: item

  defp to_struct(attrs, resource) do
    # Cast attribute values before creating struct
    attr_types = get_attribute_types(resource)

    casted_attrs =
      Enum.map(attrs, fn {key, value} ->
        case Map.get(attr_types, key) do
          nil ->
            {key, value}

          type_info ->
            {key, cast_value(value, type_info)}
        end
      end)
      |> Map.new()

    struct(resource, casted_attrs)
  end

  defp get_attribute_types(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(fn attr ->
      type = Ash.Type.get_type(attr.type)
      # Initialize constraints to get proper defaults (e.g., precision for datetime types)
      constraints = init_constraints(type, attr.constraints)
      {attr.name, %{type: type, constraints: constraints}}
    end)
    |> Map.new()
  end

  defp init_constraints(type, constraints) do
    if function_exported?(type, :init, 1) do
      case type.init(constraints) do
        {:ok, initialized} -> initialized
        _ -> constraints
      end
    else
      constraints
    end
  end

  defp cast_value(nil, _type_info), do: nil

  defp cast_value(value, %{type: type, constraints: constraints}) do
    # XTDB via pgwire returns raw values that need proper casting:
    # - Atoms come as strings -> need String.to_atom
    # - Maps may come as JSON strings -> cast_input handles this
    # - DateTimes come as strings -> cast_input handles this
    cond do
      # Atom type with string value - convert string to atom
      type == Ash.Type.Atom and is_binary(value) ->
        String.to_atom(value)

      # Try cast_input first (handles JSON strings for maps, datetime strings, etc.)
      true ->
        case Ash.Type.cast_input(type, value, constraints) do
          {:ok, casted} ->
            casted

          _ ->
            # Fall back to cast_stored for already-typed values
            case Ash.Type.cast_stored(type, value, constraints) do
              {:ok, casted} -> casted
              :error -> value
            end
        end
    end
  end
end
