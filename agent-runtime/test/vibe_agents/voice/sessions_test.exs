Code.require_file("support/test_infra.ex", __DIR__)

defmodule VibeAgents.Voice.SessionsTest do
  use ExUnit.Case, async: true

  alias VibeAgents.Voice.Sessions

  setup_all do
    VibeAgents.Voice.TestInfra.ensure_started!()
    :ok
  end

  @attrs %{
    "agentId" => "agent-1",
    "userId" => "user-1",
    "chatId" => "chat-1",
    "agentProfile" => %{"displayName" => "Vee"}
  }

  test "create/1 returns a session_id, ws_url, token and expires_at" do
    {:ok, result} = Sessions.create(@attrs)

    assert is_binary(result.session_id)
    assert String.ends_with?(result.ws_url, "/v1/voice/socket/websocket")
    assert is_binary(result.token)
    assert %DateTime{} = result.expires_at
  end

  test "the token verifies to the session id, user id and agent id" do
    {:ok, result} = Sessions.create(@attrs)

    assert {:ok, %{sid: sid, user_id: "user-1", agent_id: "agent-1"}} =
             Phoenix.Token.verify(VibeAgentsWeb.Endpoint, "voice-session", result.token, max_age: 900)

    assert sid == result.session_id
  end

  test "fetch/1 returns the stored record" do
    {:ok, result} = Sessions.create(@attrs)

    assert {:ok, record} = Sessions.fetch(result.session_id)
    assert record.agent_id == "agent-1"
    assert record.user_id == "user-1"
    assert record.chat_id == "chat-1"
    assert record.agent_profile == @attrs["agentProfile"]
  end

  test "fetch/1 misses an unknown session" do
    assert Sessions.fetch("does-not-exist") == :error
  end
end
