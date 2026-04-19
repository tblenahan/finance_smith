defmodule FinanceSmith.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    maybe_add_logger_file_backend()
    maybe_prepare_log_dir()

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

  defp maybe_prepare_log_dir do
    if has_file_backend?() do
      log_dir = Application.get_env(:finance_smith, :log_dir, "logs")

      case File.mkdir_p(log_dir) do
        :ok ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("Could not create log directory #{log_dir}: #{inspect(reason)}")
      end
    end
  end

  defp has_file_backend? do
    Application.get_env(:finance_smith, :enable_logger_file_backend, true)
  end

  defp maybe_add_logger_file_backend do
    if has_file_backend?() do
      case LoggerBackends.add({LoggerFileBackend, :error_log}) do
        {:ok, _} ->
          :ok

        {:error, :already_present} ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("Could not start LoggerFileBackend :error_log: #{inspect(reason)}")
      end
    end
  end
end
