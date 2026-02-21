# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.RelationshipsTest do
  use ExUnit.Case, async: false

  alias AshXTDB.Test.{Organization, Post, User}

  require Ash.Query

  setup do
    # Clean up tables before each test
    AshXTDB.TestRepo.query("DELETE FROM posts WHERE posts.\"_id\" IS NOT NULL", [])
    AshXTDB.TestRepo.query("DELETE FROM users WHERE users.\"_id\" IS NOT NULL", [])

    AshXTDB.TestRepo.query(
      "DELETE FROM organizations WHERE organizations.\"_id\" IS NOT NULL",
      []
    )

    :ok
  end

  describe "belongs_to relationship" do
    test "filters through belongs_to relationship" do
      # Create an organization
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "Acme Corp", industry: "Tech"})
        |> Ash.create!()

      # Create users in that organization
      _user1 =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "alice@acme.com",
          name: "Alice",
          organization_id: org.id
        })
        |> Ash.create!()

      _user2 =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "bob@acme.com",
          name: "Bob",
          organization_id: org.id
        })
        |> Ash.create!()

      # Create a user without organization
      _user3 =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "charlie@solo.com",
          name: "Charlie"
        })
        |> Ash.create!()

      # Filter users by organization name
      users =
        User
        |> Ash.Query.filter(organization.name == "Acme Corp")
        |> Ash.read!()

      assert length(users) == 2
      assert Enum.all?(users, &(&1.organization_id == org.id))
    end

    test "filters through belongs_to with multiple conditions" do
      # Create organizations
      tech_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TechCo", industry: "Tech"})
        |> Ash.create!()

      finance_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "FinCo", industry: "Finance"})
        |> Ash.create!()

      # Create users
      _alice =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "alice@tech.com",
          name: "Alice",
          organization_id: tech_org.id
        })
        |> Ash.create!()

      _bob =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "bob@fin.com",
          name: "Bob",
          organization_id: finance_org.id
        })
        |> Ash.create!()

      # Filter by organization industry
      tech_users =
        User
        |> Ash.Query.filter(organization.industry == "Tech")
        |> Ash.read!()

      assert length(tech_users) == 1
      assert hd(tech_users).name == "Alice"
    end
  end

  describe "has_many relationship" do
    test "filters through has_many relationship" do
      # Create a user
      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "author@blog.com",
          name: "Author"
        })
        |> Ash.create!()

      # Create posts for the user
      _post1 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "First Post",
          body: "Hello world",
          user_id: user.id
        })
        |> Ash.create!()

      _post2 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Second Post",
          body: "More content",
          user_id: user.id
        })
        |> Ash.create!()

      # Read posts and verify they belong to the user
      posts =
        Post
        |> Ash.Query.filter(user.name == "Author")
        |> Ash.read!()

      assert length(posts) == 2
      assert Enum.all?(posts, &(&1.user_id == user.id))
    end
  end

  describe "loading relationships" do
    test "loads belongs_to relationship" do
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "LoadTest Org"})
        |> Ash.create!()

      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "loader@test.com",
          name: "Loader",
          organization_id: org.id
        })
        |> Ash.create!()

      # Load the user with organization
      [loaded_user] =
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.Query.load(:organization)
        |> Ash.read!()

      assert loaded_user.organization.id == org.id
      assert loaded_user.organization.name == "LoadTest Org"
    end

    test "loads has_many relationship" do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "posts@test.com",
          name: "Poster"
        })
        |> Ash.create!()

      _post1 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Post One",
          user_id: user.id
        })
        |> Ash.create!()

      _post2 =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Post Two",
          user_id: user.id
        })
        |> Ash.create!()

      # Load the user with posts
      [loaded_user] =
        User
        |> Ash.Query.filter(id == ^user.id)
        |> Ash.Query.load(:posts)
        |> Ash.read!()

      assert length(loaded_user.posts) == 2
      assert Enum.any?(loaded_user.posts, &(&1.title == "Post One"))
      assert Enum.any?(loaded_user.posts, &(&1.title == "Post Two"))
    end
  end
end
