defmodule VibeWeb.AgentBridgeSocket do
  @moduledoc """
  Socket for the agent bridge daemon running on a user's computer.
  """
  use Phoenix.Socket

  channel("bridge:*", VibeWeb.AgentBridgeChannel)

  @impl true
  def connect(params, socket, connect_info) do
    token = extract_connect_token(params, connect_info)

    case token && Vibe.AgentBridge.verify_connection(token) do
      {:ok, identity} ->
        {:ok,
         socket
         |> assign(:user_id, identity.user_id)
         |> assign(:computer_id, identity.computer_id)
         |> assign(:device_label, identity.device_label)}

      _ ->
        :error
    end
  end

  @doc """
  Resolves the bridge token for a WebSocket connect.
  """
  def extract_connect_token(params, connect_info) do
    case header_token(connect_info) do
      nil -> query_token(params)
      token -> token
    end
  end

  defp header_token(%{x_headers: headers}) when is_list(headers) do
    Enum.find_value(headers, fn
      {"x-vibe-bridge-token", value} when is_binary(value) -> parse_auth_header_value(value)
      _ -> nil
    end)
  end

  defp header_token(_), do: nil

  defp query_token(%{"token" => token}) when is_binary(token) do
    case String.trim(token) do
      "" -> nil
      "undefined" -> nil
      t -> t
    end
  end

  defp query_token(_), do: nil

  @doc false
  def parse_auth_header_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Regex.run(~r/^Bearer\s+(.+)$/i, trimmed) do
      [_, token] ->
        case String.trim(token) do
          "" -> nil
          "undefined" -> nil
          t -> t
        end

      nil ->
        if trimmed == "" or trimmed == "undefined" or String.downcase(trimmed) == "bearer",
          do: nil,
          else: trimmed
    end
  end

  def parse_auth_header_value(_), do: nil

  @impl true
  def id(socket),
    do: "agent_bridge_socket:#{socket.assigns.user_id}:#{socket.assigns.computer_id}"
end
