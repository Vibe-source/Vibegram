defmodule VibeWeb.Plugs.ApiAuth do
  @moduledoc """
  Auth plug for the JSON REST API.
  """

  import Plug.Conn
  require Logger

  alias Vibe.Accounts

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    required? = Keyword.get(opts, :required, false)

    case extract_bearer(conn) do
      nil ->
        if required?, do: unauthorized(conn, "Missing bearer token"), else: conn

      token ->
        case Accounts.get_user_by_token(token) do
          {:ok, user} ->
            conn
            |> assign(:current_user, user)
            |> assign(:current_auth_token, token)

          {:error, :token_expired} ->
            unauthorized(conn, "Token expired")

          _ ->
            unauthorized(conn, "Invalid token")
        end
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Unauthorized", message: message}))
    |> halt()
  end
end
