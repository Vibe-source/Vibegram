defmodule VibeWeb.UserSocket do
  use Phoenix.Socket

  # A Socket handler

  # # Channels Personal channel for calls/notifications
  channel("user:*", VibeWeb.UserChannel)
  # Chat rooms
  channel("chat:*", VibeWeb.ChatChannel)
  # AI Agent streaming
  channel("agent:*", VibeWeb.AgentChannel)
  # Owner-only live view of an agent's browser
  channel("computer:*", VibeWeb.ComputerChannel)
  # VibeNet peer relay network
  channel("relay:*", VibeWeb.RelayChannel)

  # Socket params are passed from the client and can be used to verify and.
  @impl true
  def connect(params, socket, connect_info) do
    case extract_connect_token(params, connect_info) do
      nil ->
        :error

      t when is_binary(t) and t != "" ->
        case Vibe.Accounts.get_user_by_token(t) do
          {:ok, user} ->
            {:ok, assign(socket, :user_id, user.id)}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Resolves the login token for a WebSocket connect.
  """
  def extract_connect_token(params, connect_info) do
    case header_token(connect_info) do
      nil -> query_token(params)
      token -> token
    end
  end

  defp header_token(%{x_headers: headers}) when is_list(headers) do
    Enum.find_value(headers, fn
      {"x-vibe-auth", value} when is_binary(value) -> parse_auth_header_value(value)
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
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
