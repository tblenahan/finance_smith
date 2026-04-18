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
                  :user_id,
                  :inserted_at,
                  :updated_at
                ]
              )
    end

    update :complete_sync do
      accept []
      change set_attribute(:last_synced_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy action_type(:read) do
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

    # All other writes are system-only. SyncWorker / complete_sync call with
    # `authorize?: false`, bypassing policies entirely. The `forbid_unless`
    # passes (no decision) for :create_from_public_token, which is already
    # covered by its own policy above; it forbids every other actor-driven write.
    policy action_type([:create, :update, :destroy]) do
      forbid_unless action(:create_from_public_token)
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
