# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.TypesTest do
  @moduledoc """
  Tests for custom XTDB types: Duration, Interval, Period, and URI.
  Includes both unit tests for type casting and integration tests for SQL execution.
  """
  use ExUnit.Case, async: false

  alias AshXTDB.Types.Duration
  alias AshXTDB.Types.Interval
  alias AshXTDB.Types.Period
  alias AshXTDB.Types.URI, as: URIType
  alias AshXTDB.Query

  @moduletag :integration

  # ============================================================================
  # Duration Type Tests
  # ============================================================================

  describe "Duration type casting" do
    test "casts valid ISO 8601 duration strings" do
      assert {:ok, "P1Y"} = Duration.cast_input("P1Y", [])
      assert {:ok, "P1M"} = Duration.cast_input("P1M", [])
      assert {:ok, "P1D"} = Duration.cast_input("P1D", [])
      assert {:ok, "PT1H"} = Duration.cast_input("PT1H", [])
      assert {:ok, "PT1M"} = Duration.cast_input("PT1M", [])
      assert {:ok, "PT1S"} = Duration.cast_input("PT1S", [])
      assert {:ok, "P1Y2M3DT4H5M6S"} = Duration.cast_input("P1Y2M3DT4H5M6S", [])
    end

    test "rejects invalid duration strings" do
      assert {:error, _} = Duration.cast_input("invalid", [])
      assert {:error, _} = Duration.cast_input("P", [])
      assert {:error, _} = Duration.cast_input("PT", [])
      assert {:error, _} = Duration.cast_input("1Y", [])
    end

    test "handles nil" do
      assert {:ok, nil} = Duration.cast_input(nil, [])
    end

    test "validates duration format" do
      assert Duration.valid_duration?("P1Y") == true
      assert Duration.valid_duration?("P1Y2M3D") == true
      assert Duration.valid_duration?("PT1H30M") == true
      assert Duration.valid_duration?("P1Y2M3DT4H5M6S") == true
      assert Duration.valid_duration?("P") == false
      assert Duration.valid_duration?("invalid") == false
    end

    test "parses duration components" do
      {:ok, result} = Duration.parse("P1Y2M3DT4H5M6S")
      assert result.years == 1
      assert result.months == 2
      assert result.days == 3
      assert result.hours == 4
      assert result.minutes == 5
      assert result.seconds == 6.0

      {:ok, result2} = Duration.parse("PT1H30M")
      assert result2.years == 0
      assert result2.months == 0
      assert result2.days == 0
      assert result2.hours == 1
      assert result2.minutes == 30
      assert result2.seconds == 0
    end

    test "builds duration from components" do
      assert "P1Y2M3DT4H5M6S" ==
               Duration.build(%{years: 1, months: 2, days: 3, hours: 4, minutes: 5, seconds: 6})

      assert "PT1H30M" == Duration.build(%{hours: 1, minutes: 30})
      assert "P0D" == Duration.build(%{})
    end

    test "dumps to native format" do
      assert {:ok, "P1Y"} = Duration.dump_to_native("P1Y", [])
      assert {:ok, nil} = Duration.dump_to_native(nil, [])
    end
  end

  describe "Duration SQL execution" do
    test "executes DURATION literal in SQL" do
      # XTDB only supports time-based durations (PT format), not date-based (P1Y2M3D)
      sql = "SELECT DURATION 'PT1H30M' AS dur"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[duration]]}} ->
          # XTDB returns duration as a string
          assert is_binary(duration) || duration != nil

        {:error, error} ->
          flunk("DURATION query failed: #{inspect(error)}")
      end
    end

    test "executes duration arithmetic" do
      # XTDB only supports time-based durations
      sql = "SELECT TIMESTAMP '2024-01-01T00:00:00Z' + DURATION 'PT1H' AS future_date"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[result]]}} ->
          # Should be 2024-01-01 01:00:00Z
          assert result != nil

        {:error, error} ->
          flunk("Duration arithmetic failed: #{inspect(error)}")
      end
    end
  end

  # ============================================================================
  # Interval Type Tests
  # ============================================================================

  describe "Interval type casting" do
    test "casts ISO 8601 interval strings" do
      {:ok, interval} = Interval.cast_input("P1Y2M3D", [])
      assert interval.years == 1
      assert interval.months == 2
      assert interval.days == 3
    end

    test "casts SQL interval strings" do
      {:ok, interval} = Interval.cast_input("1 year 2 months 3 days", [])
      assert interval.years == 1
      assert interval.months == 2
      assert interval.days == 3
    end

    test "casts from map" do
      {:ok, interval} = Interval.cast_input(%{years: 1, months: 2}, [])
      assert interval.years == 1
      assert interval.months == 2
    end

    test "handles nil" do
      assert {:ok, nil} = Interval.cast_input(nil, [])
    end

    test "converts to ISO format" do
      interval = %Interval{years: 1, months: 2, days: 3, hours: 4, minutes: 5, seconds: 6}
      assert "P1Y2M3DT4H5M6S" == Interval.to_iso(interval)
    end

    test "converts to SQL format" do
      interval = %Interval{years: 1, months: 2, days: 3}
      assert "1 year 2 months 3 days" == Interval.to_sql(interval)
    end

    test "handles singular/plural in SQL format" do
      assert "1 year" == Interval.to_sql(%Interval{years: 1})
      assert "2 years" == Interval.to_sql(%Interval{years: 2})
    end

    test "dumps to native format" do
      interval = %Interval{years: 1, months: 2}
      {:ok, result} = Interval.dump_to_native(interval, [])
      assert result == "P1Y2M"
    end
  end

  # ============================================================================
  # Period Type Tests
  # ============================================================================

  describe "Period type casting" do
    @from ~U[2024-01-01 00:00:00Z]
    @to ~U[2024-12-31 23:59:59Z]

    test "casts from map with DateTime values" do
      {:ok, period} = Period.cast_input(%{from: @from, to: @to}, [])
      assert period.from == @from
      assert period.to == @to
    end

    test "casts from map with string keys" do
      {:ok, period} =
        Period.cast_input(
          %{
            "from" => "2024-01-01T00:00:00Z",
            "to" => "2024-12-31T23:59:59Z"
          },
          []
        )

      assert period.from == @from
      assert period.to == @to
    end

    test "casts from tuple" do
      {:ok, period} = Period.cast_input({@from, @to}, [])
      assert period.from == @from
      assert period.to == @to
    end

    test "handles nil" do
      assert {:ok, nil} = Period.cast_input(nil, [])
    end

    test "creates period with new/2" do
      period = Period.new(@from, @to)
      assert period.from == @from
      assert period.to == @to
    end

    test "checks if datetime is contained in period" do
      period = Period.new(@from, @to)

      # In range
      assert Period.contains?(period, ~U[2024-06-15 12:00:00Z]) == true

      # At start (inclusive)
      assert Period.contains?(period, @from) == true

      # At end (exclusive)
      assert Period.contains?(period, @to) == false

      # Before range
      assert Period.contains?(period, ~U[2023-06-15 12:00:00Z]) == false

      # After range
      assert Period.contains?(period, ~U[2025-06-15 12:00:00Z]) == false
    end

    test "checks if periods overlap" do
      period1 = Period.new(@from, @to)
      period2 = Period.new(~U[2024-06-01 00:00:00Z], ~U[2025-06-01 00:00:00Z])
      period3 = Period.new(~U[2025-01-01 00:00:00Z], ~U[2025-12-31 00:00:00Z])

      assert Period.overlaps?(period1, period2) == true
      assert Period.overlaps?(period1, period3) == false
    end

    test "calculates duration in seconds" do
      period = Period.new(~U[2024-01-01 00:00:00Z], ~U[2024-01-02 00:00:00Z])
      assert Period.duration_seconds(period) == 86400
    end

    test "converts to SQL format" do
      period = Period.new(@from, @to)

      assert Period.to_sql(period) ==
               "PERIOD(TIMESTAMP '2024-01-01T00:00:00Z', TIMESTAMP '2024-12-31T23:59:59Z')"
    end

    test "dumps to native format" do
      period = Period.new(@from, @to)
      {:ok, result} = Period.dump_to_native(period, [])

      assert result["from"] == "2024-01-01T00:00:00Z"
      assert result["to"] == "2024-12-31T23:59:59Z"
    end
  end

  describe "Period SQL execution" do
    test "executes PERIOD literal in SQL" do
      sql = "SELECT PERIOD(TIMESTAMP '2024-01-01T00:00:00Z', TIMESTAMP '2024-12-31T23:59:59Z') AS time_range"

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[time_range]]}} ->
          assert time_range != nil

        {:error, error} ->
          flunk("PERIOD query failed: #{inspect(error)}")
      end
    end
  end

  # ============================================================================
  # URI Type Tests
  # ============================================================================

  describe "URI type casting" do
    test "casts valid URI strings" do
      {:ok, uri} = URIType.cast_input("https://example.com/path?query=value", [])
      assert uri == "https://example.com/path?query=value"
    end

    test "casts URI struct" do
      uri_struct = URI.parse("https://example.com")
      {:ok, uri} = URIType.cast_input(uri_struct, [])
      assert uri == "https://example.com"
    end

    test "rejects URI without scheme" do
      assert {:error, _} = URIType.cast_input("example.com", [])
    end

    test "handles nil" do
      assert {:ok, nil} = URIType.cast_input(nil, [])
    end

    test "extracts host from URI" do
      assert URIType.host("https://example.com/path") == "example.com"
    end

    test "extracts path from URI" do
      assert URIType.path("https://example.com/path/to/resource") == "/path/to/resource"
    end

    test "extracts scheme from URI" do
      assert URIType.scheme("https://example.com") == "https"
      assert URIType.scheme("ftp://files.example.com") == "ftp"
    end

    test "checks if URI is HTTPS" do
      assert URIType.https?("https://example.com") == true
      assert URIType.https?("http://example.com") == false
    end

    test "dumps to native format" do
      assert {:ok, "https://example.com"} = URIType.dump_to_native("https://example.com", [])
      assert {:ok, nil} = URIType.dump_to_native(nil, [])
    end
  end

  # ============================================================================
  # Query Integration Tests
  # ============================================================================

  describe "Query.escape_value for types" do
    test "escapes Interval struct" do
      interval = %Interval{years: 1, months: 2}
      assert Query.inline_params("SELECT $1", [interval]) == "SELECT DURATION 'P1Y2M'"
    end

    test "escapes Period struct" do
      period =
        Period.new(
          ~U[2024-01-01 00:00:00Z],
          ~U[2024-12-31 23:59:59Z]
        )

      result = Query.inline_params("SELECT $1", [period])

      assert result ==
               "SELECT PERIOD(TIMESTAMP '2024-01-01T00:00:00Z', TIMESTAMP '2024-12-31T23:59:59Z')"
    end
  end

  describe "SQL execution with inlined type values" do
    test "executes query with inlined Interval" do
      interval = %Interval{days: 7}
      sql = Query.inline_params("SELECT TIMESTAMP '2024-01-01T00:00:00Z' + $1 AS future", [interval])

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[result]]}} ->
          assert result != nil

        {:error, error} ->
          flunk("Interval inline query failed: #{inspect(error)}")
      end
    end

    test "executes query with inlined Period" do
      period = Period.new(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
      sql = Query.inline_params("SELECT $1 AS time_range", [period])

      case AshXTDB.TestRepo.query(sql, []) do
        {:ok, %{rows: [[result]]}} ->
          assert result != nil

        {:error, error} ->
          flunk("Period inline query failed: #{inspect(error)}")
      end
    end
  end
end
