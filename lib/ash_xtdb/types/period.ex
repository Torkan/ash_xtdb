# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Types.Period do
  @moduledoc """
  An Ash type for XTDB Period values.

  A Period represents a time range with a start and end timestamp.
  XTDB uses periods for temporal validity ranges (valid_time, system_time).

  ## Format

  In XTDB SQL, periods are expressed as:
  `PERIOD(TIMESTAMP '2024-01-01T00:00:00Z', TIMESTAMP '2024-12-31T23:59:59Z')`

  ## Usage

      defmodule MyApp.Contract do
        use Ash.Resource

        attributes do
          attribute :validity_period, AshXTDB.Types.Period
        end
      end

  ## Examples

      # Create a period
      period = %AshXTDB.Types.Period{
        from: ~U[2024-01-01 00:00:00Z],
        to: ~U[2024-12-31 23:59:59Z]
      }

      # Or use the constructor
      period = AshXTDB.Types.Period.new(~U[2024-01-01 00:00:00Z], ~U[2024-12-31 23:59:59Z])
  """

  use Ash.Type

  defstruct [:from, :to]

  @type t :: %__MODULE__{
          from: DateTime.t(),
          to: DateTime.t()
        }

  @impl Ash.Type
  def storage_type(_), do: :map

  @impl Ash.Type
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(%__MODULE__{} = period, _), do: {:ok, period}

  def cast_input(%{from: from, to: to}, _) do
    with {:ok, from_dt} <- parse_datetime(from),
         {:ok, to_dt} <- parse_datetime(to) do
      {:ok, %__MODULE__{from: from_dt, to: to_dt}}
    end
  end

  def cast_input(%{"from" => from, "to" => to}, _) do
    with {:ok, from_dt} <- parse_datetime(from),
         {:ok, to_dt} <- parse_datetime(to) do
      {:ok, %__MODULE__{from: from_dt, to: to_dt}}
    end
  end

  def cast_input({from, to}, _) do
    with {:ok, from_dt} <- parse_datetime(from),
         {:ok, to_dt} <- parse_datetime(to) do
      {:ok, %__MODULE__{from: from_dt, to: to_dt}}
    end
  end

  def cast_input(_, _) do
    {:error, message: "Period must have :from and :to DateTime values"}
  end

  @impl Ash.Type
  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(%{"from" => from, "to" => to}, _) do
    with {:ok, from_dt} <- parse_datetime(from),
         {:ok, to_dt} <- parse_datetime(to) do
      {:ok, %__MODULE__{from: from_dt, to: to_dt}}
    end
  end

  def cast_stored(%{from: from, to: to}, _) do
    with {:ok, from_dt} <- parse_datetime(from),
         {:ok, to_dt} <- parse_datetime(to) do
      {:ok, %__MODULE__{from: from_dt, to: to_dt}}
    end
  end

  def cast_stored(_, _), do: :error

  @impl Ash.Type
  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(%__MODULE__{from: from, to: to}, _) do
    {:ok,
     %{
       "from" => DateTime.to_iso8601(from),
       "to" => DateTime.to_iso8601(to)
     }}
  end

  def dump_to_native(_, _), do: :error

  @doc """
  Creates a new Period from two DateTimes.
  """
  @spec new(DateTime.t(), DateTime.t()) :: t()
  def new(%DateTime{} = from, %DateTime{} = to) do
    %__MODULE__{from: from, to: to}
  end

  @doc """
  Checks if a DateTime falls within the period (inclusive of start, exclusive of end).
  """
  @spec contains?(t(), DateTime.t()) :: boolean()
  def contains?(%__MODULE__{from: from, to: to}, %DateTime{} = datetime) do
    DateTime.compare(datetime, from) in [:gt, :eq] and DateTime.compare(datetime, to) == :lt
  end

  @doc """
  Checks if two periods overlap.
  """
  @spec overlaps?(t(), t()) :: boolean()
  def overlaps?(%__MODULE__{from: from1, to: to1}, %__MODULE__{from: from2, to: to2}) do
    DateTime.compare(from1, to2) == :lt and DateTime.compare(from2, to1) == :lt
  end

  @doc """
  Returns the duration of the period in seconds.
  """
  @spec duration_seconds(t()) :: integer()
  def duration_seconds(%__MODULE__{from: from, to: to}) do
    DateTime.diff(to, from)
  end

  @doc """
  Converts the period to XTDB SQL PERIOD syntax.
  """
  @spec to_sql(t()) :: String.t()
  def to_sql(%__MODULE__{from: from, to: to}) do
    "PERIOD(TIMESTAMP '#{DateTime.to_iso8601(from)}', TIMESTAMP '#{DateTime.to_iso8601(to)}')"
  end

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, message: "Invalid datetime format: #{str}"}
    end
  end

  defp parse_datetime(_), do: {:error, message: "Invalid datetime"}
end
