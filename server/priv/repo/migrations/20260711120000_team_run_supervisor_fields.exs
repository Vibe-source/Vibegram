defmodule Vibe.Repo.Migrations.TeamRunSupervisorFields do
  use Ecto.Migration

  def change do
    alter table(:agent_team_runs) do
      add :mode, :string, null: false, default: "supervisor"
      add :lead_worker, :string
      add :worker_states, :map, null: false, default: %{}
    end
  end
end
