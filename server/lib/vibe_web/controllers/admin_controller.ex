defmodule VibeWeb.AdminController do
  @moduledoc """
  Admin-only views. The roster reads the agent *users*: the built-in team has no
  `agents` row on purpose, so listing that table would show an empty team.
  """
  use VibeWeb, :controller

  import Ecto.Query

  alias Vibe.Accounts.User
  alias Vibe.Admins
  alias Vibe.AI.LocalAgentWorker
  alias Vibe.Repo

  plug VibeWeb.Plugs.RequireAdmin, [scope: "agents.read"] when action in [:team]
  plug VibeWeb.Plugs.RequireAdmin, [scope: "admin.grant"] when action in [:admins]

  def me(conn, _params) do
    user = conn.assigns.current_user
    grant = Admins.get_grant(user)

    json(conn, %{
      ok: true,
      admin: grant != nil,
      role: grant && grant.role,
      scopes: Admins.scopes(user)
    })
  end

  def team(conn, _params) do
    workers = Map.values(LocalAgentWorker.workers())
    ids = workers |> Enum.map(&Map.get(&1, :agent_user_id)) |> Enum.reject(&is_nil/1)

    seeded =
      Repo.all(
        from(u in User,
          where: u.id in ^ids,
          select: %{id: u.id, username: u.username, tier: u.tier}
        )
      )
      |> Map.new(&{&1.id, &1})

    rows =
      workers
      |> Enum.sort_by(&Map.get(&1, :handle))
      |> Enum.map(fn worker ->
        user_id = Map.get(worker, :agent_user_id)
        row = Map.get(seeded, user_id)

        %{
          handle: Map.get(worker, :handle),
          label: Map.get(worker, :label),
          username: Map.get(worker, :username),
          user_id: user_id,
          model: Map.get(worker, :model),
          fallback_model: Map.get(worker, :fallback_model),
          effort: Map.get(worker, :effort),
          runtime: Map.get(worker, :runtime),
          avatar_url: Map.get(worker, :avatar_url),
          seeded: row != nil,
          tier: row && row.tier
        }
      end)

    json(conn, %{ok: true, count: length(rows), agents: rows})
  end

  def admins(conn, _params) do
    grants =
      Enum.map(Admins.list_grants(), fn grant ->
        %{
          username: grant.user && grant.user.username,
          role: grant.role,
          scopes: Admins.scopes(grant.user_id),
          granted_at: grant.inserted_at
        }
      end)

    json(conn, %{ok: true, admins: grants})
  end
end
