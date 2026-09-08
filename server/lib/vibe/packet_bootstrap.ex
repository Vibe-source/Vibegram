defmodule Vibe.PacketBootstrap do
  @moduledoc """
  Proxy entries the app offers in Settings → Proxy. The client runs the packet engine
  itself as a loopback SOCKS hop, so the server hands over configuration only.
  """

  @doc """
  `VIBE_PACKET_PROXY_PROFILES` holds a JSON list in the client's own profile shape (name.
  """
  def issue_for_user(_user) do
    {:ok, %{packetProxyProfiles: proxy_profiles()}}
  end

  def proxy_profiles do
    with value when is_binary(value) <- System.get_env("VIBE_PACKET_PROXY_PROFILES"),
         {:ok, profiles} <- Jason.decode(value),
         true <- is_list(profiles) do
      Enum.filter(profiles, &is_map/1)
    else
      _ -> []
    end
  end
end
