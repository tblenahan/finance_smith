import Config

# Load project `.env` before imported configs read `System.get_env/1`.
# Includes prod for local / bootstrap runs; real deploys inject env directly and need not ship `.env`.
# The RELEASE_ROOT guard prevents sourcing .env during a release build (Elixir releases export that var).
# Variables already set in the process environment are not overwritten.
if config_env() in [:dev, :test, :prod] and is_nil(System.get_env("RELEASE_ROOT")) do
  dotenv_path = Path.expand("../.env", __DIR__)

  if File.exists?(dotenv_path) do
    dotenv_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.each(fn line ->
      line = String.trim(line)

      cond do
        line == "" or String.starts_with?(line, "#") ->
          :ok

        true ->
          case String.split(line, "=", parts: 2) do
            [key, val] ->
              key = String.trim(key)
              val = String.trim(val)

              if System.get_env(key) == nil do
                System.put_env(key, val)
              end

            _ ->
              :ok
          end
      end
    end)
  end
end

config :finance_smith,
  ecto_repos: [FinanceSmith.Repo],
  ash_domains: [FinanceSmith.Identity, FinanceSmith.Banking]

config :finance_smith, FinanceSmithWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost", path: "/", port: 4000],
  render_errors: [formats: [html: FinanceSmithWeb.ErrorHTML]],
  pubsub_server: FinanceSmith.PubSub,
  live_view: [signing_salt: "finance_smith_live_view"]

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  known_types: [
    AshPostgres.Timestamptz,
    AshPostgres.TimestamptzUsec,
    FinanceSmith.Banking.Types.PlaidItemStatus,
    FinanceSmith.Banking.Types.AccountStatus
  ]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :finance_smith, Oban,
  repo: FinanceSmith.Repo,
  prefix: "machine",
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/30 * * * *", FinanceSmith.DataLake.SyncScheduler}
     ]}
  ],
  queues: [data_lake: 5]

config :logger, :error_log,
  level: :warning,
  max_bytes: 10_000_000,
  keep: 7,
  metadata: [:request_id, :module]

config :plaid,
  root_uri: "https://sandbox.plaid.com/",
  client_id: System.get_env("PLAID_CLIENT_ID"),
  secret: System.get_env("SANDBOX_PLAID_SECRET"),
  # Extend recv_timeout for endpoints that trigger real-time institution
  # requests (e.g. accounts/balance/get can take up to 30s).
  http_options: [recv_timeout: 30_000]

config :esbuild,
  version: "0.24.0",
  default: [
    # `cd` is project `assets/`; outdir must be relative to that (Phoenix serves `priv/static/assets`).
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

import_config "#{config_env()}.exs"
