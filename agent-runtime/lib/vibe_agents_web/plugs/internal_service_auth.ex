defmodule VibeAgentsWeb.Plugs.InternalServiceAuth do
  @moduledoc "`vibe-internal-auth/v1` on every /internal/v1/* route — core → runtime only."
  import Plug.Conn
  require Logger

  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    key = Application.get_env(:vibe_agents, :internal_hmac_key) || ""
    body = conn.assigns[:raw_body] || ""
    path = path_with_query(conn)

    case VibeContracts.ServiceAuth.verify(key, conn.method, path, body, conn.req_headers,
           allowed_services: ["core"]
         ) do
      :ok ->
        conn

      {:error, reason} ->
        Logger.warning("[InternalServiceAuth] rejected #{conn.method} #{path}: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "unauthorized", "reason" => to_string(reason)}))
        |> halt()
    end
  end

  defp path_with_query(%{request_path: path, query_string: ""}), do: path
  defp path_with_query(%{request_path: path, query_string: qs}), do: path <> "?" <> qs
end
