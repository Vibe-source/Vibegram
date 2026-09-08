defmodule Vibe.Repo.Migrations.CreateAgentRunReceipts do
  use Ecto.Migration

  def change do
    create table(:agent_run_receipts, primary_key: false) do
      add :run_id, :string, primary_key: true
      add :last_seq, :bigint, null: false, default: 0
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:agent_run_receipts, [:updated_at])
  end
end
