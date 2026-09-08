defmodule VibeAgents.Repo.Migrations.CreateAgentRuns do
  use Ecto.Migration

  def change do
    create table(:agent_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, :binary_id, null: false
      add :agent_user_id, :binary_id, null: false
      add :owner_user_id, :binary_id, null: false
      add :requester_user_id, :binary_id
      add :chat_id, :string, null: false
      add :chat_kind, :string
      add :source, :string, null: false
      add :parent_run_id, references(:agent_runs, type: :binary_id, on_delete: :nilify_all)
      add :idempotency_key, :string
      add :status, :string, null: false, default: "queued"
      add :input, :map, null: false, default: %{}
      add :agent_profile, :map, null: false, default: %{}
      add :context, :map, null: false, default: %{}
      add :capabilities, :map, null: false, default: %{}
      add :state, :map, null: false, default: %{}
      add :result, :map
      add :error, :string
      add :usage, :map, null: false, default: %{}
      add :cost_cents, :integer, null: false, default: 0
      add :steps, :integer, null: false, default: 0
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps()
    end

    create unique_index(:agent_runs, [:idempotency_key])
    create index(:agent_runs, [:agent_id, :inserted_at])
    create index(:agent_runs, [:chat_id, :inserted_at])
    create index(:agent_runs, [:status])
  end
end
