# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.LateralJoinTest do
  @moduledoc """
  Tests for lateral join support.

  Lateral joins in Ash allow loading relationships with per-parent scoping,
  enabling features like "first 5 posts per user" or "posts with offset per user".

  XTDB doesn't support the SQL LATERAL keyword, so ash_xtdb implements this
  via iteration - running a correlated query for each parent record.
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Test.{Post, PostTag, Tag, User}

  require Ash.Query

  setup do
    # Clean up tables before each test
    AshXTDB.TestRepo.query("DELETE FROM post_tags WHERE post_tags.\"_id\" IS NOT NULL", [])
    AshXTDB.TestRepo.query("DELETE FROM tags WHERE tags.\"_id\" IS NOT NULL", [])
    AshXTDB.TestRepo.query("DELETE FROM posts WHERE posts.\"_id\" IS NOT NULL", [])
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])

    :ok
  end

  describe "has_many with limit (lateral join)" do
    test "loads limited posts per user" do
      # Create two users
      user1 =
        User
        |> Ash.Changeset.for_create(:create, %{email: "user1@test.com", name: "User One"})
        |> Ash.create!()

      user2 =
        User
        |> Ash.Changeset.for_create(:create, %{email: "user2@test.com", name: "User Two"})
        |> Ash.create!()

      # Create 5 posts for user1
      for i <- 1..5 do
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "User1 Post #{i}",
          body: "Body #{i}",
          user_id: user1.id
        })
        |> Ash.create!()
      end

      # Create 3 posts for user2
      for i <- 1..3 do
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "User2 Post #{i}",
          body: "Body #{i}",
          user_id: user2.id
        })
        |> Ash.create!()
      end

      # Load users with limited posts (first 2 posts per user)
      users =
        User
        |> Ash.Query.filter(id in [^user1.id, ^user2.id])
        |> Ash.Query.load(posts: Ash.Query.limit(Post, 2))
        |> Ash.read!()

      user1_loaded = Enum.find(users, &(&1.id == user1.id))
      user2_loaded = Enum.find(users, &(&1.id == user2.id))

      # Each user should have at most 2 posts
      assert length(user1_loaded.posts) == 2
      assert length(user2_loaded.posts) == 2
    end

    test "loads posts with offset and limit per user" do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{email: "pager@test.com", name: "Pager"})
        |> Ash.create!()

      # Create 10 posts with predictable titles for sorting
      for i <- 1..10 do
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Post #{String.pad_leading(Integer.to_string(i), 2, "0")}",
          body: "Body #{i}",
          user_id: user.id
        })
        |> Ash.create!()
      end

      # Load user with posts: skip 2, take 3
      posts_query =
        Post
        |> Ash.Query.sort(title: :asc)
        |> Ash.Query.offset(2)
        |> Ash.Query.limit(3)

      [loaded_user] =
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.Query.load(posts: posts_query)
        |> Ash.read!()

      assert length(loaded_user.posts) == 3
      titles = Enum.map(loaded_user.posts, & &1.title)
      # After sorting and offset 2, should get posts 03, 04, 05
      assert "Post 03" in titles
      assert "Post 04" in titles
      assert "Post 05" in titles
    end
  end

  describe "belongs_to loading" do
    test "loads user for each post" do
      user1 =
        User
        |> Ash.Changeset.for_create(:create, %{email: "author1@test.com", name: "Author One"})
        |> Ash.create!()

      user2 =
        User
        |> Ash.Changeset.for_create(:create, %{email: "author2@test.com", name: "Author Two"})
        |> Ash.create!()

      post1 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Post by Author One",
          user_id: user1.id
        })
        |> Ash.create!()

      post2 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Post by Author Two",
          user_id: user2.id
        })
        |> Ash.create!()

      # Load posts with their users
      posts =
        Post
        |> Ash.Query.filter(id in [^post1.id, ^post2.id])
        |> Ash.Query.load(:user)
        |> Ash.read!()

      post1_loaded = Enum.find(posts, &(&1.id == post1.id))
      post2_loaded = Enum.find(posts, &(&1.id == post2.id))

      assert post1_loaded.user.name == "Author One"
      assert post2_loaded.user.name == "Author Two"
    end
  end

  describe "many_to_many relationship" do
    test "loads tags through join table" do
      # Create posts
      post1 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Tagged Post 1",
          user_id: Ash.UUID.generate()
        })
        |> Ash.create!()

      post2 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Tagged Post 2",
          user_id: Ash.UUID.generate()
        })
        |> Ash.create!()

      # Create tags
      tag_elixir =
        Tag
        |> Ash.Changeset.for_create(:create, %{name: "elixir"})
        |> Ash.create!()

      tag_xtdb =
        Tag
        |> Ash.Changeset.for_create(:create, %{name: "xtdb"})
        |> Ash.create!()

      tag_ash =
        Tag
        |> Ash.Changeset.for_create(:create, %{name: "ash"})
        |> Ash.create!()

      # Link post1 to elixir and ash
      PostTag
      |> Ash.Changeset.for_create(:create, %{post_id: post1.id, tag_id: tag_elixir.id})
      |> Ash.create!()

      PostTag
      |> Ash.Changeset.for_create(:create, %{post_id: post1.id, tag_id: tag_ash.id})
      |> Ash.create!()

      # Link post2 to xtdb and ash
      PostTag
      |> Ash.Changeset.for_create(:create, %{post_id: post2.id, tag_id: tag_xtdb.id})
      |> Ash.create!()

      PostTag
      |> Ash.Changeset.for_create(:create, %{post_id: post2.id, tag_id: tag_ash.id})
      |> Ash.create!()

      # Load posts with their tags
      posts =
        Post
        |> Ash.Query.filter(id in [^post1.id, ^post2.id])
        |> Ash.Query.load(:tags)
        |> Ash.read!()

      post1_loaded = Enum.find(posts, &(&1.id == post1.id))
      post2_loaded = Enum.find(posts, &(&1.id == post2.id))

      post1_tag_names = Enum.map(post1_loaded.tags, & &1.name) |> Enum.sort()
      post2_tag_names = Enum.map(post2_loaded.tags, & &1.name) |> Enum.sort()

      assert post1_tag_names == ["ash", "elixir"]
      assert post2_tag_names == ["ash", "xtdb"]
    end

    test "loads posts for tags (reverse many_to_many)" do
      # Create posts
      post1 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Elixir Tutorial",
          user_id: Ash.UUID.generate()
        })
        |> Ash.create!()

      post2 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "XTDB Guide",
          user_id: Ash.UUID.generate()
        })
        |> Ash.create!()

      # Create tag
      tag =
        Tag
        |> Ash.Changeset.for_create(:create, %{name: "database"})
        |> Ash.create!()

      # Link both posts to tag
      PostTag
      |> Ash.Changeset.for_create(:create, %{post_id: post1.id, tag_id: tag.id})
      |> Ash.create!()

      PostTag
      |> Ash.Changeset.for_create(:create, %{post_id: post2.id, tag_id: tag.id})
      |> Ash.create!()

      # Load tag with its posts
      [loaded_tag] =
        Tag
        |> Ash.Query.filter(id == ^tag.id)
        |> Ash.Query.load(:posts)
        |> Ash.read!()

      assert length(loaded_tag.posts) == 2
      post_titles = Enum.map(loaded_tag.posts, & &1.title) |> Enum.sort()
      assert post_titles == ["Elixir Tutorial", "XTDB Guide"]
    end

    test "loads many_to_many with limit" do
      # Create a post with many tags
      post =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Multi-tagged Post",
          user_id: Ash.UUID.generate()
        })
        |> Ash.create!()

      # Create 5 tags
      tags =
        for i <- 1..5 do
          Tag
          |> Ash.Changeset.for_create(:create, %{name: "tag#{i}"})
          |> Ash.create!()
        end

      # Link all tags to post
      for tag <- tags do
        PostTag
        |> Ash.Changeset.for_create(:create, %{post_id: post.id, tag_id: tag.id})
        |> Ash.create!()
      end

      # Load post with limited tags
      [loaded_post] =
        Post
        |> Ash.Query.filter(id == ^post.id)
        |> Ash.Query.load(tags: Ash.Query.limit(Tag, 3))
        |> Ash.read!()

      assert length(loaded_post.tags) == 3
    end
  end

  describe "lateral join capability" do
    test "reports lateral join capability for XTDB resources" do
      # All test resources use AshXTDB.DataLayer
      assert AshXTDB.DataLayer.can?(User, {:lateral_join, [Post]})
      assert AshXTDB.DataLayer.can?(Post, {:lateral_join, [User]})
      assert AshXTDB.DataLayer.can?(Post, {:lateral_join, [Tag, PostTag]})
    end

    test "prefer_lateral_join_for_many_to_many? returns false" do
      # XTDB uses iteration which is less efficient, so we don't prefer it
      refute AshXTDB.DataLayer.prefer_lateral_join_for_many_to_many?()
    end
  end
end
