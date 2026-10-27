defmodule Pack.Repo.Migrations.CreateWorlds do
  use Ecto.Migration

  def change, do: create(table(:worlds))
end
