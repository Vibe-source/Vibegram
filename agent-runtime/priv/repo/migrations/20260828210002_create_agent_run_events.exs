defmodule VibeAgents.Repo.Migrations.CreateAgentRunEvents do
  use Ecto.Migration

  def change do
    create table(:agent_run_events, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :run_id, references(:agent_runs, type: :binary_id, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :kind, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :ts, :bigint, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:agent_run_events, [:run_id, :seq])
  end
end
