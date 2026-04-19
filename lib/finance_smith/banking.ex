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

      # Returns active PlaidItems visible to the actor (own + household members').
      define :list_active_plaid_items, action: :list_active

      # Used by the dashboard to load per-plaid-item KPI aggregates.
      define :get_plaid_item_kpis, action: :read, get_by: [:id]
    end

    resource FinanceSmith.Banking.Account do
      define :get_account_by_id, action: :read, get_by: [:id]
    end

    resource FinanceSmith.Banking.Transaction do
      define :list_transactions, action: :list

      define :list_transaction_categories, action: :categories

      # Lightweight read for chart rendering — no pagination.
      define :list_transactions_for_chart, action: :for_chart
    end
  end
end
