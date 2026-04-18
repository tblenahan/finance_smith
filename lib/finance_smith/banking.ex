defmodule FinanceSmith.Banking do
  use Ash.Domain

  resources do
    resource FinanceSmith.Banking.PlaidItem do
      define :create_plaid_item_from_public_token,
        action: :create_from_public_token,
        args: [:public_token]

      define :complete_plaid_item_sync, action: :complete_sync

      define :get_plaid_item_by_id, action: :read, get_by: [:id]

      define :get_plaid_item_summary_by_id, action: :read_for_ui, get_by: [:id]
    end

    resource FinanceSmith.Banking.Account do
      define :get_account_by_id, action: :read, get_by: [:id]
    end

    resource FinanceSmith.Banking.Transaction do
      define :list_recent_transactions, action: :for_dashboard

      define :list_transactions, action: :list

      define :list_transaction_categories, action: :categories
    end
  end
end
