import Config

config :finance_smith, FinanceSmith.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "finance_smith_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :ash, policies: [show_policy_breakdowns?: true]

config :finance_smith, FinanceSmith.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!("7LdKH1xblhw4ajVe5JAYWRiQ4g32jOGRQvU2sJO5nyg="),
      iv_length: 12
    }
  ]
