defmodule FinanceSmith.Identity.User do
  use Ash.Resource,
    domain: FinanceSmith.Identity,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "users"
    repo FinanceSmith.Repo
    schema "core"

    references do
      reference :household, on_delete: :restrict, index?: true
    end
  end

  cloak do
    vault(FinanceSmith.Vault)
    attributes([:mfa_secret, :recovery_codes])
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    create :register do
      accept [:email]

      argument :password, :string do
        allow_nil? false
        constraints min_length: 12
      end

      argument :household_name, :string do
        default "My Household"
      end

      validate FinanceSmith.Identity.User.Validations.PasswordComplexity
      change FinanceSmith.Identity.User.Changes.Register
    end

    read :sign_in do
      argument :email, :string do
        allow_nil? false
      end

      argument :password, :string do
        allow_nil? false
      end

      prepare build(limit: 1)
      filter expr(email == ^arg(:email))
    end

    update :generate_mfa_secret do
      require_atomic? false
      change FinanceSmith.Identity.User.Changes.GenerateMfaSecret
    end

    update :enable_mfa do
      require_atomic? false

      argument :code, :string do
        allow_nil? false
        constraints min_length: 6, max_length: 6
      end

      change FinanceSmith.Identity.User.Changes.EnableMfa
    end

    update :verify_mfa_login do
      require_atomic? false

      argument :code, :string do
        allow_nil? false
      end

      change FinanceSmith.Identity.User.Changes.CheckLockout
      change FinanceSmith.Identity.User.Changes.VerifyMfaLogin
      change FinanceSmith.Identity.User.Changes.TrackAuthFailure
    end

    update :record_failed_login do
      description "Increments failed_auth_attempts and sets locked_until after the threshold."
      require_atomic? false
      change FinanceSmith.Identity.User.Changes.RecordFailedLogin
    end

    update :clear_auth_lockout do
      description "Resets failed_auth_attempts and locked_until on successful login."
      require_atomic? false

      change set_attribute(:failed_auth_attempts, 0)
      change set_attribute(:locked_until, nil)
    end
  end

  policies do
    # Registration and sign-in have no actor — anyone may attempt them.
    bypass action(:register) do
      authorize_if always()
    end

    bypass action(:sign_in) do
      authorize_if always()
    end

    # Lockout management is called internally by verify_sign_in/2 (system context).
    bypass action([:record_failed_login, :clear_auth_lockout]) do
      authorize_if always()
    end

    # A user may only manage their own MFA settings.
    policy action(:generate_mfa_secret) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:enable_mfa) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action(:verify_mfa_login) do
      authorize_if expr(id == ^actor(:id))
    end

    # A user may only read their own record.
    policy action_type(:read) do
      authorize_if expr(id == ^actor(:id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :email, :string do
      allow_nil? false
    end

    attribute :password_hash, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :mfa_enabled, :boolean do
      allow_nil? false
      default false
    end

    attribute :failed_auth_attempts, :integer do
      allow_nil? false
      default 0
    end

    attribute :locked_until, :utc_datetime_usec

    attribute :mfa_secret, :string do
      sensitive? true
    end

    attribute :recovery_codes, :string do
      sensitive? true
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

  calculations do
    calculate :total_net_worth, :integer, expr(total_assets - total_liabilities)
  end

  aggregates do
    sum :total_assets, [:plaid_items, :accounts], :current_balance do
      filter expr(type not in ["credit", "loan"])
      default 0
    end

    sum :total_liabilities, [:plaid_items, :accounts], :current_balance do
      filter expr(type in ["credit", "loan"])
      default 0
    end

    sum :outflow_30d, [:plaid_items, :accounts, :transactions], :amount do
      filter expr(amount > 0 and date >= ago(30, :day))
      default 0
    end

    sum :inflow_30d, [:plaid_items, :accounts, :transactions], :amount do
      filter expr(amount < 0 and date >= ago(30, :day))
      default 0
    end

    count :active_streams_count, [:plaid_items] do
      filter expr(status == :active)
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
