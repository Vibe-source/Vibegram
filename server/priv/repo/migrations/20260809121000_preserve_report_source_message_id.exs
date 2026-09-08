defmodule Vibe.Repo.Migrations.PreserveReportSourceMessageId do
  use Ecto.Migration

  def up do
    alter table(:message_reports) do
      add(:source_message_id, :uuid)
    end

    execute("UPDATE message_reports SET source_message_id = message_id")

    alter table(:message_reports) do
      modify(:source_message_id, :uuid, null: false)
    end

    create(index(:message_reports, [:source_message_id]))
  end

  def down do
    drop(index(:message_reports, [:source_message_id]))

    alter table(:message_reports) do
      remove(:source_message_id)
    end
  end
end
