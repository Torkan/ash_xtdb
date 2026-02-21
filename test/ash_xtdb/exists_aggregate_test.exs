# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.ExistsAggregateTest do
  @moduledoc """
  Tests for aggregate references inside exists() clauses.

  When an aggregate (e.g., user_count, post_count) is referenced inside an
  exists() filter, the aggregate isn't in the root-level alias map. Instead,
  we generate an inline correlated scalar subquery:

      EXISTS (SELECT 1 FROM "organizations" sub0
        WHERE sub0."_id" = t."organization_id"
        AND (SELECT COUNT(*) FROM "users" agg_sub0
             WHERE agg_sub0."organization_id" = sub0."_id") > 0)
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Test.{Organization, Post, Project, User, UserProject}

  require Ash.Query

  @moduletag :integration

  setup do
    tables = [
      {"user_projects", "user_projects"},
      {"post_tags", "post_tags"},
      {"comments", "comments"},
      {"posts", "posts"},
      {"users", "users"},
      {"projects", "projects"},
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

  describe "basic aggregate in exists" do
    setup do
      # Org with users
      org_with_users = create_org("TechCorp", "Technology")
      create_user("alice@test.com", "Alice", 30, true, org_with_users.id)
      create_user("bob@test.com", "Bob", 25, true, org_with_users.id)

      # Org without users
      org_without_users = create_org("EmptyInc", "Finance")

      # Project belonging to org_with_users
      project =
        create_project("Alpha", "ALPHA", org_with_users.id, 50_000, true)

      {:ok,
       %{
         org_with_users: org_with_users,
         org_without_users: org_without_users,
         project: project
       }}
    end

    test "exists(organization, user_count > 0) filters by aggregate in exists", ctx do
      # Projects whose organization has at least one user
      results =
        Project
        |> Ash.Query.filter(
          exists(
            organization,
            user_count > 0
          )
        )
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == ctx.project.id
    end

    test "exists(organization, user_count == 0) matches orgs with no users", ctx do
      # Create a project in the empty org
      empty_project =
        create_project("Beta", "BETA", ctx.org_without_users.id, 10_000, true)

      results =
        Project
        |> Ash.Query.filter(
          exists(
            organization,
            user_count == 0
          )
        )
        |> Ash.read!()

      ids = Enum.map(results, & &1.id)
      assert empty_project.id in ids
      refute ctx.project.id in ids
    end

    test "not exists(organization, user_count > 0) negation works", ctx do
      create_project("Beta", "BETA", ctx.org_without_users.id, 10_000, true)

      results =
        Project
        |> Ash.Query.filter(
          not exists(
            organization,
            user_count > 0
          )
        )
        |> Ash.read!()

      ids = Enum.map(results, & &1.id)
      refute ctx.project.id in ids
      # The project in the empty org should match
      assert length(results) == 1
    end
  end

  describe "aggregate with filter in exists" do
    setup do
      org = create_org("MixedOrg", "Technology")

      alice = create_user("alice@test.com", "Alice", 30, true, org.id)
      bob = create_user("bob@test.com", "Bob", 25, false, org.id)

      project = create_project("Gamma", "GAMMA", org.id, 75_000, true)

      {:ok, %{org: org, alice: alice, bob: bob, project: project}}
    end

    test "exists(organization, active_user_count > 0) uses aggregate with filter", ctx do
      # active_user_count counts only users where active == true
      # MixedOrg has 1 active user (Alice) and 1 inactive (Bob)
      results =
        Project
        |> Ash.Query.filter(
          exists(
            organization,
            active_user_count > 0
          )
        )
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == ctx.project.id
    end

    test "exists(organization, active_user_count > 1) with threshold", ctx do
      # Only 1 active user, so active_user_count > 1 should not match
      results =
        Project
        |> Ash.Query.filter(
          exists(
            organization,
            active_user_count > 1
          )
        )
        |> Ash.read!()

      assert results == []

      # Now activate Bob
      ctx.bob
      |> Ash.Changeset.for_update(:update, %{active: true})
      |> Ash.update!()

      # Now should match
      results =
        Project
        |> Ash.Query.filter(
          exists(
            organization,
            active_user_count > 1
          )
        )
        |> Ash.read!()

      assert length(results) == 1
    end
  end

  describe "aggregate in exists combined with other filters" do
    setup do
      active_org = create_org("ActiveCorp", "Technology")
      inactive_org = create_org("InactiveCorp", "Finance")

      create_user("u1@test.com", "User1", 30, true, active_org.id)

      # Active project in active org
      active_project =
        create_project("ActiveProj", "AP", active_org.id, 50_000, true)

      # Active project in inactive org (no users)
      lonely_project =
        create_project("LonelyProj", "LP", inactive_org.id, 30_000, true)

      # Inactive project in active org
      inactive_project =
        create_project("InactiveProj", "IP", active_org.id, 20_000, false)

      {:ok,
       %{
         active_project: active_project,
         lonely_project: lonely_project,
         inactive_project: inactive_project
       }}
    end

    test "combines exists aggregate with direct attribute filter", ctx do
      # Active projects whose organization has users
      results =
        Project
        |> Ash.Query.filter(
          active == true and
            exists(
              organization,
              user_count > 0
            )
        )
        |> Ash.read!()

      ids = Enum.map(results, & &1.id)
      assert ctx.active_project.id in ids
      refute ctx.lonely_project.id in ids
      refute ctx.inactive_project.id in ids
    end

    test "aggregate in exists combined with aggregate sort at root", ctx do
      # Add members to the active project
      alice = create_user("alice@test.com", "Alice", 30, true, nil)
      bob = create_user("bob@test.com", "Bob", 25, true, nil)
      create_user_project(alice.id, ctx.active_project.id)
      create_user_project(bob.id, ctx.active_project.id)

      # Active projects in orgs with users, sorted by member_count
      results =
        Project
        |> Ash.Query.filter(
          active == true and
            exists(organization, user_count > 0)
        )
        |> Ash.Query.sort(member_count: :desc)
        |> Ash.read!()

      assert results != []
      assert hd(results).id == ctx.active_project.id
    end
  end

  describe "user-level aggregate in exists" do
    setup do
      org = create_org("TestOrg", "Technology")

      alice = create_user("alice@test.com", "Alice", 30, true, org.id)
      bob = create_user("bob@test.com", "Bob", 25, true, org.id)

      # Alice has posts
      create_post("Post 1", "Content", alice.id)
      create_post("Post 2", "Content", alice.id)

      # Bob has no posts

      {:ok, %{org: org, alice: alice, bob: bob}}
    end

    test "exists(users, post_count > 0) on organization", ctx do
      # Organizations that have at least one user with posts
      results =
        Organization
        |> Ash.Query.filter(exists(users, post_count > 0))
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == ctx.org.id
    end

    test "exists(users, post_count >= 2) checks threshold", ctx do
      # Alice has 2 posts, so org should match
      results =
        Organization
        |> Ash.Query.filter(exists(users, post_count >= 2))
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == ctx.org.id

      # No user has 3 posts
      results =
        Organization
        |> Ash.Query.filter(exists(users, post_count >= 3))
        |> Ash.read!()

      assert results == []
    end
  end

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_org(name, industry) do
    Organization
    |> Ash.Changeset.for_create(:create, %{name: name, industry: industry})
    |> Ash.create!()
  end

  defp create_user(email, name, age, active, org_id) do
    attrs = %{email: email, name: name, age: age, active: active}
    attrs = if org_id, do: Map.put(attrs, :organization_id, org_id), else: attrs

    User
    |> Ash.Changeset.for_create(:create, attrs)
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

  defp create_project(name, code, org_id, budget, active) do
    Project
    |> Ash.Changeset.for_create(:create, %{
      name: name,
      code: code,
      organization_id: org_id,
      budget: budget,
      active: active
    })
    |> Ash.create!()
  end

  defp create_user_project(user_id, project_id) do
    UserProject
    |> Ash.Changeset.for_create(:create, %{
      user_id: user_id,
      project_id: project_id
    })
    |> Ash.create!()
  end
end
