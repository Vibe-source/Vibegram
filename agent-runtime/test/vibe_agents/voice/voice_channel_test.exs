Code.require_file("support/test_infra.ex", __DIR__)
Code.require_file("support/fake_provider.ex", __DIR__)

defmodule VibeAgentsWeb.VoiceChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint VibeAgentsWeb.Endpoint

  setup_all do
    VibeAgents.Voice.TestInfra.ensure_started!()
    :ok
  end

  setup do
    previous = Application.get_env(:vibe_agents, :voice_provider)
    Application.put_env(:vibe_agents, :voice_provider, VibeAgents.Voice.FakeProvider)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:vibe_agents, :voice_provider)
  defp restore(value), do: Application.put_env(:vibe_agents, :voice_provider, value)

  defp session_record do
    {:ok, result} =
      VibeAgents.Voice.Sessions.create(%{
        "agentId" => "agent-1",
        "userId" => "user-1",
        "chatId" => "chat-1",
        "agentProfile" => %{"displayName" => "Vee"}
      })

    result
  end

  test "connect fails with a bad token" do
    assert :error = connect(VibeAgentsWeb.VoiceSocket, %{"token" => "not-a-real-token"})
  end

  test "connect fails with no token at all" do
    assert :error = connect(VibeAgentsWeb.VoiceSocket, %{})
  end

  test "join succeeds when the topic sid matches the token's sid" do
    session = session_record()
    {:ok, socket} = connect(VibeAgentsWeb.VoiceSocket, %{"token" => session.token})

    assert {:ok, _reply, _socket} = subscribe_and_join(socket, "voice:" <> session.session_id, %{})
  end

  test "join fails when the topic sid doesn't match the token's sid" do
    session = session_record()
    {:ok, socket} = connect(VibeAgentsWeb.VoiceSocket, %{"token" => session.token})

    assert {:error, %{reason: "sid_mismatch"}} =
             subscribe_and_join(socket, "voice:" <> Ecto.UUID.generate(), %{})
  end

  test "join fails for a well-formed token whose session was never created" do
    token =
      Phoenix.Token.sign(VibeAgentsWeb.Endpoint, "voice-session", %{
        sid: "ghost-session",
        user_id: "user-1",
        agent_id: "agent-1"
      })

    {:ok, socket} = connect(VibeAgentsWeb.VoiceSocket, %{"token" => token})

    assert {:error, %{reason: "session_not_found"}} =
             subscribe_and_join(socket, "voice:ghost-session", %{})
  end
end
