defmodule Vibe.Repo.Migrations.RuntimeDecisions do
  use Ecto.Migration

  # Runtime-sourced approvals/permissions (isolated agent runs) have no.
  def change do
    alter table(:agent_approval_tasks) do
      modify :thread_id, :binary_id, null: true
      modify :event_id, :binary_id, null: true
    end
  end
end
