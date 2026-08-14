defmodule FinanceSmith.Banking.DatePeriod do
  @moduledoc """
  Calendar math for date-windowed budget metrics.

  Resolves weekly, monthly, quarterly, and yearly ranges around a given date
  and counts inclusive days within those windows. This module is pure
  calendar logic with no persistence.
  """

  @type period_type :: :weekly | :monthly | :quarterly | :yearly

  @doc """
  Returns the inclusive `{start_date, end_date}` of the calendar period of
  `period_type` that contains today (`Date.utc_today/0`).
  """
  @spec to_range(period_type) :: {Date.t(), Date.t()}
  def to_range(period_type), do: to_range(period_type, Date.utc_today())

  @doc """
  Returns the inclusive `{start_date, end_date}` of the calendar period of
  `period_type` that contains `date`.

  Weeks are ISO Monday–Sunday. Quarters are calendar Q1 Jan–Mar through
  Q4 Oct–Dec.
  """
  @spec to_range(period_type, Date.t()) :: {Date.t(), Date.t()}
  def to_range(:weekly, %Date{} = date) do
    {Date.beginning_of_week(date), Date.end_of_week(date)}
  end

  def to_range(:monthly, %Date{} = date) do
    {Date.beginning_of_month(date), Date.end_of_month(date)}
  end

  def to_range(:quarterly, %Date{} = date) do
    start_month = quarter_start_month(date.month)
    start_date = Date.new!(date.year, start_month, 1)
    end_date = Date.end_of_month(Date.new!(date.year, start_month + 2, 1))
    {start_date, end_date}
  end

  def to_range(:yearly, %Date{} = date) do
    {Date.new!(date.year, 1, 1), Date.new!(date.year, 12, 31)}
  end

  @doc """
  Inclusive day count of `[start_date, end_date]`.

  Returns `0` when `end_date` is before `start_date`.
  """
  @spec day_count(Date.t(), Date.t()) :: non_neg_integer()
  def day_count(%Date{} = start_date, %Date{} = end_date) do
    max(0, Date.diff(end_date, start_date) + 1)
  end

  @doc """
  Inclusive days elapsed from `start_date` through `today`, capped to the
  `[start_date, end_date]` window.

  Returns `0` when `today` is before the window, the full `day_count/2` when
  `today` is after the window, and `Date.diff(today, start_date) + 1` when
  `today` falls inside it.
  """
  @spec elapsed_days(Date.t(), Date.t(), Date.t()) :: non_neg_integer()
  def elapsed_days(%Date{} = start_date, %Date{} = end_date, %Date{} = today) do
    cond do
      Date.compare(today, start_date) == :lt -> 0
      Date.compare(today, end_date) == :gt -> day_count(start_date, end_date)
      true -> Date.diff(today, start_date) + 1
    end
  end

  @doc """
  Day count of the calendar period of `period_type` that contains `date`.
  """
  @spec period_day_count(period_type, Date.t()) :: pos_integer()
  def period_day_count(period_type, %Date{} = date) do
    {start_date, end_date} = to_range(period_type, date)
    day_count(start_date, end_date)
  end

  defp quarter_start_month(month) when month in 1..3, do: 1
  defp quarter_start_month(month) when month in 4..6, do: 4
  defp quarter_start_month(month) when month in 7..9, do: 7
  defp quarter_start_month(month) when month in 10..12, do: 10
end
