defmodule VibeWeb.ApiController do
  use VibeWeb, :controller

  def health(conn, _params) do
    json(conn, %{
      status: "ok",
      timestamp: DateTime.utc_now(),
      version: "1.0.0",
      backend: "elixir_phoenix"
    })
  end

  def ping(conn, _params) do
    json(conn, %{pong: System.system_time(:millisecond)})
  end

  @doc "Liveness+DB readiness probe for a load balancer / orchestrator; never raises."
  def ready(conn, _params) do
    if db_ok?() do
      json(conn, %{status: "ready", db: "ok", node: node()})
    else
      conn |> put_status(503) |> json(%{status: "not_ready", db: "error", node: node()})
    end
  end

  defp db_ok? do
    case Vibe.Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _result} -> true
      {:error, _reason} -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def info(conn, _params) do
    json(conn, %{
      name: "Vibe Server (Elixir)",
      version: "1.0.0",
      features: ["e2ee", "p2p", "push", "media"],
      limits: %{maxFileSize: 52428800},
      shareBaseUrl: Vibe.Links.share_base_url()
    })
  end

  def servers(conn, _params) do

    scheme = case get_req_header(conn, "x-forwarded-proto") do
      [proto | _] -> proto
      _ -> to_string(conn.scheme)
    end

    host = case get_req_header(conn, "x-forwarded-host") do
      [host | _] -> host
      _ -> conn.host
    end

    url = if (scheme == "https" and conn.port == 443) or (scheme == "http" and conn.port == 80) do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{conn.port}"
    end

    url = if String.contains?(url, "localhost") and System.get_env("PHX_HOST") != nil and System.get_env("PHX_HOST") != "localhost" do
       "https://#{System.get_env("PHX_HOST")}"
    else
       url
    end

    json(conn, %{
      servers: [
        %{
          id: "primary",
          url: url,
          name: "Primary Server",
          status: "online"
        }
      ]
    })
  end

  def vapid_key(conn, _params) do
    vapid_public_key = System.get_env("VAPID_PUBLIC_KEY") || ""
    json(conn, %{publicKey: vapid_public_key})
  end

  def turn_credentials(conn, _params) do
    turn_url = System.get_env("TURN_URL")
    turn_username = System.get_env("TURN_USERNAME")
    turn_credential = System.get_env("TURN_CREDENTIAL")
    turn_secret = System.get_env("TURN_SECRET")

    ttl = 86_400

    ice_servers =
      cond do
        is_binary(turn_url) and turn_url != "" and is_binary(turn_username) ->
          [
            %{urls: turn_url, username: turn_username, credential: turn_credential || ""}
          ]

        is_binary(turn_url) and turn_url != "" and is_binary(turn_secret) and turn_secret != "" ->
          timestamp = System.system_time(:second) + ttl
          username = "#{timestamp}:vibe"
          credential = :crypto.mac(:hmac, :sha, turn_secret, username) |> Base.encode64()

          [
            %{urls: turn_url, username: username, credential: credential}
          ]

        true ->
          [
            %{
              urls: "turn:openrelay.metered.ca:443?transport=tcp",
              username: "openrelayproject",
              credential: "openrelayproject"
            },
            %{
              urls: "turns:openrelay.metered.ca:443?transport=tcp",
              username: "openrelayproject",
              credential: "openrelayproject"
            }
          ]
      end

    json(conn, %{
      iceServers: ice_servers,
      ttl: ttl,
      iceTransportPolicy: if(System.get_env("FORCE_RELAY") == "true", do: "relay", else: "all")
    })
  end

  def index(conn, _params) do

    path = "/app/priv/static/index.html"

    final_path =
      if File.exists?(path) do
        path
      else
        Application.app_dir(:vibe, "priv/static/index.html")
      end

    if File.exists?(final_path) do
      conn
      |> put_resp_header("content-type", "text/html")
      |> send_file(200, final_path)
    else
      conn
      |> put_status(404)
      |> json(%{error: "Client not found. Please run build."})
    end
  end
end
