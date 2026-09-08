defmodule Vibe.Repo.Migrations.AddExecutionModeToAgents do
  use Ecto.Migration

  # Routes an agent's dispatch to the isolated agent-runtime instead of the.
  def change do
    alter table(:agents) do
      add :execution_mode, :string, default: "embedded", null: false
    end

    create index(:agents, [:execution_mode])
  end
end
