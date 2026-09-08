defmodule Vibe.Repo.Migrations.CreatePlatformConnections do
  use Ecto.Migration

  def change do
    create table(:platform_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :external_account_id, :string
      add :external_account_login, :string
      add :display_name, :string
      add :scopes, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "active"
      add :access_token_encrypted, :text
      add :refresh_token_encrypted, :text
      add :token_expires_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}
      add :last_used_at, :utc_datetime
      add :last_error, :text

      timestamps()
    end

    create unique_index(
             :platform_connections,
             [:user_id, :provider, :external_account_id],
             name: :platform_connections_user_provider_account_index
           )

    create index(:platform_connections, [:user_id, :provider, :status])
    create index(:platform_connections, [:status, :inserted_at])

    create table(:connection_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :connection_id,
          references(:platform_connections, type: :binary_id, on_delete: :delete_all),
          null: false
      add :grantee_type, :string, null: false
      add :grantee_id, :string, null: false
      add :capabilities, {:array, :string}, null: false, default: []
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(
             :connection_grants,
             [:connection_id, :grantee_type, :grantee_id],
             name: :connection_grants_connection_grantee_index
           )

    create index(:connection_grants, [:grantee_type, :grantee_id, :enabled])

    create table(:connection_audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :connection_id,
          references(:platform_connections, type: :binary_id, on_delete: :delete_all)
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :actor_type, :string, null: false
      add :actor_id, :string
      add :action, :string, null: false
      add :capability, :string
      add :detail, :map, null: false, default: %{}

      timestamps(updated_at: false)
    end

    create index(:connection_audit_events, [:user_id, :inserted_at])
    create index(:connection_audit_events, [:connection_id, :inserted_at])
    create index(:connection_audit_events, [:action, :inserted_at])
  end
end
