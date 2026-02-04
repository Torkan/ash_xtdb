# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.Capabilities do
  @moduledoc """
  Defines the capabilities supported by the XTDB data layer.

  This module implements all `can?/2` checks for `Ash.DataLayer` behavior,
  declaring which features XTDB supports.

  ## Supported Capabilities

  ### Phase 1: Basic CRUD
  - `:create`, `:read`, `:update`, `:destroy`
  - `:upsert` (XTDB INSERT is naturally upsert)

  ### Phase 2: Query Features
  - `:filter`, `:sort`, `:limit`, `:offset`, `:select`, `:distinct`
  - `:boolean_filter`, `:nested_expressions`
  - `{:filter_expr, _}`, `{:sort, _}`

  ### Phase 3: Relationships
  - `{:join, resource}` - joins to other XTDB resources
  - `{:filter_relationship, _}` - filter through relationships

  ### Phase 4: Aggregates
  - Basic: `:count`, `:sum`, `:avg`, `:min`, `:max`, `:exists`, `:first`, `:list`
  - Statistical: `:stddev_pop`, `:stddev_samp`, `:var_pop`, `:var_samp`
  - Boolean: `:bool_and`, `:bool_or`
  - Query variants: `{:query_aggregate, kind}`
  - Relationship aggregates: `{:aggregate_relationship, relationship}`

  ### Phase 5: Transactions
  - `:transact` - full transaction support

  ### Phase 7: Bulk Operations
  - `:bulk_create`, `:update_query`, `:destroy_query`

  ### Phase 8: Atomic Updates
  - `:expr_error`, `{:atomic, :update}`, `{:atomic, :upsert}`

  ### Phase 9: Calculations
  - `:expression_calculation`

  ### Phase 10: Multitenancy
  - `:multitenancy`, `{:multitenancy, :attribute}`
  - `:changeset_filter`

  ### Lateral Joins
  - `{:lateral_join, resources}` - via NEST_MANY/NEST_ONE iteration

  ## Unsupported Capabilities

  - `{:lock, _}` - XTDB doesn't support row locking
  - `{:multitenancy, :context}` - XTDB has no schema support
  """

  @doc """
  Checks if the data layer supports a given capability.

  This is the main entry point called by `Ash.DataLayer.can?/2`.
  """
  @spec can?(Ash.Resource.t(), term()) :: boolean()
  def can?(resource, capability) do
    do_can?(resource, capability)
  end

  # ============================================================================
  # Phase 1: Basic CRUD
  # ============================================================================

  defp do_can?(_, :create), do: true
  defp do_can?(_, :read), do: true
  defp do_can?(_, :update), do: true
  defp do_can?(_, :destroy), do: true

  # ============================================================================
  # Phase 2: Query Features
  # ============================================================================

  defp do_can?(_, :filter), do: true
  defp do_can?(_, :sort), do: true
  defp do_can?(_, :limit), do: true
  defp do_can?(_, :offset), do: true
  defp do_can?(_, :select), do: true
  defp do_can?(_, :distinct), do: true
  defp do_can?(_, :boolean_filter), do: true
  defp do_can?(_, :nested_expressions), do: true

  # Filter expressions
  defp do_can?(_, {:filter_expr, _}), do: true

  # Sort on attribute
  defp do_can?(_, {:sort, _}), do: true

  # XTDB INSERT is naturally upsert
  defp do_can?(_, :upsert), do: true

  # Async engine support
  defp do_can?(_, :async_engine), do: true

  # ============================================================================
  # Phase 3: Relationships
  # ============================================================================

  # Allow joins to other XTDB resources
  defp do_can?(_, {:join, resource}) do
    Ash.Resource.Info.data_layer(resource) == AshXTDB.DataLayer
  end

  defp do_can?(_, {:filter_relationship, _}), do: true

  # ============================================================================
  # Phase 4: Aggregates
  # ============================================================================

  # Basic aggregates
  defp do_can?(_, {:aggregate, :count}), do: true
  defp do_can?(_, {:aggregate, :sum}), do: true
  defp do_can?(_, {:aggregate, :avg}), do: true
  defp do_can?(_, {:aggregate, :min}), do: true
  defp do_can?(_, {:aggregate, :max}), do: true
  defp do_can?(_, {:aggregate, :exists}), do: true
  defp do_can?(_, {:aggregate, :first}), do: true
  defp do_can?(_, {:aggregate, :list}), do: true

  # Statistical aggregates
  defp do_can?(_, {:aggregate, :stddev_pop}), do: true
  defp do_can?(_, {:aggregate, :stddev_samp}), do: true
  defp do_can?(_, {:aggregate, :var_pop}), do: true
  defp do_can?(_, {:aggregate, :var_samp}), do: true

  # Boolean aggregates
  defp do_can?(_, {:aggregate, :bool_and}), do: true
  defp do_can?(_, {:aggregate, :bool_or}), do: true

  # Query aggregates (same support as regular aggregates)
  defp do_can?(_, {:query_aggregate, :count}), do: true
  defp do_can?(_, {:query_aggregate, :sum}), do: true
  defp do_can?(_, {:query_aggregate, :avg}), do: true
  defp do_can?(_, {:query_aggregate, :min}), do: true
  defp do_can?(_, {:query_aggregate, :max}), do: true
  defp do_can?(_, {:query_aggregate, :exists}), do: true
  defp do_can?(_, {:query_aggregate, :first}), do: true
  defp do_can?(_, {:query_aggregate, :list}), do: true
  defp do_can?(_, {:query_aggregate, :stddev_pop}), do: true
  defp do_can?(_, {:query_aggregate, :stddev_samp}), do: true
  defp do_can?(_, {:query_aggregate, :var_pop}), do: true
  defp do_can?(_, {:query_aggregate, :var_samp}), do: true
  defp do_can?(_, {:query_aggregate, :bool_and}), do: true
  defp do_can?(_, {:query_aggregate, :bool_or}), do: true

  # Aggregate relationships - allow aggregating over relationships to other XTDB resources
  defp do_can?(_, {:aggregate_relationship, relationship}) do
    Ash.Resource.Info.data_layer(relationship.destination) == AshXTDB.DataLayer
  end

  # ============================================================================
  # Phase 5: Transactions
  # ============================================================================

  defp do_can?(_, :transact), do: true

  # ============================================================================
  # Phase 7: Bulk Operations
  # ============================================================================

  defp do_can?(_, :bulk_create), do: true
  defp do_can?(_, :update_query), do: true
  defp do_can?(_, :destroy_query), do: true

  # ============================================================================
  # Phase 8: Atomic Updates
  # ============================================================================

  # Supports expressions in UPDATE SET clause (e.g., counter = counter + 1)
  defp do_can?(_, :expr_error), do: true
  defp do_can?(_, {:atomic, :update}), do: true
  defp do_can?(_, {:atomic, :upsert}), do: true

  # ============================================================================
  # Phase 9: Calculations
  # ============================================================================

  defp do_can?(_, :expression_calculation), do: true

  # ============================================================================
  # Phase 10: Multitenancy
  # ============================================================================

  defp do_can?(_, :multitenancy), do: true
  defp do_can?(_, {:multitenancy, :attribute}), do: true
  defp do_can?(_, :changeset_filter), do: true

  # Context-based multitenancy (schemas) not supported - XTDB has no schemas
  defp do_can?(_, {:multitenancy, :context}), do: false

  # ============================================================================
  # Lateral Joins
  # ============================================================================

  # Supported via iteration when all resources use XTDB
  defp do_can?(_resource, {:lateral_join, resources}) do
    Enum.all?(resources, fn res ->
      Ash.Resource.Info.data_layer(res) == AshXTDB.DataLayer
    end)
  end

  # ============================================================================
  # Not Supported (XTDB Limitations)
  # ============================================================================

  defp do_can?(_, {:lock, _}), do: false

  # ============================================================================
  # Default
  # ============================================================================

  defp do_can?(_, _), do: false
end
