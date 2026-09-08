defmodule Vibe.Repo.Migrations.AddSavedMessageReaction do
  use Ecto.Migration

  def change do
    alter table(:saved_messages) do
      add(:reaction_emoji, :text)
    end
  end
end
