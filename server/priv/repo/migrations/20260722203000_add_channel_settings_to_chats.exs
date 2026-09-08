defmodule Vibe.Repo.Migrations.AddChannelSettingsToChats do
  use Ecto.Migration

  def change do
    alter table(:chats) do
      add(:channel_settings, :map, default: %{})
      add(:access_type, :string, default: "private", null: false)
      add(:public_slug, :string)
      add(:join_approval_required, :boolean, default: false, null: false)
      add(:restrict_saving_content, :boolean, default: false, null: false)
    end

    create(
      unique_index(:chats, [:public_slug],
        where: "public_slug IS NOT NULL",
        name: :chats_public_slug_index
      )
    )

    create(
      constraint(:chats, :chats_access_type_check, check: "access_type IN ('private', 'public')")
    )

    create table(:channel_invite_links, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:chat_id, references(:chats, type: :string, on_delete: :delete_all), null: false)
      add(:token_digest, :binary, null: false)
      add(:token_hint, :string, null: false)
      add(:created_by, references(:users, type: :binary_id, on_delete: :nothing), null: false)
      add(:expires_at, :utc_datetime)
      add(:max_uses, :integer)
      add(:use_count, :integer, default: 0, null: false)
      add(:revoked_at, :utc_datetime)

      timestamps()
    end

    create(unique_index(:channel_invite_links, [:token_digest]))
    create(index(:channel_invite_links, [:chat_id, :inserted_at]))

    create(
      constraint(:channel_invite_links, :channel_invite_links_max_uses_check,
        check: "max_uses IS NULL OR max_uses > 0"
      )
    )

    create(
      constraint(:channel_invite_links, :channel_invite_links_use_count_check,
        check: "use_count >= 0"
      )
    )

    create table(:channel_join_requests, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:chat_id, references(:chats, type: :string, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :invite_link_id,
        references(:channel_invite_links, type: :binary_id, on_delete: :nilify_all)
      )

      add(:status, :string, default: "pending", null: false)
      add(:reviewer_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:reviewed_at, :utc_datetime)

      timestamps()
    end

    create(index(:channel_join_requests, [:chat_id, :inserted_at]))

    create(
      unique_index(:channel_join_requests, [:chat_id, :user_id],
        where: "status = 'pending'",
        name: :channel_join_requests_pending_index
      )
    )

    create(
      constraint(:channel_join_requests, :channel_join_requests_status_check,
        check: "status IN ('pending', 'approved', 'rejected')"
      )
    )

    create table(:channel_agent_assignments, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:chat_id, references(:chats, type: :string, on_delete: :delete_all), null: false)
      add(:agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false)
      add(:allowed_tools, {:array, :string}, default: [], null: false)
      add(:allowed_output_modes, {:array, :string}, default: [], null: false)
      add(:trigger_config, :map, default: %{}, null: false)
      add(:permissions, :map, default: %{}, null: false)
      add(:status, :string, default: "active", null: false)
      add(:created_by, references(:users, type: :binary_id, on_delete: :nothing), null: false)

      timestamps()
    end

    create(unique_index(:channel_agent_assignments, [:chat_id, :agent_id]))
    create(index(:channel_agent_assignments, [:agent_id, :status]))

    create(
      constraint(:channel_agent_assignments, :channel_agent_assignments_status_check,
        check: "status IN ('active', 'disabled')"
      )
    )
  end
end
