defmodule FinanceSmith.Banking.PlaidItem do
  use Ash.Resource,
    domain: FinanceSmith.Banking,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak]

  postgres do
    table "plaid_items"
    repo FinanceSmith.Repo

    references do
      reference :user, on_delete: :delete, index?: true
    end
  end

  cloak do
    vault FinanceSmith.Vault
    attributes [:access_token]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
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

    attribute :next_cursor, :string

    attribute :status, FinanceSmith.Banking.Types.PlaidItemStatus do
      allow_nil? false
      default :active
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
