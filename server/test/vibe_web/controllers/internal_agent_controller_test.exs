defmodule VibeWeb.InternalAgentControllerTest do
  @moduledoc "Signed runtime → core API: auth, event relay + dedupe, deliveries, approvals, provider-auth, handoffs."

  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.AgentApprovalTask
  alias Vibe.Agents
  alias Vibe.Chat
  alias Vibe.Repo

  @endpoint VibeWeb.Endpoint
  @key String.duplicate("s", 40)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    System.put_env("VIBE_INTERNAL_HMAC_KEY", @key)
    System.put_env("VIBE_AGENT_RUNTIME_URL", "http://runtime.test")
    Application.put_env(:vibe, :agent_gateway_http, fn _m, _u, _h, _b -> {:ok, %{status: 200, body: "{}"}} end)

    on_exit(fn ->
      System.delete_env("VIBE_INTERNAL_HMAC_KEY")
      System.delete_env("VIBE_AGENT_RUNTIME_URL")
      Application.delete_env(:vibe, :agent_gateway_http)
    end)

    owner = insert_user("int_owner")
    agent = insert_agent(owner)
    {:ok, agent, secret} = Agents.rotate_secret(agent, owner.id)
    agent = Repo.preload(agent, :agent_user)
    {:ok, chat_id, _} = Chat.ensure_dm_chat(owner.id, agent.agent_user_id)
    %{owner: owner, agent: agent, secret: secret, chat_id: chat_id}
  end

  defp signed_post(path, body_map, opts \\ []) do
    body = Jason.encode!(body_map)
    key = Keyword.get(opts, :key, @key)
    headers = VibeContracts.ServiceAuth.headers(key, "POST", path, body, service: Keyword.get(opts, :service, "agent-runtime"))

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> then(fn conn -> Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end) end)
    |> post(path, body)
  end

  defp event(agent, chat_id, run_id, seq, kind, payload) do
    %{
      "contract" => "vibe.agentic.v1",
      "runId" => run_id,
      "agentId" => agent.id,
      "agentUserId" => agent.agent_user_id,
      "chatId" => chat_id,
      "seq" => seq,
      "ts" => System.system_time(:millisecond),
      "kind" => kind,
      "payload" => payload
    }
  end

  test "unsigned and wrongly signed requests are rejected" do
    conn = build_conn() |> put_req_header("content-type", "application/json") |> post("/internal/v1/agent-events", ~s({"events":[]}))
    assert conn.status == 401

    conn = signed_post("/internal/v1/agent-events", %{"events" => []}, key: String.duplicate("x", 40))
    assert conn.status == 401

    conn = signed_post("/internal/v1/agent-events", %{"events" => []}, service: "core")
    assert conn.status == 401

    conn = signed_post("/internal/v1/agent-events", %{"events" => []})
    assert json_response(conn, 200)["accepted"] == 0
  end

  test "signed events are durable, overlap-safe, and gated on membership", %{agent: agent, chat_id: chat_id} do
    VibeWeb.Endpoint.subscribe("chat:#{chat_id}")
    run_id = Ecto.UUID.generate()

    first = [
      event(agent, chat_id, run_id, 1, "run.started", %{"source" => "chat", "model" => "m"}),
      event(agent, chat_id, run_id, 2, "run.text.delta", %{"text" => "Hello"}),
      event(agent, chat_id, run_id, 3, "run.completed", %{"summary" => "done", "usage" => %{"inputTokens" => 2}, "costCents" => 1}),
      event(agent, "chat-the-agent-is-not-in", run_id, 4, "run.text.delta", %{"text" => "leak"})
    ]

    assert signed_post("/internal/v1/agent-events", %{"events" => first}) |> json_response(200) |> Map.fetch!("accepted") == 3
    assert_receive %Phoenix.Socket.Broadcast{event: "agent-stream", payload: %{"runId" => ^run_id}}
    assert_receive %Phoenix.Socket.Broadcast{event: "agent-stream", payload: %{"text" => "Hello"}}
    assert_receive %Phoenix.Socket.Broadcast{event: "agent-stream", payload: %{"status" => "done"}}

    assert signed_post("/internal/v1/agent-events", %{"events" => first}) |> json_response(200) |> Map.fetch!("accepted") == 3
    refute_receive %Phoenix.Socket.Broadcast{event: "agent-stream"}, 100
    assert Repo.get_by(Vibe.AgentUsageEvent, run_id: run_id)

    overlap = [
      event(agent, chat_id, run_id, 2, "run.text.delta", %{"text" => "duplicate"}),
      event(agent, chat_id, run_id, 3, "run.completed", %{"summary" => "done", "usage" => %{}, "costCents" => 0}),
      event(agent, chat_id, run_id, 4, "run.text.delta", %{"text" => "!"})
    ]

    assert signed_post("/internal/v1/agent-events", %{"events" => overlap}) |> json_response(200) |> Map.fetch!("accepted") == 3
    assert_receive %Phoenix.Socket.Broadcast{event: "agent-stream", payload: %{"text" => "!"}}
    refute_receive %Phoenix.Socket.Broadcast{payload: %{"text" => "duplicate"}}, 100
  end

  test "deliveries post messages as the agent, only into its own chats", %{agent: agent, chat_id: chat_id} do
    outputs = [%{"type" => "text", "text" => "delivered", "metadata" => %{}}]
    conn = signed_post("/internal/v1/deliveries", %{"runId" => "r", "agentId" => agent.id, "chatId" => chat_id, "outputs" => outputs})
    assert [%{"messageId" => _}] = json_response(conn, 200)["deliveries"]

    conn = signed_post("/internal/v1/deliveries", %{"runId" => "r", "agentId" => agent.id, "chatId" => "other-chat", "outputs" => outputs})
    assert conn.status == 403
  end

  test "approvals create a runtime decision task with claimable actions", %{agent: agent, chat_id: chat_id} do
    body = %{
      "runId" => Ecto.UUID.generate(),
      "agentId" => agent.id,
      "chatId" => chat_id,
      "decisionId" => Ecto.UUID.generate(),
      "kind" => "approval",
      "title" => "Send it?",
      "detail" => "The email body",
      "risk" => "external_effect",
      "actions" => [%{"id" => "approve", "label" => "Approve", "style" => "primary"}, %{"id" => "reject", "label" => "Reject", "style" => "destructive"}],
      "actionMode" => "single",
      "expiresAt" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
    }

    conn = signed_post("/internal/v1/approvals", body)
    assert %{"taskId" => task_id, "messageId" => message_id} = json_response(conn, 200)

    task = Repo.get!(AgentApprovalTask, task_id) |> Repo.preload(:decision_actions)
    assert task.source == "runtime"
    assert task.requested_action["actionType"] == "runtime_decision"
    assert task.message_id == message_id
    assert length(task.decision_actions) == 2
  end

  test "provider-auth returns the agent profile only for the right secret", %{agent: agent, secret: secret} do
    conn = signed_post("/internal/v1/provider-auth", %{"identifier" => agent.agent_user.username, "secret" => secret})
    body = json_response(conn, 200)
    assert body["agentId"] == agent.id
    assert body["agentProfile"]["displayName"] == agent.display_name

    conn = signed_post("/internal/v1/provider-auth", %{"identifier" => agent.agent_user.username, "secret" => "wrong"})
    assert conn.status == 401

    conn = signed_post("/internal/v1/provider-auth", %{"identifier" => "nobody", "secret" => secret})
    assert conn.status == 401
  end

  test "handoffs require both agents in the chat", %{agent: agent, chat_id: chat_id} do
    conn = signed_post("/internal/v1/handoffs", %{"runId" => "r", "agentId" => agent.id, "chatId" => chat_id, "toAgentUsername" => "ghost", "note" => "take over"})
    assert conn.status == 403
  end

  defp insert_user(prefix) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      name: "Int"
    })
  end

  defp insert_agent(owner) do
    shadow = Repo.insert!(%User{id: Ecto.UUID.generate(), username: "intagent_#{System.unique_integer([:positive])}", password_hash: "hash", public_key: "key", device_id: "d", is_agent: true, name: "Bot"})

    Repo.insert!(%Agent{
      owner_user_id: owner.id,
      agent_user_id: shadow.id,
      status: "published",
      display_name: "Internal Bot",
      enabled_tools: [],
      output_modes: ["text"],
      webhook_secret_hash: "hash",
      secret_hint: "hint"
    })
  end
end
