defmodule Vibe.Chat.Room do
  use Ecto.Schema
  import Ecto.Changeset

  # Chat IDs are generated strings
  @primary_key {:id, :string, autogenerate: false}
  schema "chats" do
    field(:is_group, :boolean, default: false)
    field(:name, :string)
    field(:type, :string, default: "dm")
    field(:description, :string)
    field(:avatar_url, :string)
    field(:channel_settings, :map, default: %{})
    field(:access_type, :string, default: "private")
    field(:public_slug, :string)
    field(:join_approval_required, :boolean, default: false)
    field(:restrict_saving_content, :boolean, default: false)

    belongs_to(:creator, Vibe.Accounts.User, type: :binary_id)
    has_many(:participants, Vibe.Chat.Participant, foreign_key: :chat_id)
    has_many(:messages, Vibe.Chat.Message, foreign_key: :chat_id)

    timestamps()
  end

  def changeset(chat, attrs) do
    chat
    |> cast(attrs, [
      :id,
      :is_group,
      :name,
      :type,
      :description,
      :avatar_url,
      :creator_id,
      :channel_settings,
      :access_type,
      :public_slug,
      :join_approval_required,
      :restrict_saving_content
    ])
    |> validate_inclusion(:type, ["dm", "group", "channel"])
    |> validate_inclusion(:access_type, ["private", "public"])
    |> unique_constraint(:public_slug, name: :chats_public_slug_index)
  end
end
