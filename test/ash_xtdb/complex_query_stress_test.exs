# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.ComplexQueryStressTest do
  @moduledoc """
  Stress tests for complex SQL generation.

  These tests combine multiple features in unrealistically complex ways
  to push the SQL generation to its limits and verify it handles
  edge cases correctly.
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Test.{Organization, Post, User}

  require Ash.Query

  @moduletag :integration
  @moduletag :stress

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

  describe "deeply nested boolean expressions" do
    setup do
      # Create a rich dataset for testing
      tech_org = create_org("TechCorp", "Technology")
      finance_org = create_org("FinanceInc", "Finance")
      retail_org = create_org("RetailMart", "Retail")

      # Users with varying ages and statuses
      alice = create_user("alice@tech.com", "Alice", 25, true, tech_org.id)
      bob = create_user("bob@tech.com", "Bob", 35, false, tech_org.id)
      carol = create_user("carol@finance.com", "Carol", 45, true, finance_org.id)
      david = create_user("david@finance.com", "David", 17, true, finance_org.id)
      eve = create_user("eve@retail.com", "Eve", 55, false, retail_org.id)

      # Posts for users
      create_post("Tech Post 1", "Body about technology", alice.id)
      create_post("Tech Post 2", nil, alice.id)
      create_post("Finance Post", "Body about finance", carol.id)

      {:ok,
       %{
         tech_org: tech_org,
         finance_org: finance_org,
         retail_org: retail_org,
         alice: alice,
         bob: bob,
         carol: carol,
         david: david,
         eve: eve
       }}
    end

    test "complex AND/OR/NOT nesting with 4+ levels", ctx do
      # Query: Find users who are:
      # ((active AND adult) OR (in tech org)) AND NOT (age > 50)
      # This creates deeply nested boolean logic
      results =
        User
        |> Ash.Query.filter(
          ((active == true and age >= 18) or organization_id == ^ctx.tech_org.id) and
            not (age > 50)
        )
        |> Ash.read!()

      # Alice: active=true, age=25 (adult), tech org -> matches
      # Bob: active=false, age=35, tech org -> matches (tech org clause)
      # Carol: active=true, age=45 (adult) -> matches
      # David: active=true, age=17 (not adult), finance org -> no match
      # Eve: active=false, age=55 -> excluded by NOT age > 50
      assert length(results) == 3
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob", "Carol"]
    end

    test "single negation with complex inner expression", _ctx do
      # NOT (age < 30 AND active)
      # This means: age >= 30 OR not active
      results =
        User
        |> Ash.Query.filter(not (age < 30 and active == true))
        |> Ash.read!()

      # NOT (age < 30 AND active) means: age >= 30 OR not active
      # Alice: age=25, active=true -> age < 30 AND active -> negated = excluded
      # Bob: age=35, active=false -> not (age < 30 AND active) -> included
      # Carol: age=45, active=true -> not (age < 30 AND active) -> included
      # David: age=17, active=true -> age < 30 AND active -> negated = excluded
      # Eve: age=55, active=false -> not (age < 30 AND active) -> included
      assert length(results) == 3
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["Bob", "Carol", "Eve"]
    end

    test "combining 6+ different operators in single query", ctx do
      # Combine: ==, !=, <, >, <=, >=, in, is_nil, contains, and, or, not
      results =
        User
        |> Ash.Query.filter(
          age >= 18 and age <= 50 and
            (active == true or organization_id == ^ctx.tech_org.id) and
            not is_nil(name) and
            name != "David" and
            contains(email, "@")
        )
        |> Ash.read!()

      # Alice: age 25 (18-50), active=true, has name, not David, has @ -> matches
      # Bob: age 35 (18-50), tech org, has name, not David, has @ -> matches
      # Carol: age 45 (18-50), active=true, has name, not David, has @ -> matches
      # David: excluded by name != "David"
      # Eve: age 55, excluded by age <= 50
      assert length(results) == 3
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob", "Carol"]
    end
  end

  describe "calculation filtering with complex expressions" do
    setup do
      org = create_org("TestOrg", "Technology")

      # Create users with specific ages for age_bracket calculation testing
      minor = create_user("minor@test.com", "Minor", 15, true, org.id)
      young_adult = create_user("young@test.com", "YoungAdult", 25, true, org.id)
      middle = create_user("middle@test.com", "MiddleAge", 45, false, org.id)
      senior = create_user("senior@test.com", "Senior", 65, true, org.id)

      {:ok, %{org: org, minor: minor, young_adult: young_adult, middle: middle, senior: senior}}
    end

    test "filter by cond-based calculation with multiple brackets", _ctx do
      # Filter by age_bracket which uses a complex cond expression
      results =
        User
        |> Ash.Query.filter(
          (age_bracket == "Young Adult" or age_bracket == "Middle Age") and
            is_adult == true
        )
        |> Ash.read!()

      # YoungAdult: bracket="Young Adult", is_adult=true -> matches
      # MiddleAge: bracket="Middle Age", is_adult=true -> matches
      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["MiddleAge", "YoungAdult"]
    end

    test "filter combining calculation with relationship traversal", _ctx do
      # Filter users where their organization is_tech AND user is_adult
      results =
        User
        |> Ash.Query.filter(organization.is_tech == true and is_adult == true)
        |> Ash.read!()

      # Only YoungAdult and MiddleAge are adults in tech org
      # But MiddleAge is not active (doesn't matter for this query)
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert "YoungAdult" in names
    end

    test "filter by string calculation with comparison operators", _ctx do
      # name_lower produces lowercase name, filter with string comparison
      results =
        User
        |> Ash.Query.filter(name_lower >= "m" and name_lower < "z")
        |> Ash.read!()

      # minor, middleage, senior, youngadult
      # >= "m": middleage, minor, senior, youngadult
      # < "z": all of them
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert length(names) >= 2
    end
  end

  describe "exists with complex inner filters" do
    setup do
      org = create_org("BlogOrg", "Media")

      prolific = create_user("prolific@blog.com", "Prolific", 30, true, org.id)
      moderate = create_user("moderate@blog.com", "Moderate", 25, true, org.id)
      lurker = create_user("lurker@blog.com", "Lurker", 20, true, org.id)

      # Prolific has many posts
      create_post("Tech Article", "Long technical content here", prolific.id)
      create_post("Short Note", nil, prolific.id)
      create_post("Another Post", "More content", prolific.id)

      # Moderate has one post with body
      create_post("Single Post", "Has a body", moderate.id)

      # Lurker has no posts

      {:ok, %{org: org, prolific: prolific, moderate: moderate, lurker: lurker}}
    end

    test "exists with calculation filter inside", _ctx do
      # Find users who have posts where has_body calculation is true
      results =
        User
        |> Ash.Query.filter(exists(posts, has_body == true))
        |> Ash.read!()

      # Prolific has posts with body
      # Moderate has post with body
      # Lurker has no posts
      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["Moderate", "Prolific"]
    end

    test "not exists combined with other filters", _ctx do
      # Find active users who don't have any posts
      results =
        User
        |> Ash.Query.filter(active == true and not exists(posts, true))
        |> Ash.read!()

      # Only Lurker has no posts and is active
      assert length(results) == 1
      assert hd(results).name == "Lurker"
    end

    test "exists with complex boolean inside", _ctx do
      # Find users with posts that have body AND title containing "Article"
      results =
        User
        |> Ash.Query.filter(exists(posts, not is_nil(body) and contains(title, "Article")))
        |> Ash.read!()

      # Only Prolific has "Tech Article" with body
      assert length(results) == 1
      assert hd(results).name == "Prolific"
    end

    test "multiple exists conditions combined", _ctx do
      # Find users who have BOTH:
      # - at least one post with body
      # - at least one post without body (nil)
      results =
        User
        |> Ash.Query.filter(exists(posts, not is_nil(body)) and exists(posts, is_nil(body)))
        |> Ash.read!()

      # Only Prolific has both types
      assert length(results) == 1
      assert hd(results).name == "Prolific"
    end
  end

  describe "combining date/time functions with other expressions" do
    alias AshXTDB.Test.ExpressionTestResource

    setup do
      # Clean expression test table
      AshXTDB.TestRepo.query(
        "DELETE FROM expression_test WHERE expression_test.\"_id\" IS NOT NULL",
        []
      )

      # Create records at different times
      old_record =
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{
          name: "old",
          value: 100.5,
          count: 10,
          created_at: DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)
        })
        |> Ash.create!()

      recent_record =
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{
          name: "recent",
          value: 50.25,
          count: 5,
          created_at: DateTime.add(DateTime.utc_now(), -1 * 3600, :second)
        })
        |> Ash.create!()

      future_record =
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{
          name: "future",
          value: 25.0,
          count: 2,
          created_at: DateTime.add(DateTime.utc_now(), 2 * 24 * 3600, :second)
        })
        |> Ash.create!()

      {:ok, %{old: old_record, recent: recent_record, future: future_record}}
    end

    test "ago() combined with math calculations", _ctx do
      # Find records created more than 1 day ago with value > 50
      results =
        ExpressionTestResource
        |> Ash.Query.filter(created_at < ago(1, :day) and value > 50)
        |> Ash.Query.load(:rounded_value)
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).name == "old"
      assert hd(results).rounded_value == 101.0
    end

    test "date comparison with calculation sort", _ctx do
      # Find records created before now, sorted by rounded value
      results =
        ExpressionTestResource
        |> Ash.Query.filter(created_at < now())
        |> Ash.Query.load(:rounded_value)
        |> Ash.Query.sort(rounded_value: :asc)
        |> Ash.read!()

      # old (101) and recent (50) should be returned, sorted by rounded value
      assert length(results) == 2
      names = Enum.map(results, & &1.name)
      assert names == ["recent", "old"]
    end

    test "from_now() with multiple conditions", _ctx do
      # Find records created between now and 3 days from now
      results =
        ExpressionTestResource
        |> Ash.Query.filter(created_at > now() and created_at < from_now(3, :day))
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).name == "future"
    end
  end

  describe "fragment with complex expressions" do
    alias AshXTDB.Test.ExpressionTestResource

    setup do
      AshXTDB.TestRepo.query(
        "DELETE FROM expression_test WHERE expression_test.\"_id\" IS NOT NULL",
        []
      )

      for {name, value, count} <- [
            {"alpha", 10.5, 3},
            {"beta", 20.0, 6},
            {"gamma", 30.75, 9}
          ] do
        ExpressionTestResource
        |> Ash.Changeset.for_create(:create, %{name: name, value: value, count: count})
        |> Ash.create!()
      end

      :ok
    end

    test "fragment calculation combined with filter and sort" do
      # Load name_upper (UPPER fragment) and double_count (arithmetic fragment)
      # Filter by count, sort by rounded value
      results =
        ExpressionTestResource
        |> Ash.Query.filter(count > 4)
        |> Ash.Query.load([:name_upper, :double_count, :rounded_value])
        |> Ash.Query.sort(rounded_value: :asc)
        |> Ash.read!()

      assert length(results) == 2

      # beta (20.0) and gamma (30.75) have count > 4
      first = hd(results)
      assert first.name == "beta"
      assert first.name_upper == "BETA"
      assert first.double_count == 12
      assert first.rounded_value == 20.0

      second = Enum.at(results, 1)
      assert second.name == "gamma"
      assert second.name_upper == "GAMMA"
      assert second.double_count == 18
      assert second.rounded_value == 31.0
    end
  end

  describe "deeply nested relationship filters" do
    setup do
      tech_org = create_org("TechCorp", "Technology")

      alice = create_user("alice@tech.com", "Alice", 30, true, tech_org.id)
      bob = create_user("bob@tech.com", "Bob", 25, true, tech_org.id)

      # Alice's posts
      alice_post1 = create_post("Alice Tech Post", "Technical content", alice.id)
      alice_post2 = create_post("Alice General", "General stuff", alice.id)

      # Bob's posts
      bob_post = create_post("Bob's Article", "Bob writes here", bob.id)

      {:ok,
       %{
         tech_org: tech_org,
         alice: alice,
         bob: bob,
         alice_post1: alice_post1,
         alice_post2: alice_post2,
         bob_post: bob_post
       }}
    end

    test "filter organization by user calculations", _ctx do
      # Find organizations where at least one user is an adult
      results =
        Organization
        |> Ash.Query.filter(exists(users, is_adult == true))
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).name == "TechCorp"
    end

    test "filter users through organization calculation", _ctx do
      # Find users in tech organizations
      results =
        User
        |> Ash.Query.filter(organization.is_tech == true)
        |> Ash.read!()

      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob"]
    end

    test "combining local and relationship calculations", _ctx do
      # Find adult users in tech orgs who have posts with body
      results =
        User
        |> Ash.Query.filter(
          is_adult == true and
            organization.is_tech == true and
            exists(posts, has_body == true)
        )
        |> Ash.read!()

      # Both Alice and Bob are adults in tech, both have posts with body
      assert length(results) == 2
    end
  end

  describe "edge cases and boundary conditions" do
    test "filter with single-element IN list" do
      create_user("lonely@test.com", "Lonely", 30, true, nil)
      create_user("other@test.com", "Other", 25, true, nil)

      # Single element IN list
      results =
        User
        |> Ash.Query.filter(name in ["Lonely"])
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).name == "Lonely"
    end

    test "multiple is_nil checks combined" do
      create_user("both_nil@test.com", nil, nil, true, nil)
      create_user("only_name@test.com", "HasName", nil, true, nil)
      create_user("only_age@test.com", nil, 30, true, nil)
      create_user("has_both@test.com", "HasBoth", 25, true, nil)

      # Find users with BOTH name and age as nil
      results =
        User
        |> Ash.Query.filter(is_nil(name) and is_nil(age))
        |> Ash.read!()

      assert length(results) == 1
      assert hd(results).email == "both_nil@test.com"
    end

    test "deeply nested OR conditions" do
      create_user("a@test.com", "A", 10, true, nil)
      create_user("b@test.com", "B", 20, false, nil)
      create_user("c@test.com", "C", 30, true, nil)
      create_user("d@test.com", "D", 40, false, nil)
      create_user("e@test.com", "E", 50, true, nil)

      # (age == 10 OR age == 20 OR age == 30 OR age == 40 OR age == 50) AND active
      results =
        User
        |> Ash.Query.filter(
          (age == 10 or age == 20 or age == 30 or age == 40 or age == 50) and
            active == true
        )
        |> Ash.read!()

      # A (10, active), C (30, active), E (50, active)
      assert length(results) == 3
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["A", "C", "E"]
    end

    test "filter with all comparison operators on same field" do
      for age <- [15, 20, 25, 30, 35, 40] do
        create_user("age#{age}@test.com", "Age#{age}", age, true, nil)
      end

      # age > 15 AND age >= 20 AND age < 40 AND age <= 35 AND age != 30
      results =
        User
        |> Ash.Query.filter(age > 15 and age >= 20 and age < 40 and age <= 35 and age != 30)
        |> Ash.read!()

      # Valid: 20, 25, 35 (30 excluded by !=, 15 by >, 40 by <)
      ages = Enum.map(results, & &1.age) |> Enum.sort()
      assert ages == [20, 25, 35]
    end
  end

  describe "ultimate stress test - combining everything" do
    setup do
      # Create a rich interconnected dataset
      tech = create_org("TechGiant", "Technology")
      finance = create_org("FinanceHouse", "Finance")

      # Tech users
      senior_dev = create_user("senior@tech.com", "SeniorDev", 45, true, tech.id)
      junior_dev = create_user("junior@tech.com", "JuniorDev", 23, true, tech.id)
      inactive_dev = create_user("inactive@tech.com", "InactiveDev", 35, false, tech.id)

      # Finance users
      analyst = create_user("analyst@finance.com", "Analyst", 30, true, finance.id)
      intern = create_user("intern@finance.com", "Intern", 19, true, finance.id)

      # Posts with various states
      create_post("Senior's Tech Article", "Deep technical dive", senior_dev.id)
      create_post("Senior's Quick Note", nil, senior_dev.id)
      create_post("Junior's First Post", "Learning journey", junior_dev.id)
      create_post("Analyst Report", "Financial analysis", analyst.id)

      {:ok,
       %{
         tech: tech,
         finance: finance,
         senior_dev: senior_dev,
         junior_dev: junior_dev,
         inactive_dev: inactive_dev,
         analyst: analyst,
         intern: intern
       }}
    end

    test "monster query combining 10+ features", _ctx do
      # The ultimate test: combine as many features as possible
      # Find users who:
      # 1. Are adults (is_adult calculation)
      # 2. In tech organizations (organization.is_tech calculation)
      # 3. Are active
      # 4. Have posts with body (exists with calculation)
      # 5. Name doesn't contain "Inactive"
      # 6. Age between 20 and 50
      # 7. Sorted by name_lower calculation

      results =
        User
        |> Ash.Query.filter(
          is_adult == true and
            organization.is_tech == true and
            active == true and
            exists(posts, has_body == true) and
            not contains(name, "Inactive") and
            age >= 20 and
            age <= 50
        )
        |> Ash.Query.load([:name_lower, :is_adult, :age_bracket])
        |> Ash.Query.sort(name_lower: :asc)
        |> Ash.read!()

      # SeniorDev: adult, tech, active, has post with body, age 45 -> MATCH
      # JuniorDev: adult, tech, active, has post with body, age 23 -> MATCH
      # InactiveDev: adult, tech, NOT active -> excluded
      # Analyst: adult, NOT tech -> excluded
      # Intern: NOT adult -> excluded

      assert length(results) == 2

      first = hd(results)
      assert first.name == "JuniorDev"
      assert first.name_lower == "juniordev"
      assert first.is_adult == true
      assert first.age_bracket == "Young Adult"

      second = Enum.at(results, 1)
      assert second.name == "SeniorDev"
      assert second.age_bracket == "Middle Age"
    end

    test "monster query with OR branches containing calculations", _ctx do
      # Find users who are either:
      # - Young Adults (age_bracket) in tech with posts
      # - OR Senior/Middle Age and active
      results =
        User
        |> Ash.Query.filter(
          (age_bracket == "Young Adult" and organization.is_tech == true and
             exists(posts, true)) or
            ((age_bracket == "Senior" or age_bracket == "Middle Age") and active == true)
        )
        |> Ash.read!()

      # JuniorDev: Young Adult, tech, has posts -> MATCH (first branch)
      # SeniorDev: Middle Age, active -> MATCH (second branch)
      # InactiveDev: Middle Age, NOT active -> excluded
      # Analyst: Young Adult, NOT tech -> excluded from first, not senior/middle
      # Intern: Minor, excluded

      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert "JuniorDev" in names
      assert "SeniorDev" in names
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
