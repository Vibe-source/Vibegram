defmodule Vibe.Repo.Migrations.AddVideoIdIndexToMusicCache do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:music_cache, [:query_hash])

    create_if_not_exists unique_index(:music_cache, [:video_id])

    create_if_not_exists index(:music_cache, [:query_hash])
  end
end
