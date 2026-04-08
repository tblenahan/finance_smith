defmodule FinanceSmith.Banking.PlaidBehaviour do
  @moduledoc """
  Behaviour for Plaid API calls used by `FinanceSmith.Banking.Plaid`.

  Test environment swaps the implementation via `:plaid_client` application
  config (see `config/test.exs`) so LiveViews and Ash changes can be tested
  without hitting the Plaid API.
  """

  @callback create_link_token(map()) :: {:ok, Plaid.Link.t()} | {:error, term()}
  @callback exchange_public_token(map()) :: {:ok, map()} | {:error, term()}
  @callback get_accounts(map()) :: {:ok, Plaid.Accounts.t()} | {:error, term()}
  @callback get_balance(map()) :: {:ok, Plaid.Accounts.t()} | {:error, term()}
  @callback get_item(map()) :: {:ok, Plaid.Item.t()} | {:error, term()}
  @callback get_institution(map()) :: {:ok, Plaid.Institutions.Institution.t()} | {:error, term()}
  @callback remove_item(map()) :: {:ok, map()} | {:error, term()}
  @callback sync_transactions(map()) :: {:ok, Plaid.Transactions.Sync.t()} | {:error, term()}
end
