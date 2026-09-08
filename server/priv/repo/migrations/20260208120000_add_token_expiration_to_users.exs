defmodule Vibe.Repo.Migrations.AddTokenExpirationToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :token_expires_at, :utc_datetime, null: true
    end

    create index(:users, [:token_expires_at])
  end
end
