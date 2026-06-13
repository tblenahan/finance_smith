defmodule FinanceSmith.Banking.PlaidItem do
  use Ash.Resource,
    domain: FinanceSmith.Banking,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    notifiers: [Ash.Notifier.PubSub],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "plaid_items"
    repo FinanceSmith.Repo
    schema "core"

    references do
      reference :user, on_delete: :delete, index?: true
    end
  end

  cloak do
    vault(FinanceSmith.Vault)
    attributes([:access_token])
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    create :create_from_public_token do
      description "Exchanges a Plaid public_token for an access_token and creates the PlaidItem."

      accept [:institution_name]

      argument :public_token, :string do
        allow_nil? false
        sensitive? true
      end

      change relate_actor(:user)
      change FinanceSmith.Banking.PlaidItem.Changes.ExchangePublicToken
    end

    read :read_for_ui do
      description "UI-safe read that excludes the cloaked access_token column."

      prepare build(
                select: [
                  :id,
                  :plaid_item_id,
                  :institution_name,
                  :status,
                  :last_synced_at,
                  :last_balance_synced_at,
                  :user_id,
                  :inserted_at,
                  :updated_at
                ]
              )
    end

    read :list_active do
      description "Returns all active PlaidItems the actor may read, sorted by institution name."

      prepare build(
                filter: [status: :active],
                select: [:id, :institution_name],
                sort: [institution_name: :asc]
              )
    end

    update :complete_sync do
      accept []
      change set_attribute(:last_synced_at, &DateTime.utc_now/0)
    end

    # System-only. Called by SyncWorker (after a real-time Plaid balance fetch)
    # with authorize?: false. The :fetch_realtime_balances change sets the
    # timestamp directly via force_change_attribute, so this action is only
    # called from the background worker path.
    update :update_balance_timestamp do
      accept []
      change set_attribute(:last_balance_synced_at, &DateTime.utc_now/0)
    end

    # Actor-facing real-time balance refresh. Ownership/household policy applies
    # (see policies block). The change module loads access_token + accounts with
    # authorize?: false tightly scoped to that single load — see AGENT_SECURITY.md
    # rule 6 for the full list of permitted access_token load sites.
    update :fetch_realtime_balances do
      description "Triggers a real-time Plaid /accounts/balance/get call for this item."

      accept []
      require_atomic? false
      change FinanceSmith.Banking.PlaidItem.Changes.FetchRealtimeBalances
    end
  end

  policies do
    policy action_type(:read) do
      # User.household_id is allow_nil?: false — every actor always has a
      # household_id. The not-is_nil guard is kept for defensive clarity.
      authorize_if expr(
                     user_id == ^actor(:id) or
                       (not is_nil(^actor(:household_id)) and
                          user.household_id == ^actor(:household_id))
                   )
    end

    # User-facing create: any authenticated actor may call this action.
    # `change relate_actor(:user)` in the action binds ownership.
    policy action(:create_from_public_token) do
      authorize_if actor_present()
    end

    # User-facing balance refresh: actor must own this item or share a household.
    # Kept as a dedicated policy so the intent is explicit and auditable.
    policy action(:fetch_realtime_balances) do
      authorize_if expr(
                     user_id == ^actor(:id) or
                       (not is_nil(^actor(:household_id)) and
                          user.household_id == ^actor(:household_id))
                   )
    end

    # All other writes are system-only. SyncWorker / complete_sync call with
    # `authorize?: false`, bypassing policies entirely. The `forbid_unless`
    # allowlist passes (no decision) for the two actor-driven writes above;
    # it forbids every other actor-driven write path.
    policy action_type([:create, :update, :destroy]) do
      forbid_unless action([:create_from_public_token, :fetch_realtime_balances])
      authorize_if always()
    end
  end

  pub_sub do
    module FinanceSmithWeb.Endpoint
    prefix "plaid_item"

    publish :complete_sync, ["sync_complete", :user_id]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :plaid_item_id, :string do
      allow_nil? false
    end

    attribute :access_token, :string do
      allow_nil? false
      constraints allow_empty?: false
    end

    attribute :institution_name, :string

    attribute :last_synced_at, :utc_datetime_usec do
      public? true
    end

    # Tracks the last time a real-time Plaid /accounts/balance/get call succeeded.
    # nil means a paid fetch has never been performed. Used by SyncWorker to gate
    # the 24-hour rate limit window and by the UI to surface the cost warning.
    attribute :last_balance_synced_at, :utc_datetime_usec do
      public? true
    end

    attribute :next_cursor, :string do
      # SyncWorker persists cursor via default `:update`; must be writable.
      public? true
    end

    attribute :status, FinanceSmith.Banking.Types.PlaidItemStatus do
      allow_nil? false
      default :active
      # SyncWorker sets `:error` on Plaid failures via default `:update`.
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, FinanceSmith.Identity.User do
      allow_nil? false
    end

    has_many :accounts, FinanceSmith.Banking.Account
  end

  aggregates do
    sum :kpi_assets, [:accounts], :current_balance do
      filter expr(
               type not in ["credit", "loan"] and status == :active and is_nil(duplicate_of_id)
             )

      default 0
    end

    sum :kpi_liabilities, [:accounts], :current_balance do
      filter expr(type in ["credit", "loan"] and status == :active and is_nil(duplicate_of_id))
      default 0
    end

    sum :kpi_outflow_30d, [:accounts, :transactions], :amount do
      filter expr(amount > 0 and date >= ago(30, :day))
      join_filter :accounts, expr(is_nil(duplicate_of_id))
      default 0
    end

    sum :kpi_inflow_30d, [:accounts, :transactions], :amount do
      filter expr(amount < 0 and date >= ago(30, :day))
      join_filter :accounts, expr(is_nil(duplicate_of_id))
      default 0
    end

    count :kpi_active_accounts_count, :accounts do
      filter expr(status == :active and is_nil(duplicate_of_id))
      default 0
    end
  end

  identities do
    identity :unique_plaid_item_id, [:plaid_item_id]
  end
end
