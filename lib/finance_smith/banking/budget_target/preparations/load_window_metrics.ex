defmodule FinanceSmith.Banking.BudgetTarget.Preparations.LoadWindowMetrics do
  @moduledoc """
  Loads windowed spend metrics for `:for_window` using the action's date args.
  """

  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    date_args = %{
      start_date: Ash.Query.get_argument(query, :start_date),
      end_date: Ash.Query.get_argument(query, :end_date)
    }

    # scaled_target is pure math on the target amount; only the spend
    # calculations are scoped to an optional user.
    spend_args = Map.put(date_args, :user_id, Ash.Query.get_argument(query, :user_id))

    Ash.Query.load(query,
      actual_spend: spend_args,
      scaled_target: date_args,
      projected_spend: spend_args
    )
  end
end
