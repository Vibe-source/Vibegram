defmodule VibeAgents.Repo.Migrations.CreateAgentUsageLedger do
  use Ecto.Migration

  def change do
    create table(:agent_usage_ledger, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :agent_id, :binary_id, null: false
      add :run_id, :binary_id
      add :day, :date, null: false
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cost_cents, :integer, null: false, default: 0

      timestamps(updated_at: false)
    end

    create index(:agent_usage_ledger, [:agent_id, :day])
  end
end
