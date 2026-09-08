defmodule Vibe.Repo.Migrations.AddTokenIssuedAtToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :token_issued_at, :utc_datetime
    end

    execute("UPDATE users SET token_issued_at = inserted_at WHERE token_issued_at IS NULL")
  end

  def down do
    alter table(:users) do
      remove :token_issued_at
    end
  end
end
