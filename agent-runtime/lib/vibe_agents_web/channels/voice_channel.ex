defmodule VibeAgentsWeb.VoiceChannel do
  @moduledoc """
  Thin transport: validates the join against the token's sid/user/agent, starts or
  attaches VibeAgents.Voice.Session, and forwards frames both ways. All real behavior
  lives in Session. See docs/agent-voice-v1.md §3/§6.
  """
  use Phoenix.Channel

  alias VibeAgents.Voice.Session
  alias VibeAgents.Voice.Sessions

  @inbound_events ~w(audio.chunk audio.end interrupt text.message image.frame decision hangup)

  @impl true
  def join("voice:" <> session_id, _payload, socket) do
    with {:sid, true} <- {:sid, socket.assigns[:voice_sid] == session_id},
         {:record, {:ok, record}} <- {:record, Sessions.fetch(session_id)},
         {:owner, true} <-
           {:owner,
            record.user_id == socket.assigns.voice_user_id and
              record.agent_id == socket.assigns.voice_agent_id},
         {:session, {:ok, session_pid}} <- {:session, Session.join(session_id, record, self())} do
      {:ok, assign(socket, :voice_session_pid, session_pid)}
    else
      {:sid, false} -> {:error, %{reason: "sid_mismatch"}}
      {:record, :error} -> {:error, %{reason: "session_not_found"}}
      {:owner, false} -> {:error, %{reason: "session_mismatch"}}
      {:session, {:error, _reason}} -> {:error, %{reason: "provider_unavailable"}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "invalid_voice_topic"}}

  @impl true
  def handle_in(event, payload, socket) when event in @inbound_events do
    GenServer.cast(socket.assigns.voice_session_pid, {:frame, event, payload})
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:voice_frame, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end
end
