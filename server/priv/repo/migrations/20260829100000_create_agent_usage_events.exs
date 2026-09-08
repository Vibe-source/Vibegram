defmodule Vibe.Repo.Migrations.CreateAgentUsageEvents do
  use Ecto.Migration

  def change do
    create table(:agent_usage_events, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :owner_user_id, :binary_id, null: false
      add :agent_id, :binary_id, null: false
      add :run_id, :binary_id
      add :day, :date, null: false
      add :source, :string
      add :input_tokens, :integer, default: 0, null: false
      add :output_tokens, :integer, default: 0, null: false
      add :sandbox_seconds, :integer, default: 0, null: false
      add :cost_cents, :integer, default: 0, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:agent_usage_events, [:run_id])
    create index(:agent_usage_events, [:owner_user_id, :day])
    create index(:agent_usage_events, [:agent_id, :day])
  end
end
