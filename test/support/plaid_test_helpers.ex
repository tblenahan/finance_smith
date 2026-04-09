defmodule FinanceSmith.Test.PlaidTestHelpers do
  @moduledoc false

  @doc """
  Minimal `accounts/get`-shaped response for `MockPlaid.get_accounts/1` in tests.
  """
  def mock_accounts_response(opts \\ []) do
    account_id = Keyword.get(opts, :account_id, "acc_mock_default")

    %Plaid.Accounts{
      accounts: [
        %Plaid.Accounts.Account{
          account_id: account_id,
          name: "Mock Checking",
          type: "depository",
          subtype: "checking",
          mask: "1234",
          balances: %Plaid.Accounts.Account.Balance{current: 1000.0}
        }
      ],
      item: nil,
      request_id: "req_mock"
    }
  end
end
