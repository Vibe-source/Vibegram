defmodule VibeWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Baseline security response headers on every response. CSP is added only
  outside `/api/*` (the SPA/docs routes) — the JSON API has no HTML to inject into.
  """

  import Plug.Conn

  @csp "default-src 'self'; img-src 'self' data: https:; script-src 'self'; " <>
         "style-src 'self' 'unsafe-inline'; connect-src 'self' wss: https:; frame-ancestors 'none'"

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("permissions-policy", "camera=(), microphone=(), geolocation=()")
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> maybe_put_hsts()
    |> maybe_put_csp()
  end

  defp maybe_put_hsts(conn) do
    if https?(conn) do
      put_resp_header(
        conn,
        "strict-transport-security",
        "max-age=63072000; includeSubDomains; preload"
      )
    else
      conn
    end
  end

  defp https?(conn) do
    conn.scheme == :https or get_req_header(conn, "x-forwarded-proto") == ["https"]
  end

  defp maybe_put_csp(conn) do
    if api_path?(conn), do: conn, else: put_resp_header(conn, "content-security-policy", @csp)
  end

  defp api_path?(%{path_info: ["api" | _]}), do: true
  defp api_path?(_), do: false
end
