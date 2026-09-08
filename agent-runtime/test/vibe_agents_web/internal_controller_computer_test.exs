defmodule VibeAgentsWeb.InternalControllerComputerTest do
  @moduledoc "/internal/v1/agents/:agent_id/computer/* — straight gateway passthrough."
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  alias VibeAgents.Repo
  alias VibeAgents.Schemas.AgentComputer
  alias VibeAgents.Test.FakeSandboxHTTP

  @endpoint VibeAgentsWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    FakeSandboxHTTP.reset()
    Application.put_env(:vibe_agents, :sandbox_gateway_url, "http://gateway.test")
    Application.put_env(:vibe_agents, :sandbox_gateway_token, String.duplicate("t", 40))

    on_exit(fn ->
      FakeSandboxHTTP.reset()
      Application.delete_env(:vibe_agents, :sandbox_gateway_url)
      Application.delete_env(:vibe_agents, :sandbox_gateway_token)
    end)

    agent_id = Ecto.UUID.generate()

    %AgentComputer{}
    |> AgentComputer.changeset(%{
      agent_id: agent_id,
      sandbox_id: "sb-9",
      status: "running",
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    %{agent_id: agent_id}
  end

  defp signed(method, path, body) do
    key = Application.get_env(:vibe_agents, :internal_hmac_key)
    headers = VibeContracts.ServiceAuth.headers(key, method, path, body, service: "core")

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> then(fn conn -> Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end) end)
  end

  defp signed_get(path), do: get(signed("GET", path, ""), path)
  defp signed_post(path, body), do: post(signed("POST", path, body), path, body)

  test "a 204 from the gateway is a 204 from the runtime, with no body", %{agent_id: agent_id} do
    FakeSandboxHTTP.stub(fn :get, _url, _body -> {:ok, :no_change} end)

    conn = signed_get("/internal/v1/agents/#{agent_id}/computer/frame?since=7")
    assert conn.status == 204
    assert conn.resp_body == ""
  end

  test "a frame with a body comes back as 200 json", %{agent_id: agent_id} do
    FakeSandboxHTTP.stub(fn :get, _url, _body -> {:ok, %{"seq" => 8, "imageBase64" => "aGk="}} end)

    conn = signed_get("/internal/v1/agents/#{agent_id}/computer/frame?since=0")
    assert json_response(conn, 200)["seq"] == 8
  end

  test "a 409 from the gateway stays a 409, not a generic 422", %{agent_id: agent_id} do
    FakeSandboxHTTP.stub(fn :post, _url, _body -> {:error, {:http_error, 409, ~s({"error":"control_not_held"})}} end)

    body = ~s({"sessionId":"s-1","kind":"click","x":10,"y":20})
    conn = signed_post("/internal/v1/agents/#{agent_id}/computer/input", body)
    assert json_response(conn, 409)["error"] == "control_not_held"
  end

  test "the session body reaches the gateway without the path params", %{agent_id: agent_id} do
    FakeSandboxHTTP.stub(fn :post, _url, body -> {:ok, Map.put(body, "sessionId", "s-1")} end)

    conn = signed_post("/internal/v1/agents/#{agent_id}/computer/session", ~s({"viewerId":"u-1","fps":3}))
    assert json_response(conn, 200)["sessionId"] == "s-1"

    assert [%{body: sent}] = FakeSandboxHTTP.calls()
    assert sent == %{"viewerId" => "u-1", "fps" => 3}
  end

  test "an agent with no sandbox row is 404, not 502", %{} do
    conn = signed_get("/internal/v1/agents/#{Ecto.UUID.generate()}/computer/state")
    assert json_response(conn, 404)["error"] == "not_available"
  end

  test "closing a session passes the session id through", %{agent_id: agent_id} do
    FakeSandboxHTTP.stub(fn :delete, _url, _body -> {:ok, %{"sessionId" => "s-1", "status" => "closed"}} end)

    path = "/internal/v1/agents/#{agent_id}/computer/session/s-1"
    conn = delete(signed("DELETE", path, ""), path)
    assert json_response(conn, 200)["status"] == "closed"

    assert [%{url: url}] = FakeSandboxHTTP.calls()
    assert String.ends_with?(url, "/v1/sandboxes/sb-9/computer/session/s-1")
  end

  test "the exec log query reaches the gateway with since and limit", %{agent_id: agent_id} do
    FakeSandboxHTTP.stub(fn :get, _url, _body -> {:ok, %{"entries" => [%{"seq" => 4}]}} end)

    conn = signed_get("/internal/v1/agents/#{agent_id}/computer/exec-log?since=3&limit=5")
    assert json_response(conn, 200)["entries"] == [%{"seq" => 4}]

    assert [%{url: url}] = FakeSandboxHTTP.calls()
    assert String.ends_with?(url, "/v1/sandboxes/sb-9/exec/log?since=3&limit=5")
  end

  test "the tree query carries the path it was asked for", %{agent_id: agent_id} do
    FakeSandboxHTTP.stub(fn :get, _url, _body -> {:ok, %{"entries" => []}} end)

    conn = signed_get("/internal/v1/agents/#{agent_id}/computer/tree?path=/home/agent/proj&depth=1")
    assert json_response(conn, 200)["entries"] == []

    assert [%{url: url}] = FakeSandboxHTTP.calls()
    assert String.ends_with?(url, "/v1/sandboxes/sb-9/tree?path=%2Fhome%2Fagent%2Fproj&depth=1")
  end

  test "reading a file passes the path straight through", %{agent_id: agent_id} do
    FakeSandboxHTTP.stub(fn :get, _url, _body -> {:ok, %{"path" => "/home/agent/a.txt", "contentBase64" => "aGk="}} end)

    conn = signed_get("/internal/v1/agents/#{agent_id}/computer/file?path=/home/agent/a.txt")
    assert json_response(conn, 200)["contentBase64"] == "aGk="
  end
end
