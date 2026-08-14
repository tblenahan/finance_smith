defmodule FinanceSmith.Banking.DatePeriodTest do
  use ExUnit.Case, async: true

  alias FinanceSmith.Banking.DatePeriod

  describe "to_range/2 weekly" do
    test "resolves ISO Monday–Sunday around a Wednesday" do
      assert DatePeriod.to_range(:weekly, ~D[2026-03-11]) ==
               {~D[2026-03-09], ~D[2026-03-15]}
    end
  end

  describe "to_range/2 monthly" do
    test "resolves a non-leap February" do
      assert DatePeriod.to_range(:monthly, ~D[2026-02-15]) ==
               {~D[2026-02-01], ~D[2026-02-28]}
    end

    test "resolves a leap-year February including the 29th" do
      assert DatePeriod.to_range(:monthly, ~D[2024-02-15]) ==
               {~D[2024-02-01], ~D[2024-02-29]}
    end
  end

  describe "to_range/2 quarterly" do
    test "resolves Q1 as January through March" do
      assert DatePeriod.to_range(:quarterly, ~D[2026-02-14]) ==
               {~D[2026-01-01], ~D[2026-03-31]}
    end

    test "resolves Q4 as October through December" do
      assert DatePeriod.to_range(:quarterly, ~D[2026-11-01]) ==
               {~D[2026-10-01], ~D[2026-12-31]}
    end
  end

  describe "to_range/2 yearly" do
    test "resolves the calendar year containing Independence Day 2026" do
      assert DatePeriod.to_range(:yearly, ~D[2026-07-04]) ==
               {~D[2026-01-01], ~D[2026-12-31]}
    end
  end

  describe "to_range/1" do
    test "matches to_range/2 with Date.utc_today()" do
      today = Date.utc_today()

      assert DatePeriod.to_range(:weekly) == DatePeriod.to_range(:weekly, today)
      assert DatePeriod.to_range(:monthly) == DatePeriod.to_range(:monthly, today)
      assert DatePeriod.to_range(:quarterly) == DatePeriod.to_range(:quarterly, today)
      assert DatePeriod.to_range(:yearly) == DatePeriod.to_range(:yearly, today)
    end
  end

  describe "to_range/2 invalid period_type" do
    test "raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        apply(DatePeriod, :to_range, [:daily, ~D[2026-03-11]])
      end
    end
  end

  describe "day_count/2" do
    test "counts a single day as 1" do
      assert DatePeriod.day_count(~D[2026-03-01], ~D[2026-03-01]) == 1
    end

    test "counts an inclusive 10-day window" do
      assert DatePeriod.day_count(~D[2026-03-01], ~D[2026-03-10]) == 10
    end

    test "returns 0 when end_date is before start_date" do
      assert DatePeriod.day_count(~D[2026-03-10], ~D[2026-03-01]) == 0
    end
  end

  describe "elapsed_days/3" do
    test "returns 0 when today is before the window" do
      assert DatePeriod.elapsed_days(~D[2026-03-10], ~D[2026-03-20], ~D[2026-03-01]) == 0
    end

    test "counts inclusively through today when the window is in progress" do
      assert DatePeriod.elapsed_days(~D[2026-03-10], ~D[2026-03-20], ~D[2026-03-15]) == 6
    end

    test "returns the full window when today is after end_date" do
      assert DatePeriod.elapsed_days(~D[2026-03-10], ~D[2026-03-20], ~D[2026-03-25]) == 11
    end
  end

  describe "period_day_count/2" do
    test "counts 366 days in leap year 2024" do
      assert DatePeriod.period_day_count(:yearly, ~D[2024-07-04]) == 366
    end
  end
end
