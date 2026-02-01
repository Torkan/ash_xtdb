# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.MultitenancyTest do
  use ExUnit.Case, async: false

  alias AshXTDB.Test.PostWithTenant

  require Ash.Query

  setup do
    # Clean up the posts_with_tenant table before each test
    AshXTDB.TestRepo.query(
      "DELETE FROM posts_with_tenant WHERE posts_with_tenant.\"_id\" IS NOT NULL",
      []
    )

    :ok
  end

  # Helper to create a post with tenant set on changeset
  defp create_post!(attrs, tenant) do
    PostWithTenant
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.Changeset.set_tenant(tenant)
    |> Ash.create!()
  end

  describe "attribute-based multitenancy" do
    test "creates records with tenant attribute" do
      post = create_post!(%{title: "Org1 Post", body: "Content for org1"}, "org1")

      assert post.title == "Org1 Post"
      assert post.org_id == "org1"
    end

    test "reads only tenant's records" do
      # Create posts for different tenants
      create_post!(%{title: "Org1 Post 1", body: "Content"}, "org1")
      create_post!(%{title: "Org1 Post 2", body: "Content"}, "org1")
      create_post!(%{title: "Org2 Post", body: "Content"}, "org2")

      # Read org1's posts - should only see org1's records
      org1_posts = Ash.read!(PostWithTenant, tenant: "org1")
      assert length(org1_posts) == 2
      assert Enum.all?(org1_posts, &(&1.org_id == "org1"))

      # Read org2's posts - should only see org2's records
      org2_posts = Ash.read!(PostWithTenant, tenant: "org2")
      assert length(org2_posts) == 1
      assert hd(org2_posts).org_id == "org2"
    end

    test "updates only tenant's records" do
      # Create posts for different tenants
      org1_post = create_post!(%{title: "Org1 Post", body: "Original"}, "org1")
      create_post!(%{title: "Org2 Post", body: "Original"}, "org2")

      # Update org1's post
      updated =
        org1_post
        |> Ash.Changeset.for_update(:update, %{body: "Updated"})
        |> Ash.Changeset.set_tenant("org1")
        |> Ash.update!()

      assert updated.body == "Updated"

      # Verify org2's post is unchanged
      [org2_post] = Ash.read!(PostWithTenant, tenant: "org2")
      assert org2_post.body == "Original"
    end

    test "destroys only tenant's records" do
      # Create posts for different tenants
      org1_post = create_post!(%{title: "Org1 Post", body: "Content"}, "org1")
      create_post!(%{title: "Org2 Post", body: "Content"}, "org2")

      # Destroy org1's post
      org1_post
      |> Ash.Changeset.for_destroy(:destroy)
      |> Ash.Changeset.set_tenant("org1")
      |> Ash.destroy!()

      # Org1 should have no posts
      assert Ash.read!(PostWithTenant, tenant: "org1") == []

      # Org2 should still have its post
      assert length(Ash.read!(PostWithTenant, tenant: "org2")) == 1
    end

    test "filters work within tenant scope" do
      # Create posts for org1 with different titles
      create_post!(%{title: "Alpha Post", body: "Content"}, "org1")
      create_post!(%{title: "Beta Post", body: "Content"}, "org1")
      create_post!(%{title: "Alpha Post", body: "Content"}, "org2")

      # Filter within org1's scope
      alpha_posts =
        PostWithTenant
        |> Ash.Query.filter(title == "Alpha Post")
        |> Ash.read!(tenant: "org1")

      assert length(alpha_posts) == 1
      assert hd(alpha_posts).org_id == "org1"
    end

    test "sorting works within tenant scope" do
      # Create posts for org1 with different titles
      create_post!(%{title: "Zebra", body: "Content"}, "org1")
      create_post!(%{title: "Alpha", body: "Content"}, "org1")
      create_post!(%{title: "Beta", body: "Content"}, "org1")

      # Sort within org1's scope
      sorted_posts =
        PostWithTenant
        |> Ash.Query.sort(title: :asc)
        |> Ash.read!(tenant: "org1")

      assert Enum.map(sorted_posts, & &1.title) == ["Alpha", "Beta", "Zebra"]
    end

    test "pagination works within tenant scope" do
      # Create multiple posts for org1
      for i <- 1..5 do
        create_post!(
          %{
            title: "Post #{String.pad_leading(Integer.to_string(i), 2, "0")}",
            body: "Content"
          },
          "org1"
        )
      end

      # Create posts for org2 (should not affect org1's pagination)
      for i <- 1..3 do
        create_post!(%{title: "Org2 Post #{i}", body: "Content"}, "org2")
      end

      # Paginate org1's posts
      page =
        PostWithTenant
        |> Ash.Query.sort(title: :asc)
        |> Ash.read!(tenant: "org1", page: [limit: 2])

      assert length(page.results) == 2
      assert Enum.map(page.results, & &1.title) == ["Post 01", "Post 02"]
      assert page.more? == true
    end

    test "aggregates work within tenant scope" do
      # Create posts for different tenants
      for i <- 1..3 do
        create_post!(%{title: "Org1 Post #{i}", body: "Content"}, "org1")
      end

      for i <- 1..5 do
        create_post!(%{title: "Org2 Post #{i}", body: "Content"}, "org2")
      end

      # Count org1's posts
      org1_count = Ash.count!(PostWithTenant, tenant: "org1")
      assert org1_count == 3

      # Count org2's posts
      org2_count = Ash.count!(PostWithTenant, tenant: "org2")
      assert org2_count == 5
    end
  end
end
