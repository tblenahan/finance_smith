defmodule FinanceSmith.Banking.PlaidBalances do
  @moduledoc """
  Shared helpers for converting Plaid balance maps to integer cents.

  Used by both `ExchangePublicToken` (on initial account creation) and
  `SyncWorker` (on periodic balance refresh) to ensure consistent conversion
  logic across the two Plaid-facing paths.
  """

  @doc """
  Returns the `current` balance as integer cents, or `nil` if unavailable.
  """
  @spec balance_to_cents(map() | nil) :: integer() | nil
  def balance_to_cents(nil), do: nil

  def balance_to_cents(%{current: current}) when is_number(current) do
    round(current * 100)
  end

  def balance_to_cents(_), do: nil

  @doc """
  Returns the credit `limit` as integer cents, or `nil` if unavailable.
  """
  @spec balance_limit_to_cents(map() | nil) :: integer() | nil
  def balance_limit_to_cents(%{limit: limit}) when is_number(limit), do: round(limit * 100)
  def balance_limit_to_cents(_), do: nil
end
