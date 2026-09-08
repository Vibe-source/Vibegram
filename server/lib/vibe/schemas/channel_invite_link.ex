defmodule Vibe.Chat.ChannelInviteLink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "channel_invite_links" do
    belongs_to(:chat, Vibe.Chat.Room, type: :string)
    field(:token_digest, :binary)
    field(:token_hint, :string)
    belongs_to(:creator, Vibe.Accounts.User, foreign_key: :created_by)
    field(:expires_at, :utc_datetime)
    field(:max_uses, :integer)
    field(:use_count, :integer, default: 0)
    field(:revoked_at, :utc_datetime)

    timestamps()
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :chat_id,
      :token_digest,
      :token_hint,
      :created_by,
      :expires_at,
      :max_uses,
      :use_count,
      :revoked_at
    ])
    |> validate_required([:chat_id, :token_digest, :token_hint, :created_by])
    |> validate_number(:max_uses, greater_than: 0)
    |> validate_number(:use_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:token_digest)
  end
end
