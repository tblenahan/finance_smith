defmodule FinanceSmith.Repo.Migrations.CreateSchemas do
  use Ecto.Migration

  def up do
    execute "CREATE SCHEMA IF NOT EXISTS core"
    execute "CREATE SCHEMA IF NOT EXISTS machine"
    execute "CREATE SCHEMA IF NOT EXISTS analytics"
  end

  def down do
    execute "DROP SCHEMA IF EXISTS analytics CASCADE"
    execute "DROP SCHEMA IF EXISTS machine CASCADE"
    execute "DROP SCHEMA IF EXISTS core CASCADE"
  end
end
