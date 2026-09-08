defmodule Vibe.Repo.Migrations.AddMissingIndexes do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Concurrent builds:
  def change do
    create(index(:messages, [:chat_id, :inserted_at], concurrently: true))

    create(index(:saved_messages, [:user_id, :timestamp], concurrently: true))

    create(
      index(:chat_participants, [:user_id],
        concurrently: true,
        where: "deleted IS NOT TRUE",
        name: :chat_participants_user_id_active_index
      )
    )

    create(index(:chats, [:type, :access_type, :inserted_at], concurrently: true))

    create(index(:agent_events, [:agent_id, :occurred_at], concurrently: true))
  end
end
