defmodule FinanceSmith.Banking.BudgetTarget.Calculations.ProjectedSpend do
  @moduledoc """
  Extrapolates spend across the window from elapsed days.

  `elapsed` and `window_days` are computed in Elixir via `DatePeriod` at
  query-build time (`Date.utc_today/0`) and injected into SQL. Returns `0`
  when no days have elapsed (future window) so we never divide by zero.

  The extrapolation base is `actual_spend` through `as_of_date` (today
  clamped to `end_date`), so post-dated transactions still inside an
  in-progress window are not amplified by `window_days / elapsed`.
  """

  use Ash.Resource.Calculation

  alias FinanceSmith.Banking.DatePeriod

  @impl true
  def expression(_opts, context) do
    start_date = context.arguments[:start_date]
    end_date = context.arguments[:end_date]
    today = Date.utc_today()
    window_days = DatePeriod.day_count(start_date, end_date)
    elapsed = DatePeriod.elapsed_days(start_date, end_date, today)
    as_of = DatePeriod.as_of_date(end_date, today)

    expr(
      if ^elapsed == 0 do
        0
      else
        round(
          type(actual_spend(start_date: ^start_date, end_date: ^as_of), :decimal) *
            type(^window_days, :decimal) / type(^elapsed, :decimal)
        )
      end
    )
  end
end
