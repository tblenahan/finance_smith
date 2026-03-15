defmodule FinanceSmith.Identity.User do
  use Ash.Resource,
    domain: FinanceSmith.Identity,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo FinanceSmith.Repo

    references do
      reference :household, on_delete: :restrict, index?: true
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :email, :string do
      allow_nil? false
    end

    attribute :password_hash, :string do
      allow_nil? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :household, FinanceSmith.Identity.Household do
      allow_nil? false
    end

    has_many :plaid_items, FinanceSmith.Banking.PlaidItem
  end

  identities do
    identity :unique_email, [:email]
  end
end
