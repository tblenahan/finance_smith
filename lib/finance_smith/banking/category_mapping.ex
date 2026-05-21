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
      reference :household, on_delete: :delete, index?: true
      reference :meta_category, on_delete: :delete, index?: true
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(household_id == ^actor(:household_id))
    end

    # All writes are system-only. Sync workers and seed scripts call with
    # authorize?: false, bypassing policies entirely.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :source_category_token, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :unreviewed, :boolean do
      allow_nil? false
      default true
      public? true
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
  end

  identities do
    identity :unique_mapping_per_household, [:household_id, :provider, :source_category_token]
  end
end
