defmodule Vibe.Chat.ChannelJoinRequest do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[pending approved rejected]
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "channel_join_requests" do
    belongs_to(:chat, Vibe.Chat.Room, type: :string)
    belongs_to(:user, Vibe.Accounts.User)
    belongs_to(:invite_link, Vibe.Chat.ChannelInviteLink)
    field(:status, :string, default: "pending")
    belongs_to(:reviewer, Vibe.Accounts.User, foreign_key: :reviewer_id)
    field(:reviewed_at, :utc_datetime)

    timestamps()
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :chat_id,
      :user_id,
      :invite_link_id,
      :status,
      :reviewer_id,
      :reviewed_at
    ])
    |> validate_required([:chat_id, :user_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:chat_id, :user_id], name: :channel_join_requests_pending_index)
  end
end
