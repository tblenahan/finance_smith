defmodule FinanceSmith.Banking.BudgetTarget.Calculations.ProjectedSpend do
  @moduledoc """
  Extrapolates `actual_spend` across the window from elapsed days.

  `elapsed` and `window_days` are computed in Elixir via `DatePeriod` at
  query-build time (`Date.utc_today/0`) and injected into SQL. Returns `0`
  when no days have elapsed (future window) so we never divide by zero.
  """

  use Ash.Resource.Calculation

  alias FinanceSmith.Banking.DatePeriod

  @impl true
  def expression(_opts, context) do
    start_date = context.arguments[:start_date]
    end_date = context.arguments[:end_date]
    window_days = DatePeriod.day_count(start_date, end_date)
    elapsed = DatePeriod.elapsed_days(start_date, end_date, Date.utc_today())

    expr(
      if ^elapsed == 0 do
        0
      else
        round(
          type(actual_spend(start_date: ^start_date, end_date: ^end_date), :decimal) *
            type(^window_days, :decimal) / type(^elapsed, :decimal)
        )
      end
    )
  end
end
