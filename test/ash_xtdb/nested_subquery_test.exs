# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.NestedSubqueryTest do
  @moduledoc """
  Tests for XTDB NEST_MANY/NEST_ONE subquery support.

  All lateral joins now use NEST_MANY/NEST_ONE for efficient single-query loading.
  """
  use ExUnit.Case, async: false

  alias AshXTDB.NestedResult
  alias AshXTDB.SQL.Nested
  alias AshXTDB.Test.{Post, Tag, User}

  require Ash.Query

  describe "SQL.Nested.build_subquery/2" do
    test "builds NEST_MANY subquery SQL" do
      nested_config = %{
        name: :posts,
        type: :nest_many,
        resource: Post,
        table: "posts",
        correlation: {:id, :user_id},
        limit: 5
      }

      {sql, _params} = Nested.build_subquery(nested_config, "t")

      assert sql =~ "NEST_MANY("
      assert sql =~ "FROM \"posts\" n"
      assert sql =~ "n.\"user_id\" = t.\"_id\""
      assert sql =~ "AS \"posts\""
      assert sql =~ "FETCH FIRST 5 ROWS ONLY"
    end

    test "builds NEST_ONE subquery SQL" do
      nested_config = %{
        name: :user,
        type: :nest_one,
        resource: User,
        table: "users",
        correlation: {:user_id, :id}
      }

      {sql, _params} = Nested.build_subquery(nested_config, "t")

      assert sql =~ "NEST_ONE("
      assert sql =~ "FROM \"users\" n"
      assert sql =~ "AS \"user\""
    end

    test "includes ORDER BY clause when sort is specified" do
      nested_config = %{
        name: :posts,
        type: :nest_many,
        resource: Post,
        table: "posts",
        correlation: {:id, :user_id},
        sort: [{:title, :asc}]
      }

      {sql, _params} = Nested.build_subquery(nested_config, "t")

      assert sql =~ "ORDER BY n.\"title\" ASC"
    end

    test "includes OFFSET clause when offset is specified" do
      nested_config = %{
        name: :posts,
        type: :nest_many,
        resource: Post,
        table: "posts",
        correlation: {:id, :user_id},
        offset: 10,
        limit: 5
      }

      {sql, _params} = Nested.build_subquery(nested_config, "t")

      assert sql =~ "OFFSET 10 ROWS"
      assert sql =~ "FETCH FIRST 5 ROWS ONLY"
    end

    test "builds many-to-many correlation with through subquery" do
      nested_config = %{
        name: :tags,
        type: :nest_many,
        resource: Tag,
        table: "tags",
        correlation:
          {:through_subquery,
           %{
             through_table: "post_tags",
             source_attr_on_join: :post_id,
             dest_attr_on_join: :tag_id,
             destination_attribute: :id,
             source_attribute: :id
           }},
        limit: 5
      }

      {sql, _params} = Nested.build_subquery(nested_config, "t")

      assert sql =~ "NEST_MANY("
      assert sql =~ "FROM \"tags\" n"

      assert sql =~
               "n.\"_id\" IN (SELECT th.\"tag_id\" FROM \"post_tags\" th WHERE th.\"post_id\" = t.\"_id\")"

      assert sql =~ "AS \"tags\""
    end
  end

  describe "NestedResult.extract_nested/4" do
    test "extracts nested records from parent with __lateral_join_source__" do
      parent_records = [
        %{
          id: "user1",
          name: "Alice",
          posts: [
            %{_id: "p1", title: "Post 1", body: "Body 1", user_id: "user1"},
            %{_id: "p2", title: "Post 2", body: "Body 2", user_id: "user1"}
          ]
        },
        %{
          id: "user2",
          name: "Bob",
          posts: [
            %{_id: "p3", title: "Post 3", body: "Body 3", user_id: "user2"}
          ]
        }
      ]

      nested_records = NestedResult.extract_nested(parent_records, :posts, Post, User)

      assert length(nested_records) == 3

      # Check that each record has __lateral_join_source__
      assert Enum.all?(nested_records, fn r -> Map.has_key?(r, :__lateral_join_source__) end)

      # Check parent attribution
      user1_posts = Enum.filter(nested_records, &(&1.__lateral_join_source__.id == "user1"))
      user2_posts = Enum.filter(nested_records, &(&1.__lateral_join_source__.id == "user2"))

      assert length(user1_posts) == 2
      assert length(user2_posts) == 1
    end

    test "handles empty nested arrays" do
      parent_records = [
        %{id: "user1", name: "Alice", posts: []},
        %{id: "user2", name: "Bob", posts: nil}
      ]

      nested_records = NestedResult.extract_nested(parent_records, :posts, Post, User)

      assert nested_records == []
    end
  end

  describe "NestedResult.transform_rows/3" do
    test "transforms rows with nested JSON data" do
      rows = [
        [
          "user1",
          "Alice",
          [%{"_id" => "p1", "title" => "Post 1"}, %{"_id" => "p2", "title" => "Post 2"}]
        ],
        ["user2", "Bob", [%{"_id" => "p3", "title" => "Post 3"}]]
      ]

      columns = ["id", "name", "posts"]
      nested_configs = [%{name: :posts, type: :nest_many, resource: Post}]

      result = NestedResult.transform_rows(rows, columns, nested_configs)

      assert length(result) == 2
      assert hd(result).id == "user1"
      assert length(hd(result).posts) == 2
    end
  end

  describe "NEST_MANY/NEST_ONE SQL execution" do
    # Helper to parse JSON string results from XTDB
    defp parse_nested(nil), do: nil
    defp parse_nested("[]"), do: []
    defp parse_nested(json) when is_binary(json), do: Jason.decode!(json)
    defp parse_nested(list) when is_list(list), do: list
    defp parse_nested(map) when is_map(map), do: map

    setup do
      # Create test users with unique emails for this test
      user1 =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "nest_alice_#{System.unique_integer([:positive])}@test.com",
          name: "NestAlice",
          age: 30
        })
        |> Ash.create!()

      user2 =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "nest_bob_#{System.unique_integer([:positive])}@test.com",
          name: "NestBob",
          age: 25
        })
        |> Ash.create!()

      # Create posts for users
      post1 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "NestAlice Post 1",
          body: "Body 1",
          user_id: user1.id
        })
        |> Ash.create!()

      post2 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "NestAlice Post 2",
          body: "Body 2",
          user_id: user1.id
        })
        |> Ash.create!()

      post3 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "NestBob Post 1",
          body: "Body 3",
          user_id: user2.id
        })
        |> Ash.create!()

      {:ok, user1: user1, user2: user2, posts: [post1, post2, post3]}
    end

    test "executes NEST_MANY query for user posts", %{user1: user1, user2: user2} do
      # Build NEST_MANY query filtering to just our test users
      sql = """
      SELECT t."_id" AS id, t.name,
             NEST_MANY(SELECT n."_id", n.title, n.body FROM posts n WHERE n.user_id = t."_id") AS posts
      FROM users t
      WHERE t."_id" IN ('#{user1.id}', '#{user2.id}')
      ORDER BY t.name ASC
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: rows}} ->
          assert length(rows) == 2

          # First row should be NestAlice (alphabetically first)
          [alice_id, alice_name, alice_posts_raw] = Enum.at(rows, 0)
          alice_posts = parse_nested(alice_posts_raw)
          assert alice_name == "NestAlice"
          assert alice_id == user1.id
          assert is_list(alice_posts)
          assert length(alice_posts) == 2

          # Second row should be NestBob
          [bob_id, bob_name, bob_posts_raw] = Enum.at(rows, 1)
          bob_posts = parse_nested(bob_posts_raw)
          assert bob_name == "NestBob"
          assert bob_id == user2.id
          assert is_list(bob_posts)
          assert length(bob_posts) == 1

        {:error, error} ->
          flunk("NEST_MANY query failed: #{inspect(error)}")
      end
    end

    test "executes NEST_MANY query with ORDER BY in subquery", %{user1: user1} do
      sql = """
      SELECT t."_id" AS id, t.name,
             NEST_MANY(SELECT n."_id", n.title FROM posts n WHERE n.user_id = t."_id" ORDER BY n.title DESC) AS posts
      FROM users t
      WHERE t."_id" = '#{user1.id}'
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[_id, _name, posts_raw]]}} ->
          posts = parse_nested(posts_raw)
          assert length(posts) == 2
          # Posts should be ordered by title descending
          titles = Enum.map(posts, fn p -> p["title"] end)
          assert titles == Enum.sort(titles, :desc)

        {:error, error} ->
          flunk("NEST_MANY with ORDER BY failed: #{inspect(error)}")
      end
    end

    test "executes NEST_MANY query with LIMIT", %{user1: user1} do
      sql = """
      SELECT t."_id" AS id, t.name,
             NEST_MANY(SELECT n."_id", n.title FROM posts n WHERE n.user_id = t."_id" FETCH FIRST 1 ROWS ONLY) AS posts
      FROM users t
      WHERE t."_id" = '#{user1.id}'
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[_id, _name, posts_raw]]}} ->
          posts = parse_nested(posts_raw)
          # Should only have 1 post due to LIMIT
          assert length(posts) == 1

        {:error, error} ->
          flunk("NEST_MANY with LIMIT failed: #{inspect(error)}")
      end
    end

    test "executes NEST_ONE query for post author", %{user1: user1, posts: [post1 | _]} do
      sql = """
      SELECT t."_id" AS id, t.title,
             NEST_ONE(SELECT n."_id", n.name, n.email FROM users n WHERE n."_id" = t.user_id) AS author
      FROM posts t
      WHERE t."_id" = '#{post1.id}'
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[_id, title, author_raw]]}} ->
          author = parse_nested(author_raw)
          assert title == "NestAlice Post 1"
          assert is_map(author)
          assert author["name"] == "NestAlice"
          assert author["_id"] == user1.id

        {:error, error} ->
          flunk("NEST_ONE query failed: #{inspect(error)}")
      end
    end

    test "NEST_MANY returns empty array for users with no posts" do
      # Create a user with no posts
      user_no_posts =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "noposts_#{System.unique_integer([:positive])}@test.com",
          name: "No Posts",
          age: 40
        })
        |> Ash.create!()

      sql = """
      SELECT t."_id" AS id, t.name,
             NEST_MANY(SELECT n."_id", n.title FROM posts n WHERE n.user_id = t."_id") AS posts
      FROM users t
      WHERE t."_id" = '#{user_no_posts.id}'
      """

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[_id, _name, posts_raw]]}} ->
          posts = parse_nested(posts_raw)
          # Should return empty array for user with no posts
          # XTDB may return nil or [] for empty nested results
          assert posts in [[], nil], "Expected empty array or nil, got: #{inspect(posts)}"

        {:error, error} ->
          flunk("NEST_MANY for user with no posts failed: #{inspect(error)}")
      end
    end
  end
end
