import Config

config :finance_smith, FinanceSmith.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database:
    System.get_env(
      "POSTGRES_TEST_DB",
      "finance_smith_test#{System.get_env("MIX_TEST_PARTITION")}"
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: String.to_integer(System.get_env("POSTGRES_POOL_SIZE", "10"))

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

config :finance_smith, Oban, testing: :inline

config :finance_smith, :b2,
  key_id: System.get_env("B2_KEY_ID", "test-key-id"),
  app_key: System.get_env("B2_APP_KEY", "test-app-key"),
  bucket_name: System.get_env("B2_BUCKET_NAME", "test-bucket"),
  webhook_signing_secret:
    System.get_env("B2_WEBHOOK_SIGNING_SECRET", "test-signing-secret-32-chars-long")

config :finance_smith, FinanceSmith.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!("7LdKH1xblhw4ajVe5JAYWRiQ4g32jOGRQvU2sJO5nyg="),
      iv_length: 12
    }
  ]
