import Config

secret_key_base =
  System.get_env("SECRET_KEY_BASE_TEST") || System.get_env("SECRET_KEY_BASE") ||
    raise """
    SECRET_KEY_BASE_TEST (or SECRET_KEY_BASE) environment variable is not set.
    Add SECRET_KEY_BASE_TEST to your .env. Generate with mix phx.gen.secret, or:
      elixir -e ':crypto.strong_rand_bytes(64) |> Base.encode64() |> IO.puts()'
    """

config :finance_smith, FinanceSmithWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: secret_key_base,
  server: false

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
  key_id: System.get_env("B2_KEY_ID", ""),
  app_key: System.get_env("B2_APP_KEY", ""),
  bucket_name: System.get_env("B2_BUCKET_NAME", "")

test_cloak_key =
  System.get_env("CLOAK_KEY_TEST") || System.get_env("CLOAK_KEY") ||
    raise """
    CLOAK_KEY_TEST (or CLOAK_KEY) environment variable is not set.
    Add CLOAK_KEY_TEST to your .env file. Generate a key with:
      32 |> :crypto.strong_rand_bytes() |> Base.encode64()
    """

config :finance_smith, FinanceSmith.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1", key: Base.decode64!(test_cloak_key), iv_length: 12
    }
  ]
