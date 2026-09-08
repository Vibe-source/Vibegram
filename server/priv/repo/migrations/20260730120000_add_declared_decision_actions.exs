defmodule Vibe.Repo.Migrations.AddDeclaredDecisionActions do
  use Ecto.Migration

  def change do
    alter table(:agent_approval_tasks) do
      add(:action_mode, :string, null: false, default: "single")
      add(:expires_at, :utc_datetime)
      add(:message_id, :binary_id)
      add(:chosen_action_id, :string)
      add(:source, :string, null: false, default: "runbook")
    end

    create(index(:agent_approval_tasks, [:status, :expires_at]))
    create(index(:agent_approval_tasks, [:message_id]))

    create table(:agent_decision_actions, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:task_id, references(:agent_approval_tasks, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:action_id, :string, null: false)
      add(:label, :string, null: false)
      add(:style, :string, null: false, default: "secondary")
      add(:confirm, :text)
      add(:token_hash, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:position, :integer, null: false, default: 0)
      add(:chosen_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:chosen_at, :utc_datetime)

      timestamps()
    end

    create(unique_index(:agent_decision_actions, [:token_hash]))
    create(index(:agent_decision_actions, [:task_id, :status]))
    create(unique_index(:agent_decision_actions, [:task_id, :action_id]))
  end
end
