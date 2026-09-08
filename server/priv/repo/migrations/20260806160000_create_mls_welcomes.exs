defmodule Vibe.Repo.Migrations.CreateMlsWelcomes do
  use Ecto.Migration

  def change do
    create table(:mls_welcomes, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :recipient_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sender_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :chat_id, :string, null: false
      add :welcome, :binary, null: false
      add :ratchet_tree, :binary
      add :delivered_at, :utc_datetime

      timestamps()
    end

    create index(:mls_welcomes, [:recipient_user_id, :delivered_at])

    create index(:mls_welcomes, [:recipient_user_id, :sender_user_id, :delivered_at])
  end
end
