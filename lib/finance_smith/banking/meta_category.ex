defmodule FinanceSmith.Banking.MetaCategory do
  use Ash.Resource,
    domain: FinanceSmith.Banking,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "meta_categories"
    repo FinanceSmith.Repo
    schema "core"

    references do
      reference :household, on_delete: :delete, index?: true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name]
      change FinanceSmith.Banking.MetaCategory.Changes.SetHouseholdFromActor
    end

    # System workers (Oban jobs, seed scripts) call this action with
    # authorize?: false. household_id is accepted directly instead of
    # being derived from an actor so no actor context is needed.
    create :create_system do
      accept [:name, :household_id]
    end

    update :update do
      primary? true
      accept [:name]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(household_id == ^actor(:household_id))
    end

    policy action(:create) do
      authorize_if expr(not is_nil(^actor(:household_id)))
    end

    # Household members may rename or delete their own meta-categories.
    policy action_type([:update, :destroy]) do
      authorize_if expr(household_id == ^actor(:household_id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :household, FinanceSmith.Identity.Household do
      allow_nil? false
      public? true
    end

    has_many :category_mappings, FinanceSmith.Banking.CategoryMapping
    has_many :transactions, FinanceSmith.Banking.Transaction
    has_many :budget_targets, FinanceSmith.Banking.BudgetTarget
  end

  identities do
    identity :unique_name_per_household, [:household_id, :name]
  end
end
