defmodule FinanceSmith.Banking.PlaidBalances do
  @moduledoc """
  Shared helpers for converting Plaid balance maps to integer cents.

  Used by `ExchangePublicToken` (on initial account creation), `SyncWorker`
  (on periodic real-time balance refresh), `TransactionProcessor` (on cached
  balance extraction from the sync payload), and `BalanceRefresh` (shared
  real-time fetch helper) to ensure consistent conversion logic across all
  Plaid-facing paths.
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
  Returns the `available` balance as integer cents, or `nil` if unavailable.

  Certain account types (e.g. investment accounts, some savings accounts) do
  not provide an available balance. `nil` is a valid and expected return value
  and must be tolerated by all callers.
  """
  @spec balance_available_to_cents(map() | nil) :: integer() | nil
  def balance_available_to_cents(nil), do: nil

  def balance_available_to_cents(%{available: available}) when is_number(available) do
    round(available * 100)
  end

  def balance_available_to_cents(_), do: nil

  @doc """
  Returns the credit `limit` as integer cents, or `nil` if unavailable.
  """
  @spec balance_limit_to_cents(map() | nil) :: integer() | nil
  def balance_limit_to_cents(%{limit: limit}) when is_number(limit), do: round(limit * 100)
  def balance_limit_to_cents(_), do: nil
end
