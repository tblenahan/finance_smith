defmodule FinanceSmith.Banking.Transaction do
  use Ash.Resource,
    domain: FinanceSmith.Banking,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "transactions"
    repo FinanceSmith.Repo

    references do
      reference :account, on_delete: :delete, index?: true
    end

    custom_indexes do
      index [:account_id, :date], name: "transactions_account_id_date_index"
      index [:account_id], where: "is_pending = true", name: "transactions_pending_by_account_index"
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :plaid_transaction_id, :string do
      allow_nil? false
    end

    attribute :amount, :integer

    attribute :date, :date do
      allow_nil? false
    end

    attribute :merchant_name, :string

    attribute :category, {:array, :string}

    attribute :is_pending, :boolean do
      allow_nil? false
      default false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :account, FinanceSmith.Banking.Account do
      allow_nil? false
    end
  end

  identities do
    identity :unique_plaid_transaction_id, [:plaid_transaction_id, :date]
  end
end
