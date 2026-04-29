defmodule FinanceSmithWeb.ViewScope do
  @moduledoc """
  Shared view-scope parsing and options used by LiveViews that support
  household vs personal scope switching.
  """

  @spec default_scope(%{household_id: term()}) :: String.t()
  def default_scope(%{household_id: hid}) when not is_nil(hid), do: "scope_household"
  def default_scope(_), do: "scope_personal"

  @spec parse_scope(String.t()) :: :household | :personal
  def parse_scope("scope_household"), do: :household
  def parse_scope("scope_personal"), do: :personal
  def parse_scope(_), do: :personal

  @spec validate_scope(String.t()) :: {:ok, String.t()} | :error
  def validate_scope("scope_household"), do: {:ok, "scope_household"}
  def validate_scope("scope_personal"), do: {:ok, "scope_personal"}
  def validate_scope(_), do: :error

  @spec scope_options(%{household_id: term()}) :: [{String.t(), String.t()}]
  def scope_options(user) do
    if user.household_id do
      [{"Household", "scope_household"}, {"Personal", "scope_personal"}]
    else
      [{"Personal", "scope_personal"}]
    end
  end
end
