defmodule Vibe.Repo.Migrations.CreateAgentBridgeConnections do
  use Ecto.Migration

  def change do
    create table(:agent_bridge_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :token_hash, :string, null: false
      add :device_label, :string
      add :last_seen_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps()
    end

    create unique_index(:agent_bridge_connections, [:token_hash])
    create index(:agent_bridge_connections, [:user_id])
  end
end
