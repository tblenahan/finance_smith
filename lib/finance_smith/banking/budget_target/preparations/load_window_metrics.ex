defmodule FinanceSmith.Banking.BudgetTarget.Preparations.LoadWindowMetrics do
  @moduledoc """
  Loads windowed spend metrics for `:for_window` using the action's date args.
  """

  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    args = %{
      start_date: Ash.Query.get_argument(query, :start_date),
      end_date: Ash.Query.get_argument(query, :end_date)
    }

    Ash.Query.load(query,
      actual_spend: args,
      scaled_target: args,
      projected_spend: args
    )
  end
end
