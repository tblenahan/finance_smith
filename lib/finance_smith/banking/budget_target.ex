defmodule FinanceSmith.Banking.BudgetTarget do
  use Ash.Resource,
    domain: FinanceSmith.Banking,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "budget_targets"
    repo FinanceSmith.Repo
    schema "core"

    references do
      reference :household, on_delete: :delete, index?: true
      reference :meta_category, on_delete: :delete, index?: true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:amount, :period_type, :meta_category_id]
      change FinanceSmith.Banking.BudgetTarget.Changes.SetHouseholdFromActor
    end

    update :update do
      primary? true
      accept [:amount, :period_type]
    end

    read :for_window do
      argument :start_date, :date, allow_nil?: false
      argument :end_date, :date, allow_nil?: false
      prepare FinanceSmith.Banking.BudgetTarget.Preparations.LoadWindowMetrics
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(household_id == ^actor(:household_id))
    end

    policy action(:create) do
      authorize_if expr(not is_nil(^actor(:household_id)))
    end

    policy action_type([:update, :destroy]) do
      authorize_if expr(household_id == ^actor(:household_id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :amount, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :period_type, FinanceSmith.Banking.Types.PeriodType do
      allow_nil? false
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

  calculations do
    calculate :actual_spend,
              :integer,
              expr(
                sum(meta_category.transactions,
                  field: :amount,
                  default: 0,
                  query: [
                    filter:
                      expr(
                        amount > 0 and date >= ^arg(:start_date) and
                          date <= ^arg(:end_date) and
                          is_nil(account.duplicate_of_id)
                      )
                  ]
                )
              ) do
      argument :start_date, :date, allow_nil?: false
      argument :end_date, :date, allow_nil?: false
    end

    calculate :scaled_target,
              :integer,
              FinanceSmith.Banking.BudgetTarget.Calculations.ScaledTarget do
      argument :start_date, :date, allow_nil?: false
      argument :end_date, :date, allow_nil?: false
    end

    calculate :projected_spend,
              :integer,
              FinanceSmith.Banking.BudgetTarget.Calculations.ProjectedSpend do
      argument :start_date, :date, allow_nil?: false
      argument :end_date, :date, allow_nil?: false
    end
  end

  identities do
    identity :unique_period_per_meta_category, [:meta_category_id, :period_type]
  end
end
