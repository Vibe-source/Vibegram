defmodule Vibe.Repo.Migrations.CreateInitialSchema do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :username, :string, null: false
      add :password_hash, :string
      add :public_key, :text
      add :identity_key, :text
      add :encrypted_private_key, :text
      add :device_id, :string
      add :login_token, :string
      add :secure_id, :string
      add :profile_image, :text
      add :last_seen, :utc_datetime
      
      add :signed_pre_key_id, :integer
      add :signed_pre_key, :text
      add :signed_pre_key_signature, :text
      add :supports_advanced, :boolean, default: false

      timestamps()
    end

    create unique_index(:users, [:username])
    create unique_index(:users, [:login_token])
    create index(:users, [:secure_id])

    create table(:chats, primary_key: false) do
      add :id, :string, primary_key: true # Node uses generated string IDs
      add :is_group, :boolean, default: false
      add :name, :string

      timestamps()
    end

    create table(:chat_participants) do
      add :chat_id, references(:chats, type: :string, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :muted, :boolean, default: false
      add :pinned, :boolean, default: false
      add :marked_unread, :boolean, default: false

      timestamps()
    end

    create unique_index(:chat_participants, [:chat_id, :user_id])
    create index(:chat_participants, [:user_id])

    create table(:messages, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :chat_id, references(:chats, type: :string, on_delete: :delete_all), null: false
      add :from_id, references(:users, type: :uuid, on_delete: :nothing), null: false
      add :encrypted_content, :text, null: false
      add :type, :string, default: "text"
      add :media_url, :text
      add :status, :string, default: "sent"
      add :timestamp, :bigint
      add :reply_to_id, references(:messages, type: :uuid, on_delete: :nothing)

      timestamps()
    end

    create index(:messages, [:chat_id, :timestamp])

    create table(:message_reads) do
      add :message_id, references(:messages, type: :uuid, on_delete: :delete_all), null: false
      add :reader_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:message_reads, [:message_id, :reader_id])

    create table(:subscriptions) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :endpoint, :text, null: false
      add :keys_p256dh, :text
      add :keys_auth, :text

      timestamps()
    end

    create unique_index(:subscriptions, [:endpoint])
    create index(:subscriptions, [:user_id])
  end
end
