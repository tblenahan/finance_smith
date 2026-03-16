defmodule FinanceSmith.MixProject do
  use Mix.Project

  def project do
    [
      app: :finance_smith,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
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
      extra_applications: [:logger],
      mod: {FinanceSmith.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:ash_postgres, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:ash_cloak, "~> 0.2.0"},
      {:cloak, "~> 1.1"},
      {:plaid, "~> 3.0", hex: :plaid_elixir},
      {:req, "~> 0.5"},
      {:oban, "~> 2.18"},
      {:igniter, "~> 0.6", only: [:dev]},
      {:usage_rules, "~> 1.2", only: [:dev]}
    ]
  end

  defp aliases() do
    [test: ["ash.setup --quiet", "test"], setup: "ash.setup"]
  end

  defp elixirc_paths(:test),
    do: elixirc_paths(:dev) ++ ["test/support"]

  defp elixirc_paths(_),
    do: ["lib"]
end
