# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.AdvancedCalculationFilterTest do
  @moduledoc """
  Tests for advanced filtering scenarios involving calculations,
  nested relationship paths, and complex expressions.

  These tests stress-test the AshXTDB implementation to ensure it can
  handle arbitrarily nested references to calculations when filtering queries.
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Test.{Organization, User, Post}

  require Ash.Query

  setup do
    # Clean up all tables before each test
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

  describe "filtering by local calculations" do
    test "filter by simple string calculation (name_lower)" do
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "Acme Corp", industry: "Technology"})
        |> Ash.create!()

      Organization
      |> Ash.Changeset.for_create(:create, %{name: "Other Inc", industry: "Finance"})
      |> Ash.create!()

      # Filter by calculation - string_downcase should produce "acme corp"
      results =
        Organization
        |> Ash.Query.filter(name_lower == "acme corp")
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == org.id
    end

    test "filter by boolean calculation" do
      Organization
      |> Ash.Changeset.for_create(:create, %{name: "TechCo", industry: "Technology"})
      |> Ash.create!()

      Organization
      |> Ash.Changeset.for_create(:create, %{name: "FinCo", industry: "Finance"})
      |> Ash.create!()

      # Filter by boolean calculation
      results =
        Organization
        |> Ash.Query.filter(is_tech == true)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).name == "TechCo"
    end

    test "filter by calculation with conditional logic" do
      org1 =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "No Industry"})
        |> Ash.create!()

      Organization
      |> Ash.Changeset.for_create(:create, %{name: "Has Industry", industry: "Retail"})
      |> Ash.create!()

      # Filter by calculation that uses conditional
      results =
        Organization
        |> Ash.Query.filter(industry_or_default == "Unknown")
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == org1.id
    end

    test "filter by integer calculation (string_length)" do
      org_short =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "ABC"})
        |> Ash.create!()

      Organization
      |> Ash.Changeset.for_create(:create, %{name: "A Very Long Organization Name"})
      |> Ash.create!()

      # Filter by string_length calculation
      results =
        Organization
        |> Ash.Query.filter(name_length < 10)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == org_short.id
    end

    test "filter users by age bracket calculation" do
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TestOrg"})
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "teen@test.com",
        name: "Teen",
        age: 16,
        organization_id: org.id
      })
      |> Ash.create!()

      adult =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "adult@test.com",
          name: "Adult",
          age: 25,
          organization_id: org.id
        })
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "senior@test.com",
        name: "Senior",
        age: 65,
        organization_id: org.id
      })
      |> Ash.create!()

      # Filter by complex conditional calculation
      results =
        User
        |> Ash.Query.filter(age_bracket == "Young Adult")
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == adult.id
    end

    test "filter users by is_adult boolean calculation" do
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TestOrg"})
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "teen@test.com",
        name: "Teen",
        age: 16,
        organization_id: org.id
      })
      |> Ash.create!()

      adult =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "adult@test.com",
          name: "Adult",
          age: 25,
          organization_id: org.id
        })
        |> Ash.create!()

      results =
        User
        |> Ash.Query.filter(is_adult == true)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == adult.id
    end
  end

  describe "filtering by related record calculations" do
    test "filter users by organization calculation (is_tech)" do
      tech_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TechOrg", industry: "Technology"})
        |> Ash.create!()

      fin_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "FinOrg", industry: "Finance"})
        |> Ash.create!()

      tech_user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "tech@test.com",
          name: "Tech User",
          organization_id: tech_org.id
        })
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "fin@test.com",
        name: "Fin User",
        organization_id: fin_org.id
      })
      |> Ash.create!()

      # Filter users by organization's calculation
      results =
        User
        |> Ash.Query.filter(organization.is_tech == true)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == tech_user.id
    end

    test "filter users by organization's string calculation" do
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "Acme Corp"})
        |> Ash.create!()

      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "acme@test.com",
          name: "Acme User",
          organization_id: org.id
        })
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "noacme@test.com",
        name: "NoOrg User"
      })
      |> Ash.create!()

      # Filter users by organization's name_lower calculation
      results =
        User
        |> Ash.Query.filter(organization.name_lower == "acme corp")
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == user.id
    end

    test "filter posts by user's calculation" do
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TestOrg"})
        |> Ash.create!()

      adult_user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "adult@test.com",
          name: "Adult",
          age: 25,
          organization_id: org.id
        })
        |> Ash.create!()

      teen_user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "teen@test.com",
          name: "Teen",
          age: 16,
          organization_id: org.id
        })
        |> Ash.create!()

      adult_post =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Adult Post",
          body: "Content",
          user_id: adult_user.id
        })
        |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{
        title: "Teen Post",
        body: "Content",
        user_id: teen_user.id
      })
      |> Ash.create!()

      # Filter posts by user's is_adult calculation
      results =
        Post
        |> Ash.Query.filter(user.is_adult == true)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == adult_post.id
    end
  end

  describe "deeply nested relationship filtering" do
    test "filter posts by user's organization's calculation (2 levels deep)" do
      tech_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TechOrg", industry: "Technology"})
        |> Ash.create!()

      fin_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "FinOrg", industry: "Finance"})
        |> Ash.create!()

      tech_user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "tech@test.com",
          name: "Tech User",
          organization_id: tech_org.id
        })
        |> Ash.create!()

      fin_user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "fin@test.com",
          name: "Fin User",
          organization_id: fin_org.id
        })
        |> Ash.create!()

      tech_post =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Tech Post",
          body: "Tech Content",
          user_id: tech_user.id
        })
        |> Ash.create!()

      Post
      |> Ash.Changeset.for_create(:create, %{
        title: "Fin Post",
        body: "Fin Content",
        user_id: fin_user.id
      })
      |> Ash.create!()

      # Filter posts by user's organization's is_tech calculation (2 levels deep)
      results =
        Post
        |> Ash.Query.filter(user.organization.is_tech == true)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == tech_post.id
    end

    test "filter posts by user's organization's name_lower" do
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "Acme Corp"})
        |> Ash.create!()

      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "acme@test.com",
          name: "User",
          organization_id: org.id
        })
        |> Ash.create!()

      post =
        Post
        |> Ash.Changeset.for_create(:create, %{
          title: "Acme Post",
          body: "Content",
          user_id: user.id
        })
        |> Ash.create!()

      # Filter posts by deeply nested calculation
      results =
        Post
        |> Ash.Query.filter(user.organization.name_lower == "acme corp")
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == post.id
    end
  end

  describe "combining calculations and attributes in filters" do
    test "filter by calculation AND attribute" do
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TestOrg"})
        |> Ash.create!()

      adult_active =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "adult_active@test.com",
          name: "Adult Active",
          age: 30,
          active: true,
          organization_id: org.id
        })
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "adult_inactive@test.com",
        name: "Adult Inactive",
        age: 30,
        active: false,
        organization_id: org.id
      })
      |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "teen_active@test.com",
        name: "Teen Active",
        age: 16,
        active: true,
        organization_id: org.id
      })
      |> Ash.create!()

      # Combine calculation and attribute filter
      results =
        User
        |> Ash.Query.filter(is_adult == true and active == true)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == adult_active.id
    end

    test "filter by nested calculation AND local calculation" do
      tech_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TechOrg", industry: "Technology"})
        |> Ash.create!()

      fin_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "FinOrg", industry: "Finance"})
        |> Ash.create!()

      tech_adult =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "tech_adult@test.com",
          name: "Tech Adult",
          age: 30,
          organization_id: tech_org.id
        })
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "tech_teen@test.com",
        name: "Tech Teen",
        age: 16,
        organization_id: tech_org.id
      })
      |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "fin_adult@test.com",
        name: "Fin Adult",
        age: 30,
        organization_id: fin_org.id
      })
      |> Ash.create!()

      # Combine nested calculation and local calculation
      results =
        User
        |> Ash.Query.filter(organization.is_tech == true and is_adult == true)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == tech_adult.id
    end
  end

  describe "OR conditions with calculations" do
    test "filter by calculation OR attribute" do
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TestOrg"})
        |> Ash.create!()

      adult =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "adult@test.com",
          name: "Adult",
          age: 30,
          active: false,
          organization_id: org.id
        })
        |> Ash.create!()

      active_teen =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "teen@test.com",
          name: "Teen",
          age: 16,
          active: true,
          organization_id: org.id
        })
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "inactive_teen@test.com",
        name: "Inactive Teen",
        age: 16,
        active: false,
        organization_id: org.id
      })
      |> Ash.create!()

      # Filter by calculation OR attribute
      results =
        User
        |> Ash.Query.filter(is_adult == true or active == true)
        |> Ash.Query.sort(:email)
        |> Ash.read!()

      assert length(results) == 2
      result_ids = Enum.map(results, & &1.id)
      assert adult.id in result_ids
      assert active_teen.id in result_ids
    end
  end

  describe "filtering with NOT on calculations" do
    test "filter by NOT calculation" do
      Organization
      |> Ash.Changeset.for_create(:create, %{name: "TechOrg", industry: "Technology"})
      |> Ash.create!()

      fin_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "FinOrg", industry: "Finance"})
        |> Ash.create!()

      # Filter for non-tech orgs
      results =
        Organization
        |> Ash.Query.filter(not is_tech)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == fin_org.id
    end

    test "filter by NOT nested calculation" do
      tech_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TechOrg", industry: "Technology"})
        |> Ash.create!()

      fin_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "FinOrg", industry: "Finance"})
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "tech@test.com",
        name: "Tech User",
        organization_id: tech_org.id
      })
      |> Ash.create!()

      fin_user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "fin@test.com",
          name: "Fin User",
          organization_id: fin_org.id
        })
        |> Ash.create!()

      # Filter for users in non-tech orgs
      results =
        User
        |> Ash.Query.filter(not organization.is_tech)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == fin_user.id
    end
  end

  describe "loading and filtering calculations together" do
    test "load a calculation and filter by a different calculation" do
      Organization
      |> Ash.Changeset.for_create(:create, %{name: "TechOrg", industry: "Technology"})
      |> Ash.create!()

      Organization
      |> Ash.Changeset.for_create(:create, %{name: "FinOrg", industry: "Finance"})
      |> Ash.create!()

      # Load name_lower while filtering by is_tech
      results =
        Organization
        |> Ash.Query.filter(is_tech == true)
        |> Ash.Query.load(:name_lower)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).name_lower == "techorg"
    end

    test "load nested relationship with calculations and filter by calculation" do
      tech_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TechOrg", industry: "Technology"})
        |> Ash.create!()

      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "tech@test.com",
          name: "Tech User",
          age: 25,
          organization_id: tech_org.id
        })
        |> Ash.create!()

      # Load organization while filtering by user's is_adult calculation
      results =
        User
        |> Ash.Query.filter(is_adult == true)
        |> Ash.Query.load(:organization)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == user.id
      assert hd(results).organization.name == "TechOrg"
    end
  end

  describe "SQL generation for nested conditionals" do
    test "extract_cases pattern produces flat CASE statements (SQL inspection)" do
      # This test directly verifies the SQL generation produces flat CASE statements
      # Build a query with a nested cond calculation and inspect the generated SQL
      query =
        User
        |> Ash.Query.filter(age_bracket == "Young Adult")
        |> Ash.Query.data_layer_query()

      # Get the generated WHERE clause
      {:ok, _data_layer_query} = query

      # The query should contain the generated SQL with JOIN/WHERE info
      # The WHERE clause should have a flat CASE with multiple WHEN clauses
      # NOT nested CASE statements like: CASE WHEN ... ELSE CASE WHEN ... END END

      # We can inspect the filter's SQL generation directly
      filter = Ash.Query.filter(User, age_bracket == "Young Adult") |> Map.get(:filter)
      table = AshXTDB.DataLayer.Info.table!(User)
      {where_clause, _params, _joins} = AshXTDB.SQL.Filter.to_sql(filter, User, table)

      # The WHERE clause should contain "CASE WHEN" pattern
      assert where_clause =~ "CASE WHEN"

      # It should have multiple WHEN clauses (for age < 18, age < 30, age < 50)
      # but NOT nested CASE statements
      when_count = length(Regex.scan(~r/WHEN/, where_clause))

      assert when_count >= 3,
             "Expected at least 3 WHEN clauses for age_bracket cond, got #{when_count}"

      # Verify it's flat - should have only one CASE and one END
      case_count = length(Regex.scan(~r/\bCASE\b/, where_clause))
      end_count = length(Regex.scan(~r/\bEND\b/, where_clause))
      assert case_count == end_count, "Mismatched CASE/END - expected flat structure"

      # Should NOT have nested pattern "ELSE CASE"
      refute where_clause =~ "ELSE CASE", "Found nested CASE - extract_cases not working"
    end

    test "nested cond generates flat CASE statement (extract_cases pattern)" do
      # This test verifies that the extract_cases pattern from ash_sql is working
      # correctly - nested if/else chains should produce a single CASE statement
      # with multiple WHEN clauses rather than nested CASE statements

      # Build a filter using the age_bracket calculation which uses cond
      # cond do
      #   age < 18 -> "Minor"
      #   age < 30 -> "Young Adult"
      #   age < 50 -> "Middle Age"
      #   true -> "Senior"
      # end

      # Create an org and users
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TestOrg"})
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "minor@test.com",
        name: "Minor",
        age: 15,
        organization_id: org.id
      })
      |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "young@test.com",
        name: "Young Adult",
        age: 25,
        organization_id: org.id
      })
      |> Ash.create!()

      middle =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "middle@test.com",
          name: "Middle Age",
          age: 45,
          organization_id: org.id
        })
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "senior@test.com",
        name: "Senior",
        age: 65,
        organization_id: org.id
      })
      |> Ash.create!()

      # Filter by the middle age bracket - this exercises the extract_cases pattern
      # If extract_cases wasn't working, this would likely fail or produce incorrect SQL
      results =
        User
        |> Ash.Query.filter(age_bracket == "Middle Age")
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == middle.id
      assert hd(results).age == 45
    end

    test "filter by multiple age brackets using OR" do
      org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "TestOrg"})
        |> Ash.create!()

      minor =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "minor@test.com",
          name: "Minor",
          age: 15,
          organization_id: org.id
        })
        |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "young@test.com",
        name: "Young Adult",
        age: 25,
        organization_id: org.id
      })
      |> Ash.create!()

      User
      |> Ash.Changeset.for_create(:create, %{
        email: "middle@test.com",
        name: "Middle Age",
        age: 45,
        organization_id: org.id
      })
      |> Ash.create!()

      senior =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "senior@test.com",
          name: "Senior",
          age: 65,
          organization_id: org.id
        })
        |> Ash.create!()

      # Filter for minors OR seniors - both extreme age brackets
      results =
        User
        |> Ash.Query.filter(age_bracket == "Minor" or age_bracket == "Senior")
        |> Ash.Query.sort(:age)
        |> Ash.read!()

      assert length(results) == 2
      result_ids = Enum.map(results, & &1.id)
      assert minor.id in result_ids
      assert senior.id in result_ids
    end
  end

  describe "comparison operators with calculations" do
    test "filter by calculation greater than value" do
      Organization
      |> Ash.Changeset.for_create(:create, %{name: "Short"})
      |> Ash.create!()

      long_org =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "A Much Longer Organization Name"})
        |> Ash.create!()

      results =
        Organization
        |> Ash.Query.filter(name_length > 20)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).id == long_org.id
    end

    test "filter by calculation less than or equal" do
      org1 =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "ABC"})
        |> Ash.create!()

      org2 =
        Organization
        |> Ash.Changeset.for_create(:create, %{name: "ABCDE"})
        |> Ash.create!()

      Organization
      |> Ash.Changeset.for_create(:create, %{name: "A Very Long Name"})
      |> Ash.create!()

      results =
        Organization
        |> Ash.Query.filter(name_length <= 5)
        |> Ash.Query.sort(:name)
        |> Ash.read!()

      assert length(results) == 2
      result_ids = Enum.map(results, & &1.id)
      assert org1.id in result_ids
      assert org2.id in result_ids
    end
  end
end
