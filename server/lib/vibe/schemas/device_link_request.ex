defmodule Vibe.Schemas.DeviceLinkRequest do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "device_link_requests" do
    field :code_hash, :binary
    field :requester_device_identifier, :string
    field :requester_name, :string
    field :requester_platform, :string
    field :requester_public_key, :string
    field :user_id, :binary_id
    field :wrapped_key_envelope, :string
    field :expires_at, :utc_datetime
    field :approved_at, :utc_datetime
    field :consumed_at, :utc_datetime
    field :rejected_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(link_request, attrs) do
    link_request
    |> cast(attrs, [
      :code_hash,
      :requester_device_identifier,
      :requester_name,
      :requester_platform,
      :requester_public_key,
      :user_id,
      :wrapped_key_envelope,
      :expires_at,
      :approved_at,
      :consumed_at,
      :rejected_at
    ])
    |> validate_required([
      :code_hash,
      :requester_device_identifier,
      :requester_name,
      :requester_platform,
      :requester_public_key,
      :expires_at
    ])
    |> unique_constraint(:code_hash)
  end

  def approve_changeset(link_request, attrs) do
    link_request
    |> cast(attrs, [:user_id, :wrapped_key_envelope, :approved_at])
    |> validate_required([:user_id, :wrapped_key_envelope, :approved_at])
  end
end
