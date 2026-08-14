defmodule FinanceSmith.Banking.BudgetTarget.Calculations.ScaledTarget do
  @moduledoc """
  Scales `amount` from the row's calendar period onto the requested window.

  Day counts are computed in Elixir via `DatePeriod` and injected into SQL so
  integer division cannot truncate (e.g. 1000 * 2 / 3 → 667).
  """

  use Ash.Resource.Calculation

  alias FinanceSmith.Banking.DatePeriod

  @impl true
  def expression(_opts, context) do
    start_date = context.arguments[:start_date]
    end_date = context.arguments[:end_date]

    window_days = DatePeriod.day_count(start_date, end_date)
    weekly_days = DatePeriod.period_day_count(:weekly, start_date)
    monthly_days = DatePeriod.period_day_count(:monthly, start_date)
    quarterly_days = DatePeriod.period_day_count(:quarterly, start_date)
    yearly_days = DatePeriod.period_day_count(:yearly, start_date)

    expr(
      round(
        type(amount, :decimal) * type(^window_days, :decimal) /
          type(
            cond do
              period_type == :weekly -> ^weekly_days
              period_type == :monthly -> ^monthly_days
              period_type == :quarterly -> ^quarterly_days
              true -> ^yearly_days
            end,
            :decimal
          )
      )
    )
  end
end
