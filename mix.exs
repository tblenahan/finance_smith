defmodule FinanceSmith.MixProject do
  use Mix.Project

  def project do
    [
      app: :finance_smith,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      usage_rules: [
        file: ".cursorrules",
        usage_rules: :all
      ],
      consolidate_protocols: Mix.env() != :dev,
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :logger_backends, :crypto],
      mod: {FinanceSmith.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:decimal, "~> 3.0", override: true},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:lazy_html, ">= 0.0.0", only: :test},
      {:mox, "~> 1.0", only: :test},
      {:simple_sat, "~> 0.1"},
      {:ash_postgres, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:ash_cloak, "~> 0.2.0"},
      {:cloak, "~> 1.1"},
      {:plaid, "~> 3.0", hex: :plaid_elixir},
      {:req, "~> 0.5"},
      {:oban, "~> 2.18"},
      {:igniter, "~> 0.6", only: [:dev]},
      {:usage_rules, "~> 1.2", only: [:dev]},
      # MFA & auth
      {:nimble_totp, "~> 1.0"},
      {:eqrcode, "~> 0.2"},
      {:bcrypt_elixir, "~> 3.0"},
      # Phoenix web layer (Phase 2+)
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:ash_phoenix, "~> 2.0"},
      {:petal_components, "~> 2.0"},
      {:heroicons, "~> 0.5"},
      {:bandit, "~> 1.0"},
      {:remote_ip, "~> 1.2"},
      {:jason, "~> 1.0"},
      {:dns_cluster, "~> 0.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.24"},
      {:logger_file_backend, "~> 0.0.13"},
      {:logger_backends, "~> 1.0"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev}
    ]
  end

  defp aliases() do
    [
      test: ["ash.setup --quiet", "test"],
      setup: "ash.setup",
      audit: "deps.audit",
      "assets.deploy": ["cmd npm run --prefix assets build:css", "esbuild default --minify"]
    ]
  end

  defp elixirc_paths(:test),
    do: elixirc_paths(:dev) ++ ["test/support"]

  defp elixirc_paths(_),
    do: ["lib"]
end
