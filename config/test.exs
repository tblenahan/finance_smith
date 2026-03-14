import Config

config :finance_smith, FinanceSmith.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "finance_smith_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true
