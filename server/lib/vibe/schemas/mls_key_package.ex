defmodule Vibe.Schemas.MlsKeyPackage do
  @moduledoc """
  A single MLS KeyPackage published by one of a user's devices.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "mls_key_packages" do
    belongs_to :user, Vibe.Accounts.User
    field :device_id, :string
    field :key_package, :binary
    field :claimed_at, :utc_datetime

    timestamps()
  end

  def changeset(mls_key_package, attrs) do
    mls_key_package
    |> cast(attrs, [:user_id, :device_id, :key_package, :claimed_at])
    |> validate_required([:user_id, :device_id, :key_package])
  end
end
