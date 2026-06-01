defmodule FinanceSmith.Banking.Account do
  use Ash.Resource,
    domain: FinanceSmith.Banking,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "accounts"
    repo FinanceSmith.Repo
    schema "core"

    references do
      reference :plaid_item, on_delete: :delete, index?: true
      reference :duplicate_of, on_delete: :nilify, index?: true
    end

    custom_indexes do
      index [:plaid_item_id, :status], name: "accounts_plaid_item_id_status_index"
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    read :read_for_ui do
      description """
      User-facing account read. Excludes soft-linked Plaid reconnect duplicates.
      System jobs load accounts via the default `:read` (e.g. SyncWorker, TransactionProcessor).
      """

      filter expr(is_nil(duplicate_of_id))
    end

    create :upsert_from_plaid do
      accept [
        :plaid_account_id,
        :plaid_item_id,
        :name,
        :mask,
        :type,
        :subtype,
        :current_balance,
        :credit_limit
      ]

      upsert? true
      upsert_identity :unique_plaid_account_id

      # :status is intentionally excluded — manual deactivation is preserved across syncs.
      # Plaid re-syncing an account should not resurrect one the user has deactivated.
      upsert_fields [:name, :mask, :type, :subtype, :current_balance, :credit_limit]

      change FinanceSmith.Banking.Account.Changes.DetectDuplicateAccount
    end

    update :update_balance do
      accept [:current_balance, :credit_limit]
    end
  end

  policies do
    policy action_type(:read) do
      # User.household_id is allow_nil?: false — every actor always has a
      # household_id. The not-is_nil guard is kept for defensive clarity.
      authorize_if expr(
                     plaid_item.user_id == ^actor(:id) or
                       (not is_nil(^actor(:household_id)) and
                          plaid_item.user.household_id == ^actor(:household_id))
                   )
    end

    # Writes are system-only. SyncWorker performs account writes with
    # authorize?: false, bypassing policies.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :plaid_account_id, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string, public?: true
    attribute :mask, :string, public?: true
    attribute :type, :string, public?: true
    attribute :subtype, :string, public?: true

    attribute :current_balance, :integer, public?: true
    attribute :credit_limit, :integer, public?: true

    attribute :status, FinanceSmith.Banking.Types.AccountStatus do
      allow_nil? false
      default :active
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :plaid_item, FinanceSmith.Banking.PlaidItem do
      allow_nil? false
      public? true
    end

    belongs_to :duplicate_of, FinanceSmith.Banking.Account

    has_many :transactions, FinanceSmith.Banking.Transaction
  end

  calculations do
    calculate :available_credit,
              :integer,
              expr(
                if(is_nil(credit_limit), 0, credit_limit) -
                  if(is_nil(current_balance), 0, current_balance)
              )
  end

  identities do
    identity :unique_plaid_account_id, [:plaid_account_id]
  end
end
