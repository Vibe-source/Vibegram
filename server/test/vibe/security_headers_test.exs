defmodule Vibe.SecurityHeadersTest do
  use ExUnit.Case, async: true

  alias VibeWeb.Plugs.SecurityHeaders

  test "sets baseline headers on every response" do
    conn = SecurityHeaders.call(Plug.Test.conn(:get, "/api/health"), [])

    assert get(conn, "x-content-type-options") == "nosniff"
    assert get(conn, "x-frame-options") == "DENY"
    assert get(conn, "referrer-policy") == "strict-origin-when-cross-origin"
    assert get(conn, "permissions-policy") == "camera=(), microphone=(), geolocation=()"
    assert get(conn, "cross-origin-opener-policy") == "same-origin"
  end

  test "omits HSTS over plain http with no forwarded-proto header" do
    conn = SecurityHeaders.call(Plug.Test.conn(:get, "/"), [])
    assert get(conn, "strict-transport-security") == nil
  end

  test "sets HSTS when conn.scheme is https" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:scheme, :https)
      |> SecurityHeaders.call([])

    assert get(conn, "strict-transport-security") =~ "max-age=63072000"
  end

  test "sets HSTS when x-forwarded-proto says https (proxy-terminated TLS)" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> SecurityHeaders.call([])

    assert get(conn, "strict-transport-security") =~ "includeSubDomains"
  end

  test "adds CSP outside /api" do
    conn = SecurityHeaders.call(Plug.Test.conn(:get, "/some/spa/route"), [])
    assert get(conn, "content-security-policy") =~ "default-src 'self'"
  end

  test "never adds CSP on /api/*" do
    conn = SecurityHeaders.call(Plug.Test.conn(:get, "/api/user/123"), [])
    assert get(conn, "content-security-policy") == nil
  end

  defp get(conn, header) do
    case Plug.Conn.get_resp_header(conn, header) do
      [value | _] -> value
      [] -> nil
    end
  end
end
