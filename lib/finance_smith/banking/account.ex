defmodule FinanceSmith.Banking.Account do
  use Ash.Resource,
    domain: FinanceSmith.Banking,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "accounts"
    repo FinanceSmith.Repo

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

  identities do
    identity :unique_plaid_account_id, [:plaid_account_id]
  end
end
