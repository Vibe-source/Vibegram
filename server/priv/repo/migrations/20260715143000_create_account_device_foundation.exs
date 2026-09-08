defmodule Vibe.Repo.Migrations.CreateAccountDeviceFoundation do
  use Ecto.Migration

  def change do
    create table(:account_devices, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :device_identifier, :string, null: false
      add :name, :string, null: false
      add :platform, :string, null: false
      add :public_key, :text
      add :push_token_bundle, :map, null: false, default: %{}
      add :last_seen_at, :utc_datetime
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:account_devices, [:user_id, :device_identifier])
    create index(:account_devices, [:user_id, :revoked_at])

    create table(:device_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :account_device_id,
          references(:account_devices, type: :uuid, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:device_sessions, [:token_hash])
    create index(:device_sessions, [:user_id, :revoked_at])
    create index(:device_sessions, [:account_device_id])

    create table(:device_link_requests, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :code_hash, :binary, null: false
      add :requester_device_identifier, :string, null: false
      add :requester_name, :string, null: false
      add :requester_platform, :string, null: false
      add :requester_public_key, :text, null: false
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all)
      add :wrapped_key_envelope, :text
      add :expires_at, :utc_datetime, null: false
      add :approved_at, :utc_datetime
      add :consumed_at, :utc_datetime
      add :rejected_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:device_link_requests, [:code_hash])
    create index(:device_link_requests, [:user_id, :expires_at])

    create table(:notification_preferences, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :preferences, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:notification_preferences, [:user_id])
  end
end
