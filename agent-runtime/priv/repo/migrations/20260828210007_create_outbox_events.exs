defmodule VibeAgents.Repo.Migrations.CreateOutboxEvents do
  use Ecto.Migration

  def change do
    create table(:outbox_events, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :run_id, :binary_id, null: false
      add :seq, :integer, null: false
      add :body, :map, null: false, default: %{}
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime
      add :delivered_at, :utc_datetime

      timestamps(updated_at: false)
    end

    create index(:outbox_events, [:delivered_at, :next_attempt_at])
    create index(:outbox_events, [:run_id, :seq])
  end
end
