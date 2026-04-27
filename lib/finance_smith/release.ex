defmodule FinanceSmith.Release do
  @moduledoc """
  Migration entrypoints for the production release.

  `mix ecto.migrate` is unavailable inside a compiled release because Mix is not
  packaged. This module provides equivalent functionality via `Ecto.Migrator` and
  is invoked from `entrypoint.sh` before the supervision tree starts:

      bin/finance_smith eval 'FinanceSmith.Release.migrate()'

  The eval command boots only the repo (not the full app), runs all pending migrations,
  and exits. The entrypoint then exec-s into `bin/finance_smith start`.
  """

  @app :finance_smith

  @doc "Run all pending up-migrations for every configured Ecto repo."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Roll back a specific migration version for `repo`."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
  defp load_app, do: Application.load(@app)
end
