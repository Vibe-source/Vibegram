defmodule VibeWeb.PlatformsController do
  use VibeWeb, :controller

  require Logger

  alias Vibe.Platforms

  @doc "GET /api/platforms/catalog — multi-platform connector catalog."
  def catalog(conn, _params) do
    json(conn, %{items: Platforms.catalog()})
  end

  @doc "GET /api/platforms/connections — user's connected platforms (no tokens)."
  def index(conn, _params) do
    user_id = conn.assigns.current_user.id

    items =
      user_id
      |> Platforms.list_connections()
      |> Enum.map(&Platforms.connection_payload/1)

    json(conn, %{items: items})
  end

  @doc "GET /api/platforms/connections/:id"
  def show(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id

    case Platforms.get_connection(user_id, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      connection ->
        json(conn, %{connection: Platforms.connection_payload(connection)})
    end
  end

  @doc "POST /api/platforms/connections/:provider/authorize — start OAuth."
  def authorize(conn, %{"provider" => provider} = params) do
    user_id = conn.assigns.current_user.id
    scopes = normalize_scopes(params["scopes"])

    opts = if scopes == [], do: [], else: [scopes: scopes]

    case Platforms.start_authorize(user_id, provider, opts) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :oauth_not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: "oauth_not_configured",
          message:
            "This provider is not configured on the server. Set OAuth client credentials (e.g. GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET)."
        })

      {:error, :unknown_provider} ->
        conn |> put_status(:not_found) |> json(%{error: "unknown_provider"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "authorize_failed", detail: inspect(reason)})
    end
  end

  @doc "GET /api/platforms/oauth/:provider/callback — browser redirect from provider."
  def oauth_callback(conn, %{"provider" => provider} = params) do
    code = params["code"]
    state = params["state"]
    error = params["error"]

    result =
      cond do
        is_binary(error) and error != "" ->
          {:error, error}

        is_binary(code) and is_binary(state) ->
          Platforms.complete_oauth(provider, code, state)

        true ->
          {:error, "missing_code_or_state"}
      end

    {status, query} =
      case result do
        {:ok, connection} ->
          {"success",
           %{
             "status" => "success",
             "provider" => provider,
             "connectionId" => connection.id,
             "login" => connection.external_account_login || ""
           }}

        {:error, reason} ->
          Logger.warning("[PlatformsController] oauth callback failed: #{inspect(reason)}")

          {"error",
           %{
             "status" => "error",
             "provider" => provider,
             "error" => to_string(reason_atom(reason))
           }}
      end

    redirect_to_app(conn, status, query)
  end

  @doc "DELETE /api/platforms/connections/:id"
  def revoke(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id

    case Platforms.revoke_connection(user_id, id) do
      {:ok, _} -> send_resp(conn, 204, "")
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  @doc "POST /api/platforms/connections/:id/grants"
  def upsert_grant(conn, %{"id" => id} = params) do
    user_id = conn.assigns.current_user.id

    case Platforms.upsert_grant(user_id, id, params) do
      {:ok, grant} ->
        json(conn, %{grant: Platforms.grant_payload(grant)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :invalid_grantee} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_grantee"})

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_grant", detail: inspect(cs.errors)})
    end
  end

  @doc "DELETE /api/platforms/connections/:id/grants/:grant_id"
  def revoke_grant(conn, %{"id" => id, "grant_id" => grant_id}) do
    user_id = conn.assigns.current_user.id

    case Platforms.revoke_grant(user_id, id, grant_id) do
      :ok -> send_resp(conn, 204, "")
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  @doc """
  GET /api/platforms/usable?granteeType=bridge_agent&granteeId=claude
  Lists connections the grantee may use (capability names only).
  """
  def usable(conn, params) do
    user_id = conn.assigns.current_user.id
    grantee_type = params["granteeType"] || params["grantee_type"] || "bridge_agent"
    grantee_id = params["granteeId"] || params["grantee_id"] || "claude"

    items = Platforms.list_usable_for_grantee(user_id, grantee_type, grantee_id)
    json(conn, %{items: items})
  end

  @doc """
  POST /api/platforms/tools/invoke Bridge / client proxy for server-side platform actions
  (tokens never leave server).
  """
  def invoke_tool(conn, params) do
    user_id = conn.assigns.current_user.id
    grantee_type = params["granteeType"] || params["grantee_type"] || "bridge_agent"
    grantee_id = params["granteeId"] || params["grantee_id"] || "claude"

    case Platforms.invoke(user_id, grantee_type, grantee_id, params) do
      {:ok, result} ->
        json(conn, result)

      {:error, :no_grant} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "no_grant",
          message: "No active platform grant for this agent. Connect the app and enable access."
        })

      {:error, {:capability_not_allowed, allowed}} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "capability_not_allowed", allowed: allowed})

      {:error, :oauth_not_configured} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "oauth_not_configured"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invoke_failed", detail: safe_reason(reason)})
    end
  end


  defp redirect_to_app(conn, _status, query) do
    deep_link = "vibe://platforms/oauth?" <> URI.encode_query(query)
    web_fallback = web_fallback_url(query)

    html = """
    <!DOCTYPE html>
    <html><head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>Vibe · Connected</title>
      <meta http-equiv="refresh" content="0;url=#{Plug.HTML.html_escape(deep_link)}"/>
      <style>
        body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#0b0b0d;color:#f5f5f7}
        .card{max-width:360px;padding:28px;text-align:center}
        a{color:#5b8cff}
      </style>
    </head><body>
      <div class="card">
        <h1>#{if query["status"] == "success", do: "Connected", else: "Connection failed"}</h1>
        <p>Returning to Vibe…</p>
        <p><a href="#{Plug.HTML.html_escape(deep_link)}">Open Vibe</a></p>
        <p><a href="#{Plug.HTML.html_escape(web_fallback)}">Continue in browser</a></p>
      </div>
      <script>window.location.replace(#{Jason.encode!(deep_link)});</script>
    </body></html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp web_fallback_url(query) do
    base =
      System.get_env("VIBE_WEB_BASE_URL") ||
        "https://vibegram.io"

    base <> "/settings/connectors?" <> URI.encode_query(query)
  end

  defp normalize_scopes(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_scopes(_), do: []

  defp reason_atom(reason) when is_atom(reason), do: reason
  defp reason_atom(reason) when is_binary(reason), do: reason
  defp reason_atom({reason, _}) when is_atom(reason), do: reason
  defp reason_atom(_), do: :oauth_failed

  defp safe_reason(reason) when is_atom(reason), do: to_string(reason)
  defp safe_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp safe_reason({:github_http, status, body}), do: "github_http_#{status}:#{body}"
  defp safe_reason(reason), do: String.slice(inspect(reason), 0, 200)
end
