# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.DataLayer.ResultTransformerUnitTest do
  @moduledoc """
  Unit tests for `ResultTransformer` helpers that don't require a live XTDB.
  """
  use ExUnit.Case, async: true

  alias AshXTDB.DataLayer.ResultTransformer
  alias AshXTDB.Test.User

  describe "get_attribute_types/1" do
    # Regression: init_constraints/2 used to call function_exported?(type, :init, 1)
    # unconditionally. For composite types like {:array, :string}, `type` is a
    # tuple — function_exported? requires an atom and raises ArgumentError. The
    # fix matches {:array, _} explicitly and constrains the function_exported?
    # branch to atoms.
    test "does not crash on resources with array attributes" do
      types = ResultTransformer.get_attribute_types(User)

      assert %{type: {:array, Ash.Type.String}} = types[:tags]
      assert %{type: {:array, Ash.Type.Atom}} = types[:roles]
    end

    test "returns initialized constraints for atomic types" do
      types = ResultTransformer.get_attribute_types(User)

      assert %{type: Ash.Type.String} = types[:email]
    end
  end
end
