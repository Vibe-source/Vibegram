defmodule VibeAgents.Repo.Migrations.AddSandboxSecondsToAgentUsageLedger do
  use Ecto.Migration

  def change do
    alter table(:agent_usage_ledger) do
      add :sandbox_seconds, :integer, null: false, default: 0
    end
  end
end
