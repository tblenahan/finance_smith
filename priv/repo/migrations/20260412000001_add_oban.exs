defmodule FinanceSmith.Repo.Migrations.AddOban do
  use Ecto.Migration

  def up, do: Oban.Migration.up(prefix: "machine")
  def down, do: Oban.Migration.down(prefix: "machine")
end
