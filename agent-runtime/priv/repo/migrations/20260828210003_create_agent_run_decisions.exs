defmodule VibeAgents.Repo.Migrations.CreateAgentRunDecisions do
  use Ecto.Migration

  def change do
    create table(:agent_run_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :run_id, references(:agent_runs, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :request, :map, null: false, default: %{}
      add :outcome, :string
      add :answer, :map
      add :actor_user_id, :binary_id
      add :expires_at, :utc_datetime
      add :resolved_at, :utc_datetime

      timestamps()
    end

    create index(:agent_run_decisions, [:run_id])
    create index(:agent_run_decisions, [:status])
  end
end
