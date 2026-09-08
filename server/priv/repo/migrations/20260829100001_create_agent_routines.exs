defmodule Vibe.Repo.Migrations.CreateAgentRoutines do
  use Ecto.Migration

  def change do
    create table(:agent_routines, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :owner_user_id, :binary_id, null: false
      add :chat_id, :string, null: false
      add :prompt, :text, null: false
      add :every_minutes, :integer, null: false
      add :status, :string, null: false, default: "active"
      add :next_trigger_at, :utc_datetime
      add :last_run_at, :utc_datetime
      add :last_status, :string
      add :last_error, :string
      add :consecutive_failures, :integer, null: false, default: 0

      timestamps()
    end

    create index(:agent_routines, [:agent_id])
    create index(:agent_routines, [:owner_user_id])
    create index(:agent_routines, [:status, :next_trigger_at])
  end
end
