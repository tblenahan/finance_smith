defmodule FinanceSmith.Identity.User do
  use Ash.Resource,
    domain: FinanceSmith.Identity,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak]

  postgres do
    table "users"
    repo FinanceSmith.Repo

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
      end

      argument :household_name, :string do
        default "My Household"
      end

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

      change FinanceSmith.Identity.User.Changes.VerifyMfaLogin
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

  identities do
    identity :unique_email, [:email]
  end
end
