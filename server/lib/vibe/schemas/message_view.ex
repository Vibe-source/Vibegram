defmodule Vibe.Chat.MessageView do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "message_views" do
    belongs_to(:message, Vibe.Chat.Message, type: :binary_id)
    belongs_to(:chat, Vibe.Chat.Room, type: :string)
    belongs_to(:user, Vibe.Accounts.User, type: :binary_id)

    timestamps(updated_at: false)
  end

  def changeset(view, attrs) do
    view
    |> cast(attrs, [:message_id, :chat_id, :user_id])
    |> validate_required([:message_id, :chat_id, :user_id])
    |> unique_constraint([:message_id, :user_id])
  end
end
