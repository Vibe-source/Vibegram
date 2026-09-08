defmodule VibeWeb.AgentBridgeController do
  @moduledoc """
  REST endpoints for pairing a user's computer (the agent bridge daemon).
  """
  use VibeWeb, :controller
  require Logger

  alias Vibe.AgentBridge

  # POST /api/agent-bridge/pairing  (authenticated phone)
  def request_pairing(conn, _params) do
    user_id = conn.assigns.current_user.id
    result = AgentBridge.request_pairing(user_id)
    json(conn, result)
  end

  # POST /api/agent-bridge/pair  (daemon — body:
  def pair(conn, params) do
    code = params["pairing_code"] || params["code"] || ""
    device_label = params["device_label"] || params["device"] || "computer"

    case AgentBridge.redeem_pairing(code, device_label) do
      {:ok, %{user_id: user_id, bridge_token: token, computer_id: computer_id}} ->
        Logger.info("[AgentBridge] paired computer for user=#{user_id} device=#{device_label}")
        json(conn, %{bridge_token: token, user_id: user_id, computer_id: computer_id})

      {:error, :invalid_code} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_code"})

      {:error, :expired} ->
        conn |> put_status(:bad_request) |> json(%{error: "expired"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  # POST /api/agent-bridge/request  (daemon.
  def start_request(conn, params) do
    device_label = params["device_label"] || params["device"] || "computer"
    json(conn, AgentBridge.create_request(device_label))
  end

  # POST /api/agent-bridge/authorize  (authenticated phone.
  def authorize(conn, params) do
    request_id = params["request_id"] || params["requestId"] || ""
    user_id = conn.assigns.current_user.id

    case AgentBridge.authorize_request(request_id, user_id) do
      :ok ->
        Logger.info("[AgentBridge] authorized request for user=#{user_id}")
        json(conn, %{authorized: true})

      {:error, :already_authorized} ->
        json(conn, %{authorized: true})

      {:error, :invalid_request} ->
        conn |> put_status(:not_found) |> json(%{error: "invalid_request"})

      {:error, :expired} ->
        conn |> put_status(:bad_request) |> json(%{error: "expired"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  # POST /api/agent-bridge/claim  (daemon — no auth; proves the device_secret)
  def claim(conn, params) do
    request_id = params["request_id"] || params["requestId"] || ""
    device_secret = params["device_secret"] || params["deviceSecret"] || ""

    case AgentBridge.claim_request(request_id, device_secret) do
      {:ok, %{user_id: user_id, bridge_token: token, computer_id: computer_id}} ->
        Logger.info("[AgentBridge] claimed token for user=#{user_id}")
        json(conn, %{bridge_token: token, user_id: user_id, computer_id: computer_id})

      {:error, :pending} ->
        conn |> put_status(:accepted) |> json(%{status: "pending"})

      {:error, :expired} ->
        conn |> put_status(:bad_request) |> json(%{error: "expired"})

      {:error, :invalid} ->
        conn |> put_status(:forbidden) |> json(%{error: "invalid"})

      {:error, _reason} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_request"})
    end
  end

  # GET /api/agent-bridge/status  (authenticated phone)
  def status(conn, _params) do
    user_id = conn.assigns.current_user.id
    json(conn, AgentBridge.status(user_id))
  end

  # DELETE /api/agent-bridge  (authenticated phone)
  def revoke(conn, _params) do
    user_id = conn.assigns.current_user.id
    {:ok, count} = AgentBridge.revoke_all(user_id)
    json(conn, %{revoked: count})
  end
end
