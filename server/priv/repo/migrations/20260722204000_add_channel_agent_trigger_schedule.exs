defmodule Vibe.Repo.Migrations.AddChannelAgentTriggerSchedule do
  use Ecto.Migration

  def change do
    alter table(:channel_agent_assignments) do
      add(:next_trigger_at, :utc_datetime)
      add(:last_triggered_at, :utc_datetime)
      add(:last_trigger_status, :string)
      add(:last_trigger_error, :text)
    end

    create(index(:channel_agent_assignments, [:status, :next_trigger_at]))
  end
end
