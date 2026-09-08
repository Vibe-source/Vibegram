defmodule Vibe.Repo.Migrations.CreateAgentTeamRuns do
  use Ecto.Migration

  def change do
    create table(:agent_team_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :chat_id, :binary_id, null: false
      add :requester_user_id, :binary_id, null: false
      add :computer_id, :binary_id
      add :reply_to_id, :string
      add :workers, {:array, :string}, null: false, default: []
      add :current_index, :integer, null: false, default: 0
      add :current_worker, :string, null: false
      add :status, :string, null: false, default: "running"
      add :dispatch_ciphertext, :text, null: false
      add :bridge_metadata, :map, null: false, default: %{}
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_team_runs, [:chat_id, :status])
    create index(:agent_team_runs, [:requester_user_id, :status])
    create index(:agent_team_runs, [:computer_id, :status])
  end
end
