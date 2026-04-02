defmodule FinanceSmith.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FinanceSmith.Repo,
      FinanceSmith.Vault,
      {Phoenix.PubSub, name: FinanceSmith.PubSub},
      FinanceSmith.DataLake.B2.AuthServer,
      {Oban, oban_config()},
      FinanceSmithWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: FinanceSmith.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp oban_config do
    Application.fetch_env!(:finance_smith, Oban)
  end
end
