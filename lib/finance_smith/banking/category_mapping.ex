defmodule FinanceSmith.Banking.CategoryMapping do
  use Ash.Resource,
    domain: FinanceSmith.Banking,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "category_mappings"
    repo FinanceSmith.Repo
    schema "core"

    references do
      # Cascade-delete all mappings when the household is removed.
      reference :household, on_delete: :delete, index?: true
      # Cascade-delete mappings when the target meta-category is deleted,
      # so transactions fall back to "uncategorized" without orphaned rows.
      reference :meta_category, on_delete: :delete, index?: true
      # Preserve audit trail when the creating user is deleted.
      reference :created_by, on_delete: :nilify, index?: true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      # Re-submitting the same plaid_category updates the target meta-category
      # rather than raising a uniqueness conflict.
      upsert? true
      upsert_identity :unique_household_plaid_category
      upsert_fields [:meta_category_id, :created_by_id]

      accept [:plaid_category, :meta_category_id]

      # household_id and created_by_id are derived from the actor — not accepted
      # from the caller — to prevent cross-household ownership forgery.
      change FinanceSmith.Banking.Changes.SetActorContext
    end
  end

  policies do
    # All household members may read their household's mappings. These are also
    # queried internally by Transaction calculations — the actor's household_id
    # scopes the result set correctly.
    policy action_type(:read) do
      authorize_if expr(household_id == ^actor(:household_id))
    end

    # Any authenticated user may upsert a mapping; SetActorContext binds it to
    # their household automatically.
    policy action_type(:create) do
      authorize_if actor_present()
    end

    # Only household members may delete their household's mappings.
    policy action_type(:destroy) do
      authorize_if expr(household_id == ^actor(:household_id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :plaid_category, :string do
      allow_nil? false
      public? true
      # Stores the raw Plaid `personal_finance_category.detailed` value,
      # e.g. "FOOD_AND_DRINK_RESTAURANTS".
      constraints min_length: 1, max_length: 255
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :household, FinanceSmith.Identity.Household do
      allow_nil? false
      public? true
    end

    belongs_to :meta_category, FinanceSmith.Banking.MetaCategory do
      allow_nil? false
      public? true
    end

    belongs_to :created_by, FinanceSmith.Identity.User do
      allow_nil? true
      public? true
    end
  end

  identities do
    # One mapping per Plaid PFC string per household. This is what the upsert
    # action targets so re-mapping a category is an update, not a conflict.
    identity :unique_household_plaid_category, [:household_id, :plaid_category]
  end
end
