defmodule Vibe.Repo.Migrations.CreateAdminUsers do
  use Ecto.Migration

  def change do
    create table(:admin_users, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :granted_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :granted_reason, :text
      add :revoked_at, :utc_datetime
      add :revoked_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps()
    end

    # A revoked grant stays for audit, so uniqueness covers only the live one.
    create unique_index(:admin_users, [:user_id],
             where: "revoked_at IS NULL",
             name: :admin_users_active_user_index
           )

    create index(:admin_users, [:role, :revoked_at])
    create index(:admin_users, [:granted_by_user_id])
  end
end
