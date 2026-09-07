defmodule VibeWeb.Plugs.RequireAdmin do
  @moduledoc """
  Halts unless the caller holds a live admin grant. `:scope` narrows it further.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Vibe.Admins

  def init(opts), do: opts

  def call(conn, opts) do
    user = conn.assigns[:current_user]
    scope = Keyword.get(opts, :scope)

    cond do
      is_nil(Admins.get_grant(user)) -> deny(conn)
      is_nil(scope) -> assign(conn, :admin_scopes, Admins.scopes(user))
      Admins.can?(user, scope) -> assign(conn, :admin_scopes, Admins.scopes(user))
      true -> deny(conn)
    end
  end

  # 404, not 403: a non-admin should not learn the route exists.
  defp deny(conn) do
    conn |> put_status(404) |> json(%{error: "Not found"}) |> halt()
  end
end
