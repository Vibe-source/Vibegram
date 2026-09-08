defmodule Vibe.Chat.SavedMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @derive {Jason.Encoder, only: [:id, :user_id, :original_message_id, :chat_id, :from_id, :encrypted_content, :content, :type, :media_url, :timestamp, :extra, :inserted_at]}
  schema "saved_messages" do
    field :original_message_id, :string
    field :chat_id, :string
    field :from_id, :string
    field :encrypted_content, :string
    field :content, :string
    field :type, :string
    field :media_url, :string
    field :timestamp, :integer
    field :extra, :string
    field :reaction_emoji, :string

    belongs_to :user, Vibe.Accounts.User, type: :binary_id

    timestamps()
  end

  def changeset(saved_message, attrs) do
    saved_message
    |> cast(attrs, [:user_id, :original_message_id, :chat_id, :from_id, :encrypted_content, :content, :type, :media_url, :timestamp, :extra])
    |> validate_required([:user_id, :original_message_id, :type])
    |> unique_constraint([:user_id, :original_message_id])
  end
end
