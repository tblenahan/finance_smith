defmodule FinanceSmith.Identity.Household do
  use Ash.Resource,
    domain: FinanceSmith.Identity,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "households"
    repo FinanceSmith.Repo
  end

  actions do
    defaults [:read, :destroy, update: :*]

    create :create do
      primary? true
      accept [:name]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :users, FinanceSmith.Identity.User
  end
end
