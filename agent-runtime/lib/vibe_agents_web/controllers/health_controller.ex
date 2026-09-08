defmodule VibeAgentsWeb.HealthController do
  @moduledoc "Public, unauthenticated: /healthz (no DB) and /readyz (DB ping)."
  use VibeAgentsWeb, :controller

  def healthz(conn, _params), do: json(conn, %{"ok" => true})

  def readyz(conn, _params) do
    case Ecto.Adapters.SQL.query(VibeAgents.Repo, "SELECT 1", []) do
      {:ok, _result} -> json(conn, %{"ok" => true})
      {:error, reason} -> conn |> put_status(503) |> json(%{"ok" => false, "error" => inspect(reason)})
    end
  end
end
