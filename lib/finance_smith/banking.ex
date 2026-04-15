defmodule FinanceSmith.Banking do
  use Ash.Domain

  resources do
    resource FinanceSmith.Banking.PlaidItem do
      define :create_plaid_item_from_public_token,
        action: :create_from_public_token,
        args: [:public_token]

      define :complete_plaid_item_sync, action: :complete_sync
    end

    resource FinanceSmith.Banking.Account

    resource FinanceSmith.Banking.Transaction do
      define :list_recent_transactions, action: :for_dashboard

      define :list_transactions, action: :list
    end
  end
end
