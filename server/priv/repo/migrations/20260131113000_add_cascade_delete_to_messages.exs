defmodule Vibe.Repo.Migrations.AddCascadeDeleteToMessages do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_from_id_fkey"

    execute "ALTER TABLE messages ADD CONSTRAINT messages_from_id_fkey FOREIGN KEY (from_id) REFERENCES users(id) ON DELETE CASCADE"
  end

  def down do
    execute "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_from_id_fkey"
    execute "ALTER TABLE messages ADD CONSTRAINT messages_from_id_fkey FOREIGN KEY (from_id) REFERENCES users(id) ON DELETE NOTHING"
  end
end
