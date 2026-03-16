import Config

config :finance_smith, FinanceSmith.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: System.get_env("POSTGRES_DB", "finance_smith_dev"),
  show_sensitive_data_on_connection_error: true,
  pool_size: String.to_integer(System.get_env("POSTGRES_POOL_SIZE", "10"))

config :ash, policies: [show_policy_breakdowns?: true]

config :finance_smith, :b2,
  key_id: System.get_env("B2_KEY_ID", ""),
  app_key: System.get_env("B2_APP_KEY", ""),
  bucket_name: System.get_env("B2_BUCKET_NAME", ""),
  webhook_signing_secret: System.get_env("B2_WEBHOOK_SIGNING_SECRET", "")

config :finance_smith, FinanceSmith.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!("7LdKH1xblhw4ajVe5JAYWRiQ4g32jOGRQvU2sJO5nyg="),
      iv_length: 12
    }
  ]
