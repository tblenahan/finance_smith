import Config

config :finance_smith,
  ecto_repos: [FinanceSmith.Repo],
  ash_domains: [FinanceSmith.Identity, FinanceSmith.Banking]

config :finance_smith, FinanceSmithWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost", path: "/", port: 4000],
  render_errors: [formats: [html: {FinanceSmithWeb.ErrorHTML, :html}]],
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
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ],
  queues: [data_lake: 5]

config :plaid,
  root_uri: "https://sandbox.plaid.com/",
  client_id: System.get_env("PLAID_CLIENT_ID"),
  secret: System.get_env("PLAID_SECRET"),
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
