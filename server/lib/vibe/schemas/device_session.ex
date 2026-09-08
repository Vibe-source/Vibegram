defmodule Vibe.Schemas.DeviceSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "device_sessions" do
    field(:user_id, :binary_id)
    field(:account_device_id, :binary_id)
    field(:token_hash, :binary)
    field(:expires_at, :utc_datetime)
    field(:last_used_at, :utc_datetime)
    field(:revoked_at, :utc_datetime)

    belongs_to(:account_device, Vibe.Schemas.AccountDevice,
      define_field: false,
      foreign_key: :account_device_id,
      type: :binary_id
    )

    belongs_to(:user, Vibe.Accounts.User,
      define_field: false,
      foreign_key: :user_id,
      type: :binary_id
    )

    timestamps(type: :utc_datetime)
  end

  def active?(%__MODULE__{} = session, now \\ DateTime.utc_now()) do
    is_nil(session.revoked_at) and match?(%DateTime{}, session.expires_at) and
      DateTime.compare(session.expires_at, now) == :gt
  end

  def changeset(device_session, attrs) do
    device_session
    |> cast(attrs, [
      :user_id,
      :account_device_id,
      :token_hash,
      :expires_at,
      :last_used_at,
      :revoked_at
    ])
    |> validate_required([:user_id, :account_device_id, :token_hash, :expires_at])
    |> validate_change(:token_hash, fn :token_hash, hash ->
      if is_binary(hash) and byte_size(hash) == 32,
        do: [],
        else: [token_hash: "must be a SHA-256 digest"]
    end)
    |> unique_constraint(:token_hash)
  end
end
