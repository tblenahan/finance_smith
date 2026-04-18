defmodule FinanceSmith.Banking.PlaidCategories do
  @moduledoc """
  Display formatter for Plaid `personal_finance_category.primary_subcategory`
  values. Converts the raw enum (e.g. `"FOOD_AND_DRINK_RESTAURANTS"`) to a
  human-readable label by downcasing and replacing underscores with spaces.
  """

  @spec format(String.t() | nil) :: String.t() | nil
  def format(nil), do: nil

  def format(cat) when is_binary(cat) do
    cat
    |> String.downcase()
    |> String.replace("_", " ")
  end
end
