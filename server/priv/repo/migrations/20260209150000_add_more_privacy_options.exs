defmodule Vibe.Repo.Migrations.AddMorePrivacyOptions do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :privacy_phone_number, :string, default: "everybody"
      add :privacy_profile_photos, :string, default: "everybody"
      add :privacy_bio, :string, default: "everybody"
      add :privacy_gifts, :string, default: "everybody"
      add :privacy_birthday, :string, default: "everybody"
      add :privacy_saved_music, :string, default: "everybody"
    end
  end
end
