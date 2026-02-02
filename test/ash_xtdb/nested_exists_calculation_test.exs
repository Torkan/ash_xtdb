# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.NestedExistsCalculationTest do
  @moduledoc """
  Tests for exists() with nested relationship paths and calculations.

  These tests verify that exists() works correctly with:
  - Calculations on related resources (exists(posts, title_lower == "value"))
  - Multi-level relationship paths (exists(users.posts, ...))
  - Nested exists within exists
  - Complex calculation filters through relationship chains
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Test.{Organization, User, Post}

  require Ash.Query

  @moduletag :integration

  setup do
    # Clean up all tables
    tables = [
      {"post_tags", "post_tags"},
      {"posts", "posts"},
      {"users", "users"},
      {"tags", "tags"},
      {"organizations", "organizations"}
    ]

    for {table, alias_name} <- tables do
      AshXTDB.TestRepo.query(
        "DELETE FROM #{table} WHERE #{alias_name}.\"_id\" IS NOT NULL",
        []
      )
    end

    :ok
  end

  describe "exists with calculation on related resource" do
    setup do
      org = create_org("TestOrg", "Technology")

      alice = create_user("alice@test.com", "Alice", 30, true, org.id)
      bob = create_user("bob@test.com", "Bob", 25, true, org.id)
      carol = create_user("carol@test.com", "Carol", 35, false, org.id)

      # Alice has posts with various titles
      create_post("Hello World", "Content here", alice.id)
      create_post("UPPERCASE TITLE", nil, alice.id)

      # Bob has one post
      create_post("Bob's Post", "Bob's content", bob.id)

      # Carol has no posts

      {:ok, %{org: org, alice: alice, bob: bob, carol: carol}}
    end

    test "exists with title_lower calculation filter", ctx do
      # Find users who have posts where title_lower matches
      # title_lower is string_downcase(title)
      results =
        User
        |> Ash.Query.filter(exists(posts, title_lower == "hello world"))
        |> Ash.read!()

      # Only Alice has "Hello World" which lowercases to "hello world"
      assert length(results) == 1
      assert hd(results).id == ctx.alice.id
    end

    test "exists with has_body boolean calculation", ctx do
      # Find users who have posts where has_body == true
      # has_body is: not is_nil(body)
      results =
        User
        |> Ash.Query.filter(exists(posts, has_body == true))
        |> Ash.read!()

      # Alice has "Hello World" with body, Bob has post with body
      assert length(results) == 2
      ids = Enum.map(results, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([ctx.alice.id, ctx.bob.id])
    end

    test "exists with title_length integer calculation", ctx do
      # Find users who have posts with title_length > 15
      # title_length is string_length(title)
      results =
        User
        |> Ash.Query.filter(exists(posts, title_length > 15))
        |> Ash.read!()

      # "UPPERCASE TITLE" = 15 chars (not > 15)
      # "Hello World" = 11 chars
      # "Bob's Post" = 10 chars
      # None are > 15, so should be empty
      assert results == []
    end

    test "exists with title_length >= threshold", ctx do
      # Find users with posts having title_length >= 11
      results =
        User
        |> Ash.Query.filter(exists(posts, title_length >= 11))
        |> Ash.read!()

      # "Hello World" = 11 chars (Alice)
      # "UPPERCASE TITLE" = 15 chars (Alice)
      # "Bob's Post" = 10 chars (not >= 11)
      assert length(results) == 1
      assert hd(results).id == ctx.alice.id
    end

    test "exists combining multiple calculation filters", ctx do
      # Find users with posts where has_body AND title_length > 8
      results =
        User
        |> Ash.Query.filter(exists(posts, has_body == true and title_length > 8))
        |> Ash.read!()

      # "Hello World" has body, length 11 > 8 (Alice)
      # "Bob's Post" has body, length 10 > 8 (Bob)
      assert length(results) == 2
    end

    test "not exists with calculation", ctx do
      # Find users who DON'T have any posts with has_body == true
      results =
        User
        |> Ash.Query.filter(not exists(posts, has_body == true))
        |> Ash.read!()

      # Carol has no posts at all
      # Alice has "UPPERCASE TITLE" without body but also has one with body
      # Bob has post with body
      # Only Carol should match
      assert length(results) == 1
      assert hd(results).id == ctx.carol.id
    end
  end

  describe "exists with multi-level relationship path" do
    setup do
      # Create organization structure
      tech_org = create_org("TechCorp", "Technology")
      finance_org = create_org("FinanceInc", "Finance")
      empty_org = create_org("EmptyOrg", "Other")

      # Tech org users with posts
      tech_alice = create_user("alice@tech.com", "TechAlice", 30, true, tech_org.id)
      tech_bob = create_user("bob@tech.com", "TechBob", 25, true, tech_org.id)

      # Finance org user with posts
      finance_carol = create_user("carol@finance.com", "FinanceCarol", 35, true, finance_org.id)

      # Empty org has no users

      # Create posts
      create_post("Tech Article", "Technical content", tech_alice.id)
      create_post("Quick Note", nil, tech_alice.id)
      create_post("Bob's Tech Post", "More tech", tech_bob.id)
      create_post("Finance Report", "Financial analysis", finance_carol.id)

      {:ok,
       %{
         tech_org: tech_org,
         finance_org: finance_org,
         empty_org: empty_org,
         tech_alice: tech_alice,
         tech_bob: tech_bob,
         finance_carol: finance_carol
       }}
    end

    test "exists through users.posts path", ctx do
      # Find organizations that have users who have posts
      results =
        Organization
        |> Ash.Query.filter(exists(users.posts, true))
        |> Ash.read!()

      # TechCorp has users with posts
      # FinanceInc has user with posts
      # EmptyOrg has no users
      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["FinanceInc", "TechCorp"]
    end

    test "exists through users.posts with title filter", ctx do
      # Find organizations that have users who have posts with "Tech" in title
      results =
        Organization
        |> Ash.Query.filter(exists(users.posts, contains(title, "Tech")))
        |> Ash.read!()

      # Only TechCorp has posts with "Tech" in title
      assert length(results) == 1
      assert hd(results).id == ctx.tech_org.id
    end

    test "exists through users.posts with calculation filter", ctx do
      # Find organizations that have users who have posts with has_body == true
      results =
        Organization
        |> Ash.Query.filter(exists(users.posts, has_body == true))
        |> Ash.read!()

      # TechCorp: "Tech Article" and "Bob's Tech Post" have body
      # FinanceInc: "Finance Report" has body
      assert length(results) == 2
    end

    test "exists through users.posts with title_lower calculation", ctx do
      # Find organizations that have posts with specific lowercase title
      results =
        Organization
        |> Ash.Query.filter(exists(users.posts, title_lower == "finance report"))
        |> Ash.read!()

      # Only FinanceInc has "Finance Report"
      assert length(results) == 1
      assert hd(results).id == ctx.finance_org.id
    end

    test "not exists through multi-level path", ctx do
      # Find organizations that have NO users with posts containing "Tech"
      results =
        Organization
        |> Ash.Query.filter(not exists(users.posts, contains(title, "Tech")))
        |> Ash.read!()

      # FinanceInc has no "Tech" posts
      # EmptyOrg has no users/posts
      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["EmptyOrg", "FinanceInc"]
    end

    test "exists combined with organization calculation", ctx do
      # Find tech organizations that have users with posts that have body
      results =
        Organization
        |> Ash.Query.filter(is_tech == true and exists(users.posts, has_body == true))
        |> Ash.read!()

      # Only TechCorp is tech AND has posts with body
      assert length(results) == 1
      assert hd(results).id == ctx.tech_org.id
    end
  end

  describe "nested exists (exists within exists expression)" do
    setup do
      # Create a more complex structure
      active_org = create_org("ActiveOrg", "Technology")
      quiet_org = create_org("QuietOrg", "Finance")
      empty_org = create_org("EmptyOrg", "Other")

      # Active org: user with many posts
      active_user = create_user("active@org.com", "ActiveUser", 30, true, active_org.id)
      create_post("Post 1", "Body 1", active_user.id)
      create_post("Post 2", "Body 2", active_user.id)
      create_post("Post 3", nil, active_user.id)

      # Quiet org: user with one post without body
      quiet_user = create_user("quiet@org.com", "QuietUser", 25, true, quiet_org.id)
      create_post("Silent Post", nil, quiet_user.id)

      # Empty org: no users

      {:ok,
       %{
         active_org: active_org,
         quiet_org: quiet_org,
         empty_org: empty_org,
         active_user: active_user,
         quiet_user: quiet_user
       }}
    end

    test "exists users who exist posts with body", ctx do
      # Find organizations that have users who have posts with body
      # This is equivalent to exists(users.posts, has_body)
      results =
        Organization
        |> Ash.Query.filter(exists(users, exists(posts, has_body == true)))
        |> Ash.read!()

      # Only ActiveOrg has user with posts that have body
      assert length(results) == 1
      assert hd(results).id == ctx.active_org.id
    end

    test "exists users who have NO posts with body", ctx do
      # Find organizations where all user posts have no body
      # exists(users, not exists(posts, has_body))
      results =
        Organization
        |> Ash.Query.filter(exists(users, not exists(posts, has_body == true)))
        |> Ash.read!()

      # QuietOrg has user whose posts all have no body
      # ActiveOrg has user with posts without body (Post 3) - matches!
      # Note: This finds orgs where ANY user has no posts with body
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert "QuietOrg" in names
    end

    test "complex nested exists with calculations", ctx do
      # Find organizations that have:
      # - At least one user who is active
      # - AND that user has posts with title_length > 5
      results =
        Organization
        |> Ash.Query.filter(
          exists(users, active == true and exists(posts, title_length > 5))
        )
        |> Ash.read!()

      # ActiveOrg: active user with "Post 1" (6 chars) - matches
      # QuietOrg: active user with "Silent Post" (11 chars) - matches
      assert length(results) == 2
    end
  end

  describe "exists through relationship with user calculations" do
    setup do
      org = create_org("TestOrg", "Technology")

      # Create users of different age brackets
      minor = create_user("minor@test.com", "Minor", 16, true, org.id)
      young_adult = create_user("young@test.com", "YoungAdult", 25, true, org.id)
      senior = create_user("senior@test.com", "Senior", 65, true, org.id)

      # Posts for each
      create_post("Minor's Post", "Young content", minor.id)
      create_post("Adult's Post", "Mature content", young_adult.id)
      create_post("Senior's Wisdom", "Life experience", senior.id)

      {:ok, %{org: org, minor: minor, young_adult: young_adult, senior: senior}}
    end

    test "exists users where user calculation matches", ctx do
      # Find organization with adult users who have posts
      results =
        Organization
        |> Ash.Query.filter(exists(users, is_adult == true and exists(posts, true)))
        |> Ash.read!()

      # TestOrg has YoungAdult and Senior who are adults with posts
      assert length(results) == 1
      assert hd(results).id == ctx.org.id
    end

    test "exists with user age_bracket calculation", ctx do
      # Find organization with "Young Adult" users who have posts
      results =
        Organization
        |> Ash.Query.filter(
          exists(users, age_bracket == "Young Adult" and exists(posts, true))
        )
        |> Ash.read!()

      assert length(results) == 1
    end

    test "combining org calculation with nested user/post calculations", ctx do
      # Monster query: tech org with adult users who have posts with body
      results =
        Organization
        |> Ash.Query.filter(
          is_tech == true and
            exists(users, is_adult == true and exists(posts, has_body == true))
        )
        |> Ash.read!()

      # TestOrg is tech, has adult users (YoungAdult, Senior) with posts with body
      assert length(results) == 1
      assert hd(results).id == ctx.org.id
    end
  end

  describe "SQL generation verification for nested exists" do
    test "generates correct SQL for simple exists" do
      # Verify SQL structure for exists(posts, title == "test")
      state = %{
        resource: AshXTDB.Test.User,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      exists_expr = %Ash.Query.Exists{
        path: [:posts],
        expr: %Ash.Query.Operator.Eq{
          left: %Ash.Query.Ref{attribute: :title, relationship_path: []},
          right: "test"
        },
        at_path: [],
        resource: AshXTDB.Test.User
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(exists_expr, state)

      # Should generate EXISTS subquery
      assert sql =~ "EXISTS"
      assert sql =~ "SELECT 1 FROM"
      assert sql =~ "posts"
      assert sql =~ "title"
    end

    test "generates correct SQL for multi-level exists path" do
      state = %{
        resource: AshXTDB.Test.Organization,
        param_idx: 1,
        params: [],
        joins: %{},
        join_counter: 0,
        table_alias: "t"
      }

      exists_expr = %Ash.Query.Exists{
        path: [:users, :posts],
        expr: true,
        at_path: [],
        resource: AshXTDB.Test.Organization
      }

      {sql, _state} = AshXTDB.SQL.Filter.expression_to_sql_for_test(exists_expr, state)

      # Should generate nested EXISTS subqueries
      assert sql =~ "EXISTS"
      assert sql =~ "SELECT 1 FROM"
      # Should reference both users and posts tables
      assert sql =~ "users"
      assert sql =~ "posts"
    end
  end

  # Helper functions
  defp create_org(name, industry) do
    Organization
    |> Ash.Changeset.for_create(:create, %{name: name, industry: industry})
    |> Ash.create!()
  end

  defp create_user(email, name, age, active, org_id) do
    User
    |> Ash.Changeset.for_create(:create, %{
      email: email,
      name: name,
      age: age,
      active: active,
      organization_id: org_id
    })
    |> Ash.create!()
  end

  defp create_post(title, body, user_id) do
    Post
    |> Ash.Changeset.for_create(:create, %{
      title: title,
      body: body,
      user_id: user_id
    })
    |> Ash.create!()
  end
end
