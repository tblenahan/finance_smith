defmodule FinanceSmith.Banking.Transaction.Calculations.MetaCategoryName do
  @moduledoc """
  Returns the `MetaCategory.name` for a Transaction based on its
  `personal_finance_category` and the actor's household's CategoryMapping rules.

  This is a batch calculation — one CategoryMapping query (with MetaCategory
  loaded) covers all records in the current page. The actor's `household_id` is
  used directly to scope the query, avoiding deep relationship traversal through
  User (which has self-only read policies).

  When the actor is nil (system/test context with `authorize?: false`) or the
  transaction has no `personal_finance_category`, the result is nil.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  @impl true
  def load(_query, _opts, _context), do: []

  @impl true
  def calculate(records, _opts, context) do
    plaid_categories =
      records
      |> Enum.map(& &1.personal_finance_category)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    lookup = fetch_lookup(plaid_categories, context)

    Enum.map(records, fn txn ->
      Map.get(lookup, txn.personal_finance_category)
    end)
  end

  defp fetch_lookup([], _context), do: %{}
  defp fetch_lookup(_cats, %{actor: nil}), do: %{}

  defp fetch_lookup(plaid_categories, context) do
    actor = context.actor

    FinanceSmith.Banking.CategoryMapping
    |> Ash.Query.filter(
      household_id == ^actor.household_id and
        plaid_category in ^plaid_categories
    )
    |> Ash.Query.load(:meta_category)
    |> Ash.read!(actor: actor, authorize?: context.authorize?)
    |> Map.new(fn m -> {m.plaid_category, m.meta_category.name} end)
  end
end
