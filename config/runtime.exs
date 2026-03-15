import Config

if config_env() == :prod do
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
        tag: "AES.GCM.V1",
        key: Base.decode64!(cloak_key),
        iv_length: 12
      }
    ]
end
