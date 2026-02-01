# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Types.Duration do
  @moduledoc """
  An Ash type for XTDB Duration values.

  Durations represent a length of time in ISO 8601 format (e.g., "P1Y2M3D" for 1 year, 2 months, 3 days,
  or "PT1H30M" for 1 hour and 30 minutes).

  ## Format

  ISO 8601 duration format: `P[n]Y[n]M[n]DT[n]H[n]M[n]S`

  - `P` - Duration designator (required at the start)
  - `Y` - Year designator
  - `M` - Month designator (before T) or Minute designator (after T)
  - `D` - Day designator
  - `T` - Time designator (separates date from time components)
  - `H` - Hour designator
  - `S` - Second designator

  ## Examples

  - `"P1Y"` - 1 year
  - `"P1M"` - 1 month
  - `"P1D"` - 1 day
  - `"PT1H"` - 1 hour
  - `"PT1M"` - 1 minute
  - `"PT1S"` - 1 second
  - `"P1Y2M3DT4H5M6S"` - 1 year, 2 months, 3 days, 4 hours, 5 minutes, 6 seconds

  ## Usage

      defmodule MyApp.Task do
        use Ash.Resource

        attributes do
          attribute :estimated_duration, AshXTDB.Types.Duration
        end
      end
  """

  use Ash.Type

  @duration_regex ~r/^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$/

  @impl Ash.Type
  def storage_type(_), do: :string

  @impl Ash.Type
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(value, _) when is_binary(value) do
    if valid_duration?(value) do
      {:ok, value}
    else
      {:error, message: "Invalid ISO 8601 duration format. Expected format like 'P1Y2M3DT4H5M6S'"}
    end
  end

  def cast_input(_, _) do
    {:error, message: "Duration must be a string in ISO 8601 format"}
  end

  @impl Ash.Type
  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(value, _) when is_binary(value), do: {:ok, value}
  def cast_stored(_, _), do: :error

  @impl Ash.Type
  def dump_to_native(nil, _), do: {:ok, nil}
  def dump_to_native(value, _) when is_binary(value), do: {:ok, value}
  def dump_to_native(_, _), do: :error

  @doc """
  Validates if a string is a valid ISO 8601 duration.
  """
  @spec valid_duration?(String.t()) :: boolean()
  def valid_duration?(value) when is_binary(value) do
    case Regex.run(@duration_regex, value) do
      nil -> false
      [match | _] when match == "P" -> false  # Empty duration "P" is invalid
      [match | _] when match == "PT" -> false  # Empty time-only duration "PT" is invalid
      _ -> true
    end
  end

  def valid_duration?(_), do: false

  @doc """
  Parses a duration string into its components.

  Returns a map with keys: :years, :months, :days, :hours, :minutes, :seconds
  """
  @spec parse(String.t()) :: {:ok, map()} | :error
  def parse(value) when is_binary(value) do
    case Regex.run(@duration_regex, value) do
      nil ->
        :error

      [_ | captures] ->
        # Pad captures to ensure we have 6 elements (regex may not capture all groups)
        padded = pad_captures(captures, 6)
        [years, months, days, hours, minutes, seconds] = Enum.map(padded, &parse_capture/1)

        {:ok,
         %{
           years: trunc(years),
           months: trunc(months),
           days: trunc(days),
           hours: trunc(hours),
           minutes: trunc(minutes),
           seconds: seconds
         }}
    end
  end

  defp parse_capture(nil), do: 0
  defp parse_capture(""), do: 0
  defp parse_capture(str) when is_binary(str) do
    case Float.parse(str) do
      {num, _} -> num
      :error -> 0
    end
  end

  defp pad_captures(list, n) when length(list) >= n, do: Enum.take(list, n)
  defp pad_captures(list, n), do: list ++ List.duplicate(nil, n - length(list))

  @doc """
  Builds a duration string from components.
  """
  @spec build(map()) :: String.t()
  def build(components) when is_map(components) do
    date_part =
      [
        format_component(components[:years], "Y"),
        format_component(components[:months], "M"),
        format_component(components[:days], "D")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    time_part =
      [
        format_component(components[:hours], "H"),
        format_component(components[:minutes], "M"),
        format_component(components[:seconds], "S")
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

  defp format_component(nil, _), do: nil
  defp format_component(0, _), do: nil
  defp format_component(value, _) when is_float(value) and value == 0.0, do: nil
  defp format_component(value, suffix) when is_float(value), do: "#{value}#{suffix}"
  defp format_component(value, suffix), do: "#{value}#{suffix}"
end
