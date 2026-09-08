defmodule Vibe.Schemas.AccountDevice do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "account_devices" do
    field :user_id, :binary_id
    field :device_identifier, :string
    field :name, :string
    field :platform, :string
    field :public_key, :string
    field :push_token_bundle, :map, default: %{}
    field :last_seen_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(account_device, attrs) do
    account_device
    |> cast(attrs, [
      :user_id,
      :device_identifier,
      :name,
      :platform,
      :public_key,
      :push_token_bundle,
      :last_seen_at,
      :revoked_at
    ])
    |> validate_required([:user_id, :device_identifier, :name, :platform])
    |> unique_constraint([:user_id, :device_identifier])
  end
end
