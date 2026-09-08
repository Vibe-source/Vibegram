defmodule Vibe.Repo.Migrations.CreateMlsKeyPackages do
  use Ecto.Migration

  def change do
    create table(:mls_key_packages, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :device_id, :string, null: false
      add :key_package, :binary, null: false
      add :claimed_at, :utc_datetime

      timestamps()
    end

    create index(:mls_key_packages, [:user_id, :claimed_at])
  end
end
