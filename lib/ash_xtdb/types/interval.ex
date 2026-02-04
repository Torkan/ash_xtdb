# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Types.Interval do
  @moduledoc """
  An Ash type for XTDB Interval values.

  Intervals represent a time span similar to PostgreSQL intervals.
  They can be specified in various formats:

  ## Formats

  - ISO 8601 Duration: `"P1Y2M3DT4H5M6S"`
  - SQL Interval: `"1 year 2 months 3 days 4 hours 5 minutes 6 seconds"`
  - Shorthand: `"1 year"`, `"2 months"`, `"3 days"`, etc.

  ## Usage

      defmodule MyApp.Subscription do
        use Ash.Resource

        attributes do
          attribute :billing_interval, AshXTDB.Types.Interval
        end
      end
  """

  use Ash.Type

  # ISO 8601 duration format
  @iso_regex ~r/^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$/

  # SQL interval format: "1 year 2 months 3 days 4 hours 5 minutes 6 seconds"
  @sql_regex ~r/^(?:(\d+)\s*years?)?\s*(?:(\d+)\s*months?)?\s*(?:(\d+)\s*days?)?\s*(?:(\d+)\s*hours?)?\s*(?:(\d+)\s*minutes?)?\s*(?:(\d+(?:\.\d+)?)\s*seconds?)?$/i

  defstruct years: 0, months: 0, days: 0, hours: 0, minutes: 0, seconds: 0

  @type t :: %__MODULE__{
          years: non_neg_integer(),
          months: non_neg_integer(),
          days: non_neg_integer(),
          hours: non_neg_integer(),
          minutes: non_neg_integer(),
          seconds: number()
        }

  @impl Ash.Type
  def storage_type(_), do: :string

  @impl Ash.Type
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(%__MODULE__{} = interval, _), do: {:ok, interval}

  def cast_input(value, _) when is_binary(value) do
    cond do
      String.starts_with?(value, "P") ->
        parse_iso(value)

      true ->
        parse_sql(value)
    end
  end

  def cast_input(%{} = map, _) do
    interval = %__MODULE__{
      years: Map.get(map, :years, 0) || Map.get(map, "years", 0) || 0,
      months: Map.get(map, :months, 0) || Map.get(map, "months", 0) || 0,
      days: Map.get(map, :days, 0) || Map.get(map, "days", 0) || 0,
      hours: Map.get(map, :hours, 0) || Map.get(map, "hours", 0) || 0,
      minutes: Map.get(map, :minutes, 0) || Map.get(map, "minutes", 0) || 0,
      seconds: Map.get(map, :seconds, 0) || Map.get(map, "seconds", 0) || 0
    }

    {:ok, interval}
  end

  def cast_input(_, _) do
    {:error, message: "Interval must be a string or map"}
  end

  @impl Ash.Type
  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(value, constraints) when is_binary(value) do
    cast_input(value, constraints)
  end

  def cast_stored(_, _), do: :error

  @impl Ash.Type
  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(%__MODULE__{} = interval, _) do
    {:ok, to_iso(interval)}
  end

  def dump_to_native(value, _) when is_binary(value), do: {:ok, value}
  def dump_to_native(_, _), do: :error

  @doc """
  Converts an interval to ISO 8601 duration format.
  """
  @spec to_iso(t()) :: String.t()
  def to_iso(%__MODULE__{} = interval) do
    date_part =
      [
        format_component(interval.years, "Y"),
        format_component(interval.months, "M"),
        format_component(interval.days, "D")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    time_part =
      [
        format_component(interval.hours, "H"),
        format_component(interval.minutes, "M"),
        format_component(interval.seconds, "S")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    cond do
      date_part == "" and time_part == "" -> "P0D"
      time_part == "" -> "P" <> date_part
      date_part == "" -> "PT" <> time_part
      true -> "P" <> date_part <> "T" <> time_part
    end
  end

  @doc """
  Converts an interval to SQL format string.
  """
  @spec to_sql(t()) :: String.t()
  def to_sql(%__MODULE__{} = interval) do
    parts =
      [
        format_sql_part(interval.years, "year"),
        format_sql_part(interval.months, "month"),
        format_sql_part(interval.days, "day"),
        format_sql_part(interval.hours, "hour"),
        format_sql_part(interval.minutes, "minute"),
        format_sql_part(interval.seconds, "second")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [] do
      "0 seconds"
    else
      Enum.join(parts, " ")
    end
  end

  defp parse_iso(value) do
    case Regex.run(@iso_regex, value) do
      nil ->
        {:error, message: "Invalid ISO 8601 interval format"}

      [match | _] when match in ["P", "PT"] ->
        {:error, message: "Empty interval"}

      [_ | captures] ->
        [years, months, days, hours, minutes, seconds] = parse_captures(captures)

        {:ok,
         %__MODULE__{
           years: years,
           months: months,
           days: days,
           hours: hours,
           minutes: minutes,
           seconds: seconds
         }}
    end
  end

  defp parse_sql(value) do
    case Regex.run(@sql_regex, String.trim(value)) do
      nil ->
        {:error, message: "Invalid SQL interval format"}

      [match | _] when match == "" ->
        {:error, message: "Empty interval"}

      [_ | captures] ->
        [years, months, days, hours, minutes, seconds] = parse_captures(captures)

        {:ok,
         %__MODULE__{
           years: years,
           months: months,
           days: days,
           hours: hours,
           minutes: minutes,
           seconds: seconds
         }}
    end
  end

  defp parse_captures(captures) do
    Enum.map(captures, fn
      nil ->
        0

      "" ->
        0

      str ->
        case Float.parse(str) do
          {num, _} -> if trunc(num) == num, do: trunc(num), else: num
          :error -> 0
        end
    end)
    |> pad_to(6)
  end

  defp pad_to(list, n) when length(list) >= n, do: Enum.take(list, n)
  defp pad_to(list, n), do: list ++ List.duplicate(0, n - length(list))

  defp format_component(0, _), do: nil
  defp format_component(value, _) when is_float(value) and value == 0.0, do: nil
  defp format_component(value, suffix), do: "#{value}#{suffix}"

  defp format_sql_part(0, _), do: nil
  defp format_sql_part(value, _) when is_float(value) and value == 0.0, do: nil
  defp format_sql_part(1, unit), do: "1 #{unit}"
  defp format_sql_part(value, unit) when is_float(value) and value == 1.0, do: "1 #{unit}"
  defp format_sql_part(value, unit), do: "#{value} #{unit}s"
end
