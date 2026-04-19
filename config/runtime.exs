import Config

log_dir = System.get_env("LOG_DIR", "logs")
config :logger, :error_log, path: Path.join(log_dir, "error.log")
config :finance_smith, :log_dir, log_dir

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Generate one with: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"

  config :finance_smith, FinanceSmithWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT") || "4000")],
    url: [scheme: "https", host: host, port: 443],
    force_ssl: [rewrite_on: [:x_forwarded_proto]],
    secret_key_base: secret_key_base

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :finance_smith, FinanceSmith.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      Generate one with: 32 |> :crypto.strong_rand_bytes() |> Base.encode64()
      """

  config :finance_smith, FinanceSmith.Vault,
    ciphers: [
      default: {
        Cloak.Ciphers.AES.GCM,
        tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12
      }
    ]

  plaid_client_id =
    System.get_env("PLAID_CLIENT_ID") ||
      raise("environment variable PLAID_CLIENT_ID is missing.")

  if String.downcase(System.get_env("PLAID_ENV", "production")) == "sandbox" do
    sandbox_secret =
      System.get_env("SANDBOX_PLAID_SECRET") ||
        raise(
          "environment variable SANDBOX_PLAID_SECRET is missing (required when PLAID_ENV=sandbox)."
        )

    config :plaid,
      root_uri: "https://sandbox.plaid.com/",
      client_id: plaid_client_id,
      secret: sandbox_secret
  else
    production_secret =
      System.get_env("PRODUCTION_PLAID_SECRET") ||
        raise("environment variable PRODUCTION_PLAID_SECRET is missing.")

    config :plaid,
      root_uri: "https://production.plaid.com/",
      client_id: plaid_client_id,
      secret: production_secret
  end

  config :finance_smith, :b2,
    key_id:
      System.get_env("B2_KEY_ID") ||
        raise("environment variable B2_KEY_ID is missing."),
    app_key:
      System.get_env("B2_APP_KEY") ||
        raise("environment variable B2_APP_KEY is missing."),
    bucket_name:
      System.get_env("B2_BUCKET_NAME") ||
        raise("environment variable B2_BUCKET_NAME is missing.")
end
