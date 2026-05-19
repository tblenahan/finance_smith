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
      # Cascade-delete all meta-categories when the household is removed.
      reference :household, on_delete: :delete, index?: true
      # Preserve audit trail when the creating user is deleted.
      reference :created_by, on_delete: :nilify, index?: true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name]

      # household_id and created_by_id are derived from the actor — not accepted
      # from the caller — to prevent cross-household ownership forgery.
      change FinanceSmith.Banking.Changes.SetActorContext
    end

    update :rename do
      accept [:name]
    end
  end

  policies do
    # All household members may read their household's meta-categories.
    policy action_type(:read) do
      authorize_if expr(household_id == ^actor(:household_id))
    end

    # Any authenticated user may create a meta-category; SetActorContext binds
    # it to their household automatically.
    policy action_type(:create) do
      authorize_if actor_present()
    end

    # Only household members may rename or delete their household's meta-categories.
    policy action_type([:update, :destroy]) do
      authorize_if expr(household_id == ^actor(:household_id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :household, FinanceSmith.Identity.Household do
      allow_nil? false
      public? true
    end

    belongs_to :created_by, FinanceSmith.Identity.User do
      allow_nil? true
      public? true
    end

    has_many :category_mappings, FinanceSmith.Banking.CategoryMapping do
      public? true
    end
  end

  identities do
    # Household-scoped uniqueness: two meta-categories in the same household
    # cannot share a name.
    identity :unique_household_name, [:household_id, :name]
  end
end
