defmodule Vibe.Repo.Migrations.CompleteSettingsPreferences do
  use Ecto.Migration

  def change do
    create_if_not_exists(index(:device_sessions, [:user_id, :last_used_at]))
    create_if_not_exists(index(:account_devices, [:user_id, :last_seen_at]))
  end
end