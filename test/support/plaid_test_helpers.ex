defmodule FinanceSmith.Test.PlaidTestHelpers do
  @moduledoc false

  @doc """
  Minimal `accounts/get`-shaped response for `MockPlaid.get_accounts/1` in tests.

  Options:
  - `:account_id` — override the Plaid account_id string (default `"acc_mock_default"`)
  - `:current` — override current balance (default `1000.0`)
  - `:available` — override available balance (default `nil`)
  - `:limit` — override credit limit (default `nil`)
  """
  def mock_accounts_response(opts \\ []) do
    account_id = Keyword.get(opts, :account_id, "acc_mock_default")
    current = Keyword.get(opts, :current, 1000.0)
    available = Keyword.get(opts, :available, nil)
    limit = Keyword.get(opts, :limit, nil)

    %Plaid.Accounts{
      accounts: [
        %Plaid.Accounts.Account{
          account_id: account_id,
          name: "Mock Checking",
          type: "depository",
          subtype: "checking",
          mask: "1234",
          balances: %Plaid.Accounts.Account.Balance{
            current: current,
            available: available,
            limit: limit
          }
        }
      ],
      item: nil,
      request_id: "req_mock"
    }
  end

  @doc """
  Minimal `accounts/balance/get`-shaped response for `MockPlaid.get_balance/1`.
  Accepts the same options as `mock_accounts_response/1`.
  """
  def mock_balance_response(opts \\ []), do: mock_accounts_response(opts)
end
