defmodule Vibe.Repo.Migrations.AddModelSelectionToAgents do
  use Ecto.Migration

  def up do
    alter table(:agents) do
      add(:model_provider, :string, null: false, default: "anthropic")
      add(:model_id, :string, null: false, default: "claude-haiku-4-5-20251001")
    end

    execute("""
    UPDATE agents
    SET model_provider = 'anthropic',
        model_id = 'claude-haiku-4-5-20251001'
    """)

    alter table(:agents) do
      modify(:model_provider, :string, null: false, default: "anthropic")
      modify(:model_id, :string, null: false, default: "claude-sonnet-5")
    end

    create(
      constraint(:agents, :agents_model_provider_check,
        check: "model_provider IN ('anthropic', 'openai')"
      )
    )
  end

  def down do
    drop(constraint(:agents, :agents_model_provider_check))

    alter table(:agents) do
      remove(:model_provider)
      remove(:model_id)
    end
  end
end
