import Config

secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    raise """
    SECRET_KEY_BASE environment variable is not set.
    Add it to your .env. Generate with mix phx.gen.secret, or (bootstrap) with:
      elixir -e ':crypto.strong_rand_bytes(64) |> Base.encode64() |> IO.puts()'
    """

config :finance_smith, FinanceSmithWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  static_cache_control: "max-age=0, private, must-revalidate",
  watchers: [
    {"npm", ["run", "watch:css", cd: Path.expand("../assets", __DIR__)]},
    {:esbuild, {Esbuild, :install_and_run, [:default, ~w(--watch)]}}
  ],
  secret_key_base: secret_key_base

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
  bucket_name: System.get_env("B2_BUCKET_NAME", "")

cloak_key =
  System.get_env("CLOAK_KEY") ||
    raise """
    CLOAK_KEY environment variable is not set.
    Add it to your .env file. Generate a key with:
      32 |> :crypto.strong_rand_bytes() |> Base.encode64()
    """

config :finance_smith, FinanceSmith.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12
    }
  ]
