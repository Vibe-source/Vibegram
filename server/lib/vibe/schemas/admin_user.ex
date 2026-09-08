defmodule Vibe.Admins.AdminUser do
  @moduledoc """
  One admin grant. Revoking sets `revoked_at` rather than deleting, so the row
  survives as the audit record of who held what.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "admin_users" do
    field :role, :string
    field :scopes, {:array, :string}, default: []
    field :granted_reason, :string
    field :revoked_at, :utc_datetime

    belongs_to :user, Vibe.Accounts.User
    belongs_to :granted_by_user, Vibe.Accounts.User
    belongs_to :revoked_by_user, Vibe.Accounts.User

    timestamps()
  end

  @fields [
    :user_id,
    :role,
    :scopes,
    :granted_by_user_id,
    :granted_reason,
    :revoked_at,
    :revoked_by_user_id
  ]

  def changeset(admin_user, attrs) do
    admin_user
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :role])
    |> validate_inclusion(:role, Vibe.Admins.roles())
    |> validate_subset(:scopes, Vibe.Admins.all_scopes())
    |> unique_constraint(:user_id, name: :admin_users_active_user_index)
    |> foreign_key_constraint(:user_id)
  end
end
