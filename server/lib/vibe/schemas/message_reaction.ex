defmodule Vibe.Chat.MessageReaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "message_reactions" do
    field(:emoji, :string)

    belongs_to(:message, Vibe.Chat.Message, type: :binary_id)
    belongs_to(:chat, Vibe.Chat.Room, type: :string)
    belongs_to(:user, Vibe.Accounts.User, type: :binary_id)

    timestamps()
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:message_id, :chat_id, :user_id, :emoji])
    |> validate_required([:message_id, :chat_id, :user_id, :emoji])
    |> update_change(:emoji, &String.trim/1)
    |> validate_length(:emoji, min: 1, max: 64, count: :bytes)
    |> unique_constraint([:message_id, :user_id])
  end
end
