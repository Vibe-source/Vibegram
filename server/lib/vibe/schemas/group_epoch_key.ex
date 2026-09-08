defmodule Vibe.Schemas.GroupEpochKey do
  @moduledoc """
  One group epoch key in transit to one member who is entitled to it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_epoch_keys" do
    belongs_to :recipient_user, Vibe.Accounts.User, foreign_key: :recipient_user_id
    belongs_to :sender_user, Vibe.Accounts.User, foreign_key: :sender_user_id
    field :chat_id, :string
    field :epoch, :integer
    field :sealed_key, :binary
    field :delivered_at, :utc_datetime

    timestamps()
  end

  def changeset(group_epoch_key, attrs) do
    group_epoch_key
    |> cast(attrs, [
      :recipient_user_id,
      :sender_user_id,
      :chat_id,
      :epoch,
      :sealed_key,
      :delivered_at
    ])
    |> validate_required([:recipient_user_id, :sender_user_id, :chat_id, :epoch, :sealed_key])
    |> validate_number(:epoch, greater_than_or_equal_to: 0)
    |> unique_constraint([:recipient_user_id, :chat_id, :epoch],
      name: :group_epoch_keys_recipient_chat_epoch_index
    )
  end
end
