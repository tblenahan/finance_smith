defmodule FinanceSmith.Banking.Transaction do
  use Ash.Resource,
    domain: FinanceSmith.Banking,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "transactions"
    repo FinanceSmith.Repo
    schema "core"

    references do
      reference :account, on_delete: :delete, index?: true
      reference :meta_category, on_delete: :nilify, index?: true
    end

    custom_indexes do
      index [:account_id, :date], name: "transactions_account_id_date_index"

      index [:account_id],
        where: "is_pending = true",
        name: "transactions_pending_by_account_index"

      index [:metadata], using: "GIN", name: "transactions_metadata_gin_index"

      index [:date, :amount], name: "transactions_date_amount_index"

      index [:account_id, :personal_finance_category],
        name: "transactions_account_id_category_index"

      index [:account_id, :personal_finance_category],
        where: "amount > 0",
        name: "transactions_outflow_by_account_category_index"
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    read :for_chart do
      description """
      Returns lightweight transaction rows for chart rendering. No pagination —
      caller is responsible for scoping via arguments.

      `date_from` is optional. When omitted (the \"All\" timeframe), the query
      returns all transactions in scope up to the hard row cap of 10,000, sorted
      oldest-first. The chart then spans from the earliest returned transaction
      date to today, giving a view of the full transaction history within the cap.
      """

      argument :date_from, :date, allow_nil?: true
      argument :plaid_item_id, :uuid, allow_nil?: true
      argument :user_id, :uuid, allow_nil?: true

      prepare build(
                select: [:date, :amount, :personal_finance_category],
                sort: [date: :asc],
                limit: 10_000
              )

      filter expr(is_nil(^arg(:date_from)) or date >= ^arg(:date_from))
      filter expr(is_nil(^arg(:plaid_item_id)) or account.plaid_item_id == ^arg(:plaid_item_id))
      filter expr(is_nil(^arg(:user_id)) or account.plaid_item.user_id == ^arg(:user_id))
    end

    read :categories do
      argument :account_id, :uuid, allow_nil?: true
      argument :plaid_item_id, :uuid, allow_nil?: true
      argument :user_id, :uuid, allow_nil?: true

      prepare build(
                select: [:personal_finance_category],
                distinct: [:personal_finance_category],
                sort: [personal_finance_category: :asc]
              )

      filter expr(not is_nil(personal_finance_category))
      filter expr(is_nil(^arg(:account_id)) or account_id == ^arg(:account_id))
      filter expr(is_nil(^arg(:plaid_item_id)) or account.plaid_item_id == ^arg(:plaid_item_id))
      filter expr(is_nil(^arg(:user_id)) or account.plaid_item.user_id == ^arg(:user_id))
    end

    read :list do
      argument :account_id, :uuid, allow_nil?: true
      argument :plaid_item_id, :uuid, allow_nil?: true
      argument :user_id, :uuid, allow_nil?: true
      argument :date_from, :date, allow_nil?: true
      argument :date_to, :date, allow_nil?: true
      argument :meta_category_id, :uuid, allow_nil?: true
      argument :search, :string, allow_nil?: true

      pagination keyset?: true,
                 countable: true,
                 default_limit: 25,
                 max_page_size: 100,
                 required?: false

      prepare build(
                sort: [date: :desc, inserted_at: :desc],
                load: [:account, :meta_category]
              )

      filter expr(is_nil(^arg(:account_id)) or account_id == ^arg(:account_id))
      filter expr(is_nil(^arg(:plaid_item_id)) or account.plaid_item_id == ^arg(:plaid_item_id))
      filter expr(is_nil(^arg(:user_id)) or account.plaid_item.user_id == ^arg(:user_id))

      filter expr(is_nil(^arg(:date_from)) or date >= ^arg(:date_from))

      filter expr(is_nil(^arg(:date_to)) or date <= ^arg(:date_to))

      filter expr(is_nil(^arg(:meta_category_id)) or meta_category_id == ^arg(:meta_category_id))

      filter expr(
               is_nil(^arg(:search)) or
                 fragment("? ILIKE '%' || ? || '%'", merchant_name, ^arg(:search))
             )
    end
  end

  policies do
    policy action_type(:read) do
      # User.household_id is allow_nil?: false — every actor always has a
      # household_id. The not-is_nil guard is kept for defensive clarity.
      authorize_if expr(
                     account.plaid_item.user_id == ^actor(:id) or
                       (not is_nil(^actor(:household_id)) and
                          account.plaid_item.user.household_id == ^actor(:household_id))
                   )
    end

    # Writes are system-only. TransactionProcessor / SyncWorker call with
    # authorize?: false and bypass policies entirely. This stanza makes the
    # default-deny posture explicit for any user-facing caller.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  pub_sub do
    module FinanceSmithWeb.Endpoint
    prefix "transaction"

    publish_all :create, ["created"]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :plaid_transaction_id, :string do
      allow_nil? false
      public? true
    end

    attribute :amount, :integer, public?: true

    attribute :date, :date do
      allow_nil? false
      public? true
    end

    attribute :merchant_name, :string, public?: true

    attribute :personal_finance_category, :string, public?: true

    attribute :website, :string, public?: true

    attribute :is_pending, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :account, FinanceSmith.Banking.Account do
      allow_nil? false
      public? true
    end

    belongs_to :meta_category, FinanceSmith.Banking.MetaCategory do
      public? true
    end
  end

  identities do
    identity :unique_plaid_id, [:plaid_transaction_id]
  end
end
