defmodule Vibe.Stories.Story do
  @moduledoc """
  Story schema for 24-hour ephemeral content.
  Stories expire after 24 hours and support visibility controls.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "stories" do
    field :media_url, :string
    field :media_type, :string, default: "image"  # image, video
    field :caption, :string
    field :duration, :integer, default: 5  # seconds to display

    field :original_media_url, :string

    field :visibility, :string, default: "everyone"

    field :visible_to, {:array, :string}, default: []

    field :hidden_from, {:array, :string}, default: []

    field :view_count, :integer, default: 0

    field :expires_at, :utc_datetime

    belongs_to :user, Vibe.Accounts.User, type: :binary_id

    timestamps()
  end

  @required_fields [:user_id, :media_url, :media_type]
  @optional_fields [:caption, :duration, :original_media_url, :visibility, :visible_to, :hidden_from, :expires_at, :view_count]

  def changeset(story, attrs) do
    story
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:visibility, ["everyone", "contacts", "close_friends", "custom"])
    |> validate_inclusion(:media_type, ["image", "video"])
    |> set_expiry()
  end

  defp set_expiry(changeset) do
    if get_field(changeset, :expires_at) do
      changeset
    else
      expires_at = DateTime.utc_now() |> DateTime.add(24 * 60 * 60, :second) |> DateTime.truncate(:second)
      put_change(changeset, :expires_at, expires_at)
    end
  end
end
