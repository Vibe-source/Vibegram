defmodule Vibe.Admins do
  @moduledoc """
  Admin roles and the scopes each one carries. The role list lives here rather
  than in a check constraint, so adding a role ships as code, not as a migration.
  """
  import Ecto.Query

  alias Vibe.Admins.AdminUser
  alias Vibe.Repo

  @scopes ~w(
    admin.grant
    agents.read
    agents.write
    users.read
    audit.read
    server.ops
  )

  # Per-row `scopes` adds to these; it never subtracts.
  @role_scopes %{
    "superadmin" => @scopes,
    "admin" => ~w(agents.read agents.write users.read audit.read)
  }

  def roles, do: Map.keys(@role_scopes)

  def all_scopes, do: @scopes

  def scopes_for_role(role), do: Map.get(@role_scopes, role, [])

  def get_grant(nil), do: nil
  def get_grant(%{id: user_id}), do: get_grant(user_id)

  def get_grant(user_id) when is_binary(user_id) do
    Repo.one(from(a in AdminUser, where: a.user_id == ^user_id and is_nil(a.revoked_at)))
  end

  def get_grant(_), do: nil

  def admin?(user), do: get_grant(user) != nil

  def superadmin?(user), do: match?(%AdminUser{role: "superadmin"}, get_grant(user))

  def scopes(user) do
    case get_grant(user) do
      nil -> []
      %AdminUser{role: role, scopes: extra} -> Enum.uniq(scopes_for_role(role) ++ (extra || []))
    end
  end

  def can?(user, scope), do: scope in scopes(user)

  def list_grants do
    Repo.all(
      from(a in AdminUser,
        where: is_nil(a.revoked_at),
        order_by: [asc: a.role, asc: a.inserted_at],
        preload: [:user]
      )
    )
  end
end
