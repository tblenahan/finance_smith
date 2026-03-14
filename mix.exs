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
      ]
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
      {:ash_postgres, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:igniter, "~> 0.6", only: [:dev]},
      {:usage_rules, "~> 1.2", only: [:dev]}
    ]
  end
end
