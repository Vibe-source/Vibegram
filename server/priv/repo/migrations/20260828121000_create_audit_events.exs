defmodule Vibe.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :actor_user_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :action, :string, null: false
      add :target_type, :string
      add :target_id, :string
      add :ip, :string
      add :user_agent, :string
      add :metadata, :map, default: %{}, null: false

      timestamps(updated_at: false)
    end

    create index(:audit_events, [:actor_user_id, :inserted_at])
    create index(:audit_events, [:action, :inserted_at])
  end
end
