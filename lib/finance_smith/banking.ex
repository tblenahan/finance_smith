defmodule FinanceSmith.Banking do
  use Ash.Domain

  resources do
    resource FinanceSmith.Banking.PlaidItem do
      define :create_plaid_item_from_public_token,
        action: :create_from_public_token,
        args: [:public_token]
    end

    resource FinanceSmith.Banking.Account
    resource FinanceSmith.Banking.Transaction
  end
end
