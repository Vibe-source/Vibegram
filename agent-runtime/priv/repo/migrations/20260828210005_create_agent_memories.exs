defmodule VibeAgents.Repo.Migrations.CreateAgentMemories do
  use Ecto.Migration

  def change do
    create table(:agent_memories, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, :binary_id, null: false
      add :key, :string, null: false
      add :value, :text, null: false
      add :created_by_run_id, :binary_id

      timestamps()
    end

    create unique_index(:agent_memories, [:agent_id, :key])
  end
end
