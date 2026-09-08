defmodule VibeWeb.Plugs.InternalServiceAuth do
  @moduledoc """
  Verifies `vibe-internal-auth/v1` signed requests from the agent-runtime
  (docs/agent-platform-v1.md §3.1).
  """

  import Plug.Conn
  require Logger

  @allowed_services ["agent-runtime"]
  @signed_headers ~w(x-vibe-service x-vibe-timestamp x-vibe-nonce x-vibe-signature)

  def init(opts), do: opts

  def call(conn, _opts) do
    case internal_key() do
      key when is_binary(key) and key != "" ->
        verify(conn, key)

      _ ->
        Logger.error("[InternalServiceAuth] VIBE_INTERNAL_HMAC_KEY is unset")
        respond(conn, :service_unavailable, "internal_auth_unconfigured")
    end
  end

  defp verify(conn, key) do
    method = conn.method
    path = path_with_query(conn)
    body = conn.assigns[:raw_body] || ""
    headers = header_map(conn)

    case VibeContracts.ServiceAuth.verify(key, method, path, body, headers,
           allowed_services: @allowed_services
         ) do
      :ok ->
        conn

      {:error, reason} ->
        Logger.warning("[InternalServiceAuth] rejected path=#{path} reason=#{inspect(reason)}")
        respond(conn, :unauthorized, "unauthorized")
    end
  end

  defp header_map(conn) do
    Enum.reduce(@signed_headers, %{}, fn name, acc ->
      case get_req_header(conn, name) do
        [value | _] -> Map.put(acc, name, value)
        [] -> acc
      end
    end)
  end

  defp path_with_query(%{query_string: ""} = conn), do: conn.request_path
  defp path_with_query(conn), do: conn.request_path <> "?" <> conn.query_string

  defp respond(conn, status, error) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: error})
    |> halt()
  end

  defp internal_key, do: System.get_env("VIBE_INTERNAL_HMAC_KEY")
end
