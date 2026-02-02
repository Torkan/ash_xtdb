# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.FixedLimitationsTest do
  @moduledoc """
  Integration tests for previously known limitations that have been fixed.

  These tests verify that the following features now work correctly:
  1. Boolean type coercion from XTDB ("t"/"f" -> true/false)
  2. Aggregate filters at top level (post_count >= N)
  3. Many-to-many relationship exists filters (both directions)
  4. Deep nested exists (3+ levels)

  Each test uses precise data setup and asserts exact expected results.
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Test.{Organization, User, Post, Comment, Tag, PostTag, Project, UserProject}

  require Ash.Query

  @moduletag :integration

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup do
    # Clean up all tables in dependency order
    cleanup_tables()

    :ok
  end

  defp cleanup_tables do
    tables = [
      "comments",
      "post_tags",
      "user_projects",
      "posts",
      "tags",
      "categories",
      "projects",
      "users",
      "organizations"
    ]

    for table <- tables do
      AshXTDB.TestRepo.query("DELETE FROM #{table} WHERE #{table}.\"_id\" IS NOT NULL", [])
    end
  end

  # ============================================================================
  # 1. Boolean Type Coercion Tests
  # ============================================================================

  describe "boolean type coercion" do
    setup do
      # Create users with various boolean states
      active_user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "active@test.com",
          name: "ActiveUser",
          age: 30,
          active: true
        })
        |> Ash.create!()

      inactive_user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "inactive@test.com",
          name: "InactiveUser",
          age: 25,
          active: false
        })
        |> Ash.create!()

      {:ok, active_user: active_user, inactive_user: inactive_user}
    end

    test "boolean true is returned as Elixir true, not string", %{active_user: user} do
      [reloaded] =
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.read!()

      # Must be actual boolean, not "t" string
      assert reloaded.active === true
      assert is_boolean(reloaded.active)
    end

    test "boolean false is returned as Elixir false, not string", %{inactive_user: user} do
      [reloaded] =
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.read!()

      # Must be actual boolean, not "f" string
      assert reloaded.active === false
      assert is_boolean(reloaded.active)
    end

    test "filtering by boolean true works correctly" do
      active_users =
        User
        |> Ash.Query.filter(active == true)
        |> Ash.read!()

      assert length(active_users) == 1
      assert hd(active_users).name == "ActiveUser"
      assert hd(active_users).active === true
    end

    test "filtering by boolean false works correctly" do
      inactive_users =
        User
        |> Ash.Query.filter(active == false)
        |> Ash.read!()

      assert length(inactive_users) == 1
      assert hd(inactive_users).name == "InactiveUser"
      assert hd(inactive_users).active === false
    end

    test "boolean values in loaded relationships are properly coerced" do
      # Create org with users
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TestOrg", active: true, employee_count: 10})
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "orguser@test.com",
        name: "OrgUser",
        age: 35,
        active: true,
        organization_id: org.id
      })
      |> Ash.create!()

      # Load organization with users
      [loaded_org] =
        Organization
        |> Ash.Query.filter(id == ^org.id)
        |> Ash.Query.load(:users)
        |> Ash.read!()

      assert loaded_org.active === true
      assert is_boolean(loaded_org.active)

      [user] = loaded_org.users
      assert user.active === true
      assert is_boolean(user.active)
    end
  end

  # ============================================================================
  # 2. Aggregate Filter Tests
  # ============================================================================

  describe "aggregate filters at top level" do
    setup do
      # Create users with different numbers of posts
      # Alice: 0 posts, Bob: 1 post, Carol: 3 posts, Dave: 5 posts
      alice =
        User
        |> Ash.Changeset.for_create(:create, %{email: "alice@test.com", name: "Alice", age: 25, active: true})
        |> Ash.create!()

      bob =
        User
        |> Ash.Changeset.for_create(:create, %{email: "bob@test.com", name: "Bob", age: 30, active: true})
        |> Ash.create!()

      carol =
        User
        |> Ash.Changeset.for_create(:create, %{email: "carol@test.com", name: "Carol", age: 28, active: true})
        |> Ash.create!()

      dave =
        User
        |> Ash.Changeset.for_create(:create, %{email: "dave@test.com", name: "Dave", age: 35, active: false})
        |> Ash.create!()

      # Create posts: Bob=1, Carol=3, Dave=5
      create_posts(bob, 1)
      create_posts(carol, 3)
      create_posts(dave, 5)

      {:ok, alice: alice, bob: bob, carol: carol, dave: dave}
    end

    defp create_posts(user, count) do
      for i <- 1..count do
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Post #{i} by #{user.name}",
          user_id: user.id,
          published: true
        })
        |> Ash.create!()
      end
    end

    test "filter by aggregate equals zero" do
      users_with_no_posts =
        User
        |> Ash.Query.filter(post_count == 0)
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(users_with_no_posts, & &1.name)
      assert names == ["Alice"]
    end

    test "filter by aggregate greater than" do
      users_with_many_posts =
        User
        |> Ash.Query.filter(post_count > 2)
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(users_with_many_posts, & &1.name)
      assert names == ["Carol", "Dave"]
    end

    test "filter by aggregate greater than or equal" do
      users =
        User
        |> Ash.Query.filter(post_count >= 3)
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(users, & &1.name)
      assert names == ["Carol", "Dave"]
    end

    test "filter by aggregate less than" do
      users =
        User
        |> Ash.Query.filter(post_count < 3)
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(users, & &1.name)
      assert names == ["Alice", "Bob"]
    end

    test "filter by aggregate combined with other filters" do
      # Active users with at least 1 post
      users =
        User
        |> Ash.Query.filter(active == true and post_count >= 1)
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(users, & &1.name)
      assert names == ["Bob", "Carol"]
    end

    test "filter by aggregate with complex boolean expression" do
      # Users who have many posts (>2) OR are inactive
      users =
        User
        |> Ash.Query.filter(post_count > 2 or active == false)
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(users, & &1.name)
      # Carol (3 posts, active), Dave (5 posts, inactive - matches both conditions)
      assert names == ["Carol", "Dave"]
    end

    test "filter and sort by same aggregate" do
      users =
        User
        |> Ash.Query.filter(post_count >= 1)
        |> Ash.Query.sort(post_count: :desc)
        |> Ash.read!()

      names = Enum.map(users, & &1.name)
      # Sorted by post_count desc: Dave(5), Carol(3), Bob(1)
      assert names == ["Dave", "Carol", "Bob"]
    end

    test "filter by multiple aggregates" do
      # Create some comments on posts
      [dave_post | _] =
        Post
        |> Ash.Query.filter(exists(user, name == "Dave"))
        |> Ash.read!()

      Comment
      |> Ash.Changeset.for_create(:create, %{
        content: "Comment 1",
        post_id: dave_post.id,
        author_id: dave_post.user_id,
        approved: true,
        likes: 5
      })
      |> Ash.create!()

      # Users with posts that have comments
      users =
        User
        |> Ash.Query.filter(post_count >= 1 and comment_count >= 1)
        |> Ash.read!()

      names = Enum.map(users, & &1.name)
      assert names == ["Dave"]
    end
  end

  # ============================================================================
  # 3. Many-to-Many Exists Filter Tests
  # ============================================================================

  describe "many-to-many exists filters" do
    setup do
      # Create a user for posts
      user =
        User
        |> Ash.Changeset.for_create(:create, %{email: "m2m@test.com", name: "M2MUser", age: 30, active: true})
        |> Ash.create!()

      # Create tags with different priorities
      elixir_tag = Tag |> Ash.Changeset.for_create(:create, %{name: "elixir", priority: 100}) |> Ash.create!()
      phoenix_tag = Tag |> Ash.Changeset.for_create(:create, %{name: "phoenix", priority: 90}) |> Ash.create!()
      xtdb_tag = Tag |> Ash.Changeset.for_create(:create, %{name: "xtdb", priority: 80}) |> Ash.create!()
      unused_tag = Tag |> Ash.Changeset.for_create(:create, %{name: "unused", priority: 10}) |> Ash.create!()

      # Create posts with different publication states
      published_post1 =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "Published 1", published: true, user_id: user.id})
        |> Ash.create!()

      published_post2 =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "Published 2", published: true, user_id: user.id})
        |> Ash.create!()

      draft_post =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "Draft", published: false, user_id: user.id})
        |> Ash.create!()

      # Link tags to posts:
      # - elixir_tag: linked to published_post1 and draft_post
      # - phoenix_tag: linked to published_post1 only
      # - xtdb_tag: linked to draft_post only
      # - unused_tag: not linked to any posts
      PostTag |> Ash.Changeset.for_create(:create, %{post_id: published_post1.id, tag_id: elixir_tag.id}) |> Ash.create!()
      PostTag |> Ash.Changeset.for_create(:create, %{post_id: draft_post.id, tag_id: elixir_tag.id}) |> Ash.create!()
      PostTag |> Ash.Changeset.for_create(:create, %{post_id: published_post1.id, tag_id: phoenix_tag.id}) |> Ash.create!()
      PostTag |> Ash.Changeset.for_create(:create, %{post_id: draft_post.id, tag_id: xtdb_tag.id}) |> Ash.create!()
      PostTag |> Ash.Changeset.for_create(:create, %{post_id: published_post2.id, tag_id: elixir_tag.id}) |> Ash.create!()

      {:ok,
       user: user,
       elixir_tag: elixir_tag,
       phoenix_tag: phoenix_tag,
       xtdb_tag: xtdb_tag,
       unused_tag: unused_tag,
       published_post1: published_post1,
       published_post2: published_post2,
       draft_post: draft_post}
    end

    test "tags that have any posts (exists with true)", _ctx do
      tags =
        Tag
        |> Ash.Query.filter(exists(posts, true))
        |> Ash.Query.sort(priority: :desc)
        |> Ash.read!()

      names = Enum.map(tags, & &1.name)
      # elixir, phoenix, xtdb have posts; unused does not
      assert names == ["elixir", "phoenix", "xtdb"]
      refute "unused" in names
    end

    test "tags that have published posts", _ctx do
      tags =
        Tag
        |> Ash.Query.filter(exists(posts, published == true))
        |> Ash.Query.sort(priority: :desc)
        |> Ash.read!()

      names = Enum.map(tags, & &1.name)
      # elixir and phoenix have published posts; xtdb only has draft
      assert names == ["elixir", "phoenix"]
      refute "xtdb" in names
      refute "unused" in names
    end

    test "tags that have only unpublished posts" do
      # Tags that have posts but none are published
      # We need to use NOT exists for published posts AND exists for any posts
      tags =
        Tag
        |> Ash.Query.filter(exists(posts, true) and not exists(posts, published == true))
        |> Ash.Query.sort(priority: :desc)
        |> Ash.read!()

      names = Enum.map(tags, & &1.name)
      # xtdb only has draft posts
      assert names == ["xtdb"]
    end

    test "posts that have high-priority tags (reverse direction)", _ctx do
      posts =
        Post
        |> Ash.Query.filter(exists(tags, priority >= 90))
        |> Ash.Query.sort(title: :asc)
        |> Ash.read!()

      titles = Enum.map(posts, & &1.title)
      # Published 1 has elixir(100) and phoenix(90)
      # Published 2 has elixir(100)
      # Draft has elixir(100) and xtdb(80) - but xtdb < 90, elixir qualifies
      assert titles == ["Draft", "Published 1", "Published 2"]
    end

    test "posts that have tags with specific name", _ctx do
      posts =
        Post
        |> Ash.Query.filter(exists(tags, name == "phoenix"))
        |> Ash.read!()

      titles = Enum.map(posts, & &1.title)
      # Only Published 1 has the phoenix tag
      assert titles == ["Published 1"]
    end

    test "many-to-many with combined filters" do
      # Tags that have published posts with specific titles
      tags =
        Tag
        |> Ash.Query.filter(exists(posts, published == true and title == "Published 1"))
        |> Ash.Query.sort(priority: :desc)
        |> Ash.read!()

      names = Enum.map(tags, & &1.name)
      # elixir and phoenix are on Published 1
      assert names == ["elixir", "phoenix"]
    end
  end

  # ============================================================================
  # 4. Deep Nested Exists Tests (3+ levels)
  # ============================================================================

  describe "three-level nested exists" do
    setup do
      # Organization -> Users -> Posts
      org_with_posts =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "OrgWithPosts", active: true, employee_count: 10})
        |> Ash.create!()

      org_without_posts =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "OrgWithoutPosts", active: true, employee_count: 5})
        |> Ash.create!()

      org_inactive =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "OrgInactive", active: false, employee_count: 3})
        |> Ash.create!()

      # Create users
      user_with_posts =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "poster@test.com",
          name: "Poster",
          age: 30,
          active: true,
          organization_id: org_with_posts.id
        })
        |> Ash.create!()

      _user_without_posts =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "lurker@test.com",
          name: "Lurker",
          age: 25,
          active: true,
          organization_id: org_without_posts.id
        })
        |> Ash.create!()

      user_in_inactive_org =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "inactive_org@test.com",
          name: "InactiveOrgUser",
          age: 35,
          active: true,
          organization_id: org_inactive.id
        })
        |> Ash.create!()

      # Create posts
      published_post =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Published Post",
          published: true,
          user_id: user_with_posts.id
        })
        |> Ash.create!()

      _draft_post =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Draft Post",
          published: false,
          user_id: user_with_posts.id
        })
        |> Ash.create!()

      # User in inactive org also has a post
      Post
      |> Ash.Changeset.for_create(:create, %{
        title: "Inactive Org Post",
        published: true,
        user_id: user_in_inactive_org.id
      })
      |> Ash.create!()

      {:ok,
       org_with_posts: org_with_posts,
       org_without_posts: org_without_posts,
       org_inactive: org_inactive,
       user_with_posts: user_with_posts,
       published_post: published_post}
    end

    test "3-level: org -> users -> posts (any posts)" do
      orgs =
        Organization
        |> Ash.Query.filter(exists(users, exists(posts, true)))
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(orgs, & &1.name)
      # OrgWithPosts and OrgInactive have users with posts
      assert names == ["OrgInactive", "OrgWithPosts"]
      refute "OrgWithoutPosts" in names
    end

    test "3-level: org -> users -> posts (published posts only)" do
      orgs =
        Organization
        |> Ash.Query.filter(exists(users, exists(posts, published == true)))
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(orgs, & &1.name)
      # Both orgs with users who have published posts
      assert names == ["OrgInactive", "OrgWithPosts"]
    end

    test "3-level with filter at each level" do
      # Active orgs -> active users -> published posts
      orgs =
        Organization
        |> Ash.Query.filter(
          active == true and
            exists(users, active == true and exists(posts, published == true))
        )
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(orgs, & &1.name)
      # Only OrgWithPosts is active and has active users with published posts
      assert names == ["OrgWithPosts"]
    end
  end

  describe "four-level nested exists" do
    setup do
      # Organization -> Users -> Posts -> Comments
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "CommentOrg", active: true, employee_count: 10})
        |> Ash.create!()

      org_no_comments =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "NoCommentOrg", active: true, employee_count: 5})
        |> Ash.create!()

      user_with_comments =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "commenter@test.com",
          name: "Commenter",
          age: 30,
          active: true,
          organization_id: org.id
        })
        |> Ash.create!()

      user_without_comments =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "silent@test.com",
          name: "Silent",
          age: 25,
          active: true,
          organization_id: org_no_comments.id
        })
        |> Ash.create!()

      post_with_comments =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Post with comments",
          published: true,
          user_id: user_with_comments.id
        })
        |> Ash.create!()

      _post_without_comments =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Post without comments",
          published: true,
          user_id: user_without_comments.id
        })
        |> Ash.create!()

      approved_comment =
        Comment
        |> Ash.Changeset.for_create(:create, %{
          content: "Approved comment",
          approved: true,
          likes: 10,
          post_id: post_with_comments.id,
          author_id: user_with_comments.id
        })
        |> Ash.create!()

      _unapproved_comment =
        Comment
        |> Ash.Changeset.for_create(:create, %{
          content: "Unapproved comment",
          approved: false,
          likes: 2,
          post_id: post_with_comments.id,
          author_id: user_with_comments.id
        })
        |> Ash.create!()

      {:ok,
       org: org,
       org_no_comments: org_no_comments,
       approved_comment: approved_comment}
    end

    test "4-level: org -> users -> posts -> comments (any comments)" do
      orgs =
        Organization
        |> Ash.Query.filter(
          exists(users,
            exists(posts,
              exists(comments, true)
            )
          )
        )
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(orgs, & &1.name)
      assert names == ["CommentOrg"]
      refute "NoCommentOrg" in names
    end

    test "4-level: org -> users -> posts -> comments (approved comments)" do
      orgs =
        Organization
        |> Ash.Query.filter(
          exists(users,
            exists(posts,
              exists(comments, approved == true)
            )
          )
        )
        |> Ash.read!()

      names = Enum.map(orgs, & &1.name)
      assert names == ["CommentOrg"]
    end

    test "4-level: org -> users -> posts -> comments (popular comments)" do
      orgs =
        Organization
        |> Ash.Query.filter(
          exists(users,
            exists(posts,
              exists(comments, likes >= 5)
            )
          )
        )
        |> Ash.read!()

      names = Enum.map(orgs, & &1.name)
      # Only the approved comment has 10 likes
      assert names == ["CommentOrg"]
    end

    test "4-level with filters at all levels" do
      orgs =
        Organization
        |> Ash.Query.filter(
          active == true and
            exists(
              users,
              active == true and
                exists(
                  posts,
                  published == true and
                    exists(comments, approved == true and likes >= 5)
                )
            )
        )
        |> Ash.read!()

      names = Enum.map(orgs, & &1.name)
      assert names == ["CommentOrg"]
    end
  end

  describe "nested exists through many-to-many (projects -> members)" do
    setup do
      # Organization -> Projects -> Members (via UserProject)
      org_with_members =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "OrgWithMembers", active: true, employee_count: 10})
        |> Ash.create!()

      org_without_members =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "OrgWithoutMembers", active: true, employee_count: 5})
        |> Ash.create!()

      project_with_members =
        Project
        |> Ash.Changeset.for_create(:create, %{
          name: "ProjectWithMembers",
          code: "PWM",
          status: "active",
          active: true,
          organization_id: org_with_members.id
        })
        |> Ash.create!()

      _project_without_members =
        Project
        |> Ash.Changeset.for_create(:create, %{
          name: "ProjectWithoutMembers",
          code: "PWOM",
          status: "active",
          active: true,
          organization_id: org_without_members.id
        })
        |> Ash.create!()

      active_member =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "member@test.com",
          name: "ActiveMember",
          age: 30,
          active: true
        })
        |> Ash.create!()

      inactive_member =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "inactive_member@test.com",
          name: "InactiveMember",
          age: 35,
          active: false
        })
        |> Ash.create!()

      # Link members to project
      UserProject
      |> Ash.Changeset.for_create(:create, %{
        user_id: active_member.id,
        project_id: project_with_members.id,
        role: "developer",
        hours_allocated: 40,
        active: true
      })
      |> Ash.create!()

      UserProject
      |> Ash.Changeset.for_create(:create, %{
        user_id: inactive_member.id,
        project_id: project_with_members.id,
        role: "consultant",
        hours_allocated: 20,
        active: false
      })
      |> Ash.create!()

      {:ok,
       org_with_members: org_with_members,
       org_without_members: org_without_members,
       project_with_members: project_with_members}
    end

    test "3-level through many-to-many: org -> projects -> members" do
      orgs =
        Organization
        |> Ash.Query.filter(exists(projects, exists(members, true)))
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(orgs, & &1.name)
      assert names == ["OrgWithMembers"]
      refute "OrgWithoutMembers" in names
    end

    test "3-level through many-to-many with filter: active members only" do
      orgs =
        Organization
        |> Ash.Query.filter(exists(projects, exists(members, active == true)))
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(orgs, & &1.name)
      assert names == ["OrgWithMembers"]
    end

    test "projects with active members" do
      projects =
        Project
        |> Ash.Query.filter(exists(members, active == true))
        |> Ash.Query.sort(name: :asc)
        |> Ash.read!()

      names = Enum.map(projects, & &1.name)
      assert names == ["ProjectWithMembers"]
    end
  end

  # ============================================================================
  # 5. Combined Feature Tests
  # ============================================================================

  describe "combined features" do
    setup do
      # Create a complete hierarchy to test all features together
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "CombinedOrg", active: true, employee_count: 50})
        |> Ash.create!()

      # Create users with varying post counts
      prolific_user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "prolific@test.com",
          name: "Prolific",
          age: 30,
          active: true,
          organization_id: org.id
        })
        |> Ash.create!()

      casual_user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "casual@test.com",
          name: "Casual",
          age: 25,
          active: true,
          organization_id: org.id
        })
        |> Ash.create!()

      # Create posts
      for i <- 1..5 do
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Prolific Post #{i}",
          published: true,
          user_id: prolific_user.id
        })
        |> Ash.create!()
      end

      Post
      |> Ash.Changeset.for_create(:create, %{
        title: "Casual Post",
        published: true,
        user_id: casual_user.id
      })
      |> Ash.create!()

      # Create tags and link them
      hot_tag = Tag |> Ash.Changeset.for_create(:create, %{name: "hot", priority: 100}) |> Ash.create!()

      [first_post | _] =
        Post
        |> Ash.Query.filter(exists(user, name == "Prolific"))
        |> Ash.Query.limit(1)
        |> Ash.read!()

      PostTag |> Ash.Changeset.for_create(:create, %{post_id: first_post.id, tag_id: hot_tag.id}) |> Ash.create!()

      {:ok, org: org, prolific_user: prolific_user, casual_user: casual_user, hot_tag: hot_tag}
    end

    test "aggregate filter + nested exists" do
      # Users with 3+ posts who are in active organizations
      users =
        User
        |> Ash.Query.filter(post_count >= 3 and exists(organization, active == true))
        |> Ash.read!()

      names = Enum.map(users, & &1.name)
      assert names == ["Prolific"]
    end

    test "nested exists + many-to-many" do
      # Organizations that have users who have posts with hot tags
      orgs =
        Organization
        |> Ash.Query.filter(
          exists(users,
            exists(posts, exists(tags, name == "hot"))
          )
        )
        |> Ash.read!()

      names = Enum.map(orgs, & &1.name)
      assert names == ["CombinedOrg"]
    end

    test "boolean coercion in nested query results" do
      # Load organization with users, verify booleans are coerced
      [org] =
        Organization
        |> Ash.Query.filter(name == "CombinedOrg")
        |> Ash.Query.load(:users)
        |> Ash.read!()

      assert org.active === true
      assert is_boolean(org.active)

      for user <- org.users do
        assert is_boolean(user.active)
        assert user.active === true
      end
    end

    test "aggregate filter + boolean filter + sort" do
      # Active users with at least 1 post, sorted by post_count desc
      users =
        User
        |> Ash.Query.filter(active == true and post_count >= 1)
        |> Ash.Query.sort(post_count: :desc)
        |> Ash.read!()

      names = Enum.map(users, & &1.name)
      assert names == ["Prolific", "Casual"]

      # Verify correct ordering
      [first, second] = users
      assert first.name == "Prolific"
      assert second.name == "Casual"
    end
  end
end
