defmodule FinanceSmith.Identity.Household do
  use Ash.Resource,
    domain: FinanceSmith.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "households"
    repo FinanceSmith.Repo
    schema "core"
  end

  actions do
    defaults [:read, :destroy, update: :*]

    create :create do
      primary? true
      accept [:name]
    end
  end

  policies do
    # A user may only read their own household.
    policy action_type(:read) do
      authorize_if expr(id == ^actor(:household_id))
    end

    # Household records are created and managed by internal registration logic
    # (authorize?: false). User-facing write attempts are always denied.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
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

  calculations do
    calculate :total_net_worth, :integer, expr(total_assets - total_liabilities)
  end

  aggregates do
    sum :total_assets, [:users, :plaid_items, :accounts], :current_balance do
      filter expr(type not in ["credit", "loan"])
      default 0
    end

    sum :total_liabilities, [:users, :plaid_items, :accounts], :current_balance do
      filter expr(type in ["credit", "loan"])
      default 0
    end

    sum :outflow_30d, [:users, :plaid_items, :accounts, :transactions], :amount do
      filter expr(amount > 0 and date >= ago(30, :day))
      default 0
    end

    sum :inflow_30d, [:users, :plaid_items, :accounts, :transactions], :amount do
      filter expr(amount < 0 and date >= ago(30, :day))
      default 0
    end

    count :active_streams_count, [:users, :plaid_items] do
      filter expr(status == :active)
    end
  end
end
