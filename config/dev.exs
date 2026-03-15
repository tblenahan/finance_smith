import Config

config :finance_smith, FinanceSmith.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "finance_smith_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :ash, policies: [show_policy_breakdowns?: true]
