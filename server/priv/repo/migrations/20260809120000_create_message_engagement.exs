defmodule Vibe.Repo.Migrations.CreateMessageEngagement do
  use Ecto.Migration

  def change do
    create table(:message_reactions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:message_id, references(:messages, type: :uuid, on_delete: :delete_all), null: false)
      add(:chat_id, references(:chats, type: :string, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:emoji, :string, null: false)

      timestamps()
    end

    create(unique_index(:message_reactions, [:message_id, :user_id]))
    create(index(:message_reactions, [:message_id, :emoji]))
    create(index(:message_reactions, [:chat_id, :inserted_at]))

    create table(:message_views, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:message_id, references(:messages, type: :uuid, on_delete: :delete_all), null: false)
      add(:chat_id, references(:chats, type: :string, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)

      timestamps(updated_at: false)
    end

    create(unique_index(:message_views, [:message_id, :user_id]))
    create(index(:message_views, [:chat_id, :user_id]))

    create table(:message_reports, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:message_id, references(:messages, type: :uuid, on_delete: :nilify_all))
      add(:chat_id, :string)
      add(:reporter_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      add(:reported_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:reason, :string, null: false)
      add(:details, :text)
      add(:status, :string, null: false, default: "pending")
      add(:resolution, :string)
      add(:action, :string)
      add(:reviewer_id, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:reviewed_at, :utc_datetime)
      add(:resolved_at, :utc_datetime)

      timestamps()
    end

    create(index(:message_reports, [:status, :inserted_at]))
    create(index(:message_reports, [:reported_user_id, :status]))
    create(index(:message_reports, [:reporter_id, :inserted_at]))
    create(index(:message_reports, [:message_id]))

    alter table(:messages) do
      add(:edited_at, :bigint)
    end
  end
end
