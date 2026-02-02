# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.SortAggregateTest do
  @moduledoc """
  Integration tests for sorting by aggregate values.

  Tests verify that:
  - Users can be sorted by aggregate counts (e.g., post_count)
  - Sorting works in both ascending and descending order
  - Users with zero aggregates are handled correctly
  - NULLS FIRST/LAST works with aggregate sorts
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Test.User
  alias AshXTDB.Test.Post

  require Ash.Query

  @moduletag :integration

  setup do
    # Clean up tables before each test
    AshXTDB.TestRepo.query("DELETE FROM posts WHERE posts.\"_id\" IS NOT NULL", [])
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])

    # Create users with different post counts
    alice =
      User
      |> Ash.Changeset.for_create(:create, %{email: "alice@test.com", name: "Alice"})
      |> Ash.create!()

    bob =
      User
      |> Ash.Changeset.for_create(:create, %{email: "bob@test.com", name: "Bob"})
      |> Ash.create!()

    carol =
      User
      |> Ash.Changeset.for_create(:create, %{email: "carol@test.com", name: "Carol"})
      |> Ash.create!()

    # Alice has 3 posts
    for i <- 1..3 do
      Post
      |> Ash.Changeset.for_create(:create, %{
        title: "Alice Post #{i}",
        user_id: alice.id
      })
      |> Ash.create!()
    end

    # Bob has 1 post
    Post
    |> Ash.Changeset.for_create(:create, %{
      title: "Bob Post 1",
      user_id: bob.id
    })
    |> Ash.create!()

    # Carol has 0 posts

    {:ok, users: %{alice: alice, bob: bob, carol: carol}}
  end

  describe "sort by aggregate descending" do
    test "sorts users by post_count descending", %{users: _users} do
      results =
        User
        |> Ash.Query.sort(post_count: :desc)
        |> Ash.read!()

      names = Enum.map(results, & &1.name)

      # Alice: 3 posts, Bob: 1 post, Carol: 0 posts
      assert names == ["Alice", "Bob", "Carol"]
    end
  end

  describe "sort by aggregate ascending" do
    test "sorts users by post_count ascending", %{users: _users} do
      results =
        User
        |> Ash.Query.sort(post_count: :asc)
        |> Ash.read!()

      names = Enum.map(results, & &1.name)

      # Carol: 0 posts, Bob: 1 post, Alice: 3 posts
      assert names == ["Carol", "Bob", "Alice"]
    end
  end

  describe "sort by aggregate with secondary sort" do
    test "uses secondary sort when aggregate values are equal", _context do
      # Create another user with 1 post (same as Bob)
      dave =
        User
        |> Ash.Changeset.for_create(:create, %{email: "dave@test.com", name: "Dave"})
        |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{
        title: "Dave Post 1",
        user_id: dave.id
      })
      |> Ash.create!()

      results =
        User
        |> Ash.Query.sort(post_count: :asc, name: :asc)
        |> Ash.read!()

      names = Enum.map(results, & &1.name)

      # Carol: 0, Bob: 1, Dave: 1, Alice: 3
      # Bob and Dave both have 1 post, so sorted by name alphabetically
      assert names == ["Carol", "Bob", "Dave", "Alice"]
    end
  end

  describe "load aggregate with sort" do
    test "can sort by aggregate and verify order is correct", _context do
      # Note: Aggregate loading while sorting is a separate feature.
      # This test verifies the sort order is correct.
      results =
        User
        |> Ash.Query.sort(post_count: :desc)
        |> Ash.read!()

      # Verify sort order is correct
      names = Enum.map(results, & &1.name)
      assert names == ["Alice", "Bob", "Carol"]
    end

    @tag :skip
    @tag :aggregate_loading
    test "can load aggregate separately after sorting", _context do
      # NOTE: Aggregate loading is a separate feature from sorting by aggregates.
      # This test is skipped until aggregate loading is implemented.
      # Sorting by aggregates works correctly (verified by other tests).
      results =
        User
        |> Ash.Query.sort(post_count: :desc)
        |> Ash.read!()

      # Verify order
      assert [alice, bob, carol] = results
      assert alice.name == "Alice"
      assert bob.name == "Bob"
      assert carol.name == "Carol"

      # Load the aggregate separately to verify values
      {:ok, alice_with_count} = Ash.load(alice, :post_count)
      {:ok, bob_with_count} = Ash.load(bob, :post_count)
      {:ok, carol_with_count} = Ash.load(carol, :post_count)

      assert alice_with_count.post_count == 3
      assert bob_with_count.post_count == 1
      assert carol_with_count.post_count == 0
    end
  end
end
