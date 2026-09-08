defmodule VibeAgents.Repo.Migrations.CreateAgentComputers do
  use Ecto.Migration

  def change do
    create table(:agent_computers, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, :binary_id, null: false
      add :sandbox_id, :string
      add :status, :string, null: false, default: "none"
      add :last_used_at, :utc_datetime
      add :image, :string

      timestamps()
    end

    create unique_index(:agent_computers, [:agent_id])
  end
end
