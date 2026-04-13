defmodule FinanceSmith.Banking.PlaidItem do
  use Ash.Resource,
    domain: FinanceSmith.Banking,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    notifiers: [Ash.Notifier.PubSub]

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

    update :complete_sync do
      accept []
      change set_attribute(:last_synced_at, &DateTime.utc_now/0)
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

  identities do
    identity :unique_plaid_item_id, [:plaid_item_id]
  end
end
