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

      # Actor-authorized real-time balance refresh. Ownership/household policy
      # applies; the access_token load is scoped inside FetchRealtimeBalances.
      define :fetch_realtime_balances, action: :fetch_realtime_balances, get_by: [:id]
    end

    resource FinanceSmith.Banking.Account do
      define :get_account_by_id, action: :read_for_ui, get_by: [:id]
      define :list_accounts, action: :read_for_ui
      define :update_account_balance, action: :update_balance

      # :update_cached_balances is intentionally NOT defined here. It is
      # system-only — called by BalanceRefresh and TransactionProcessor via
      # Ash.Changeset.for_update/3 directly with authorize?: false — and must
      # not be exposed as a Banking.* code interface.
    end

    resource FinanceSmith.Banking.Transaction do
      define :list_transactions, action: :list

      # Lightweight read for chart rendering — no pagination.
      define :list_transactions_for_chart, action: :for_chart
    end

    resource FinanceSmith.Banking.MetaCategory do
      define :list_meta_categories, action: :read
      define :get_meta_category_by_id, action: :read, get_by: [:id]
      define :update_meta_category, action: :update
      define :destroy_meta_category, action: :destroy
    end

    resource FinanceSmith.Banking.CategoryMapping do
      define :list_category_mappings, action: :read
      define :destroy_category_mapping, action: :destroy
    end
  end
end
