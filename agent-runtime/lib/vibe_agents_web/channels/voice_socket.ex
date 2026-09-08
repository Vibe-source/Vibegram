defmodule VibeAgentsWeb.VoiceSocket do
  @moduledoc """
  Transport for vibe.voice.v1 calls. Verifies the join token minted by
  VibeAgents.Voice.Sessions.create/1 (docs/agent-voice-v1.md §3).
  """
  use Phoenix.Socket

  channel "voice:*", VibeAgentsWeb.VoiceChannel

  @max_age_seconds 900

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Phoenix.Token.verify(VibeAgentsWeb.Endpoint, "voice-session", token, max_age: @max_age_seconds) do
      {:ok, %{sid: sid, user_id: user_id, agent_id: agent_id}} ->
        socket =
          socket
          |> assign(:voice_sid, sid)
          |> assign(:voice_user_id, user_id)
          |> assign(:voice_agent_id, agent_id)

        {:ok, socket}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "voice_socket:#{socket.assigns.voice_sid}"
end
