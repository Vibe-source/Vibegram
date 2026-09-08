defmodule VibeAgentsWeb.Plugs.InternalServiceAuthTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias VibeAgentsWeb.Plugs.InternalServiceAuth

  defp signed_conn(body, opts \\ []) do
    key = Keyword.get(opts, :key, Application.get_env(:vibe_agents, :internal_hmac_key))
    service = Keyword.get(opts, :service, "core")
    headers = VibeContracts.ServiceAuth.headers(key, "POST", "/internal/v1/runs", body, service: service)

    conn = conn(:post, "/internal/v1/runs", body) |> assign(:raw_body, Keyword.get(opts, :raw_body, body))
    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end

  test "a correctly signed request passes" do
    conn = signed_conn(~s({"a":1})) |> InternalServiceAuth.call([])
    refute conn.halted
  end

  test "a tampered body is rejected" do
    conn = signed_conn(~s({"a":1}), raw_body: ~s({"a":2})) |> InternalServiceAuth.call([])
    assert conn.halted and conn.status == 401
  end

  test "the wrong key is rejected" do
    conn = signed_conn("{}", key: String.duplicate("z", 40)) |> InternalServiceAuth.call([])
    assert conn.halted and conn.status == 401
  end

  test "only the core may call the runtime" do
    conn = signed_conn("{}", service: "agent-runtime") |> InternalServiceAuth.call([])
    assert conn.halted and conn.status == 401
  end

  test "missing headers are rejected" do
    conn = conn(:post, "/internal/v1/runs", "{}") |> assign(:raw_body, "{}") |> InternalServiceAuth.call([])
    assert conn.halted and conn.status == 401
  end
end
