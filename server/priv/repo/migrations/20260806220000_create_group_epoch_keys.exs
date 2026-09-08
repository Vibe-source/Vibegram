defmodule Vibe.Repo.Migrations.CreateGroupEpochKeys do
  use Ecto.Migration

  def change do
    create table(:group_epoch_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :recipient_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sender_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :chat_id, :string, null: false
      add :epoch, :integer, null: false
      add :sealed_key, :binary, null: false
      add :delivered_at, :utc_datetime

      timestamps()
    end

    create index(:group_epoch_keys, [:recipient_user_id, :delivered_at])

    create unique_index(:group_epoch_keys, [:recipient_user_id, :chat_id, :epoch],
             name: :group_epoch_keys_recipient_chat_epoch_index
           )

    create index(:group_epoch_keys, [:recipient_user_id, :sender_user_id, :delivered_at])
  end
end
