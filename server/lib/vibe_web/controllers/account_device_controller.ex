defmodule VibeWeb.AccountDeviceController do
  use VibeWeb, :controller

  alias Vibe.Accounts

  # GET /api/account/devices
  def index(conn, _params) do
    user_id = conn.assigns.current_user.id
    current_identifier = current_device_identifier(conn)
    devices = Accounts.list_devices(user_id)
    json(conn, %{devices: Enum.map(devices, &device_json(&1, current_identifier))})
  end

  def register_current(conn, params) do
    identifier = params["deviceId"] || current_device_identifier(conn)

    if is_nil(identifier) or identifier == "" do
      conn |> put_status(400) |> json(%{error: "X-Vibe-Device-ID header or deviceId is required"})
    else
      attrs = %{
        "device_identifier" => identifier,
        "name" => params["name"],
        "platform" => params["platform"],
        "public_key" => params["publicKey"]
      }

      case Accounts.register_device(conn.assigns.current_user.id, attrs, revive: true) do
        {:ok, device} ->
          json(conn, %{device: device_json(device, identifier)})

        {:error, changeset} ->
          conn
          |> put_status(422)
          |> json(%{error: "Invalid device", details: changeset_errors(changeset)})
      end
    end
  end

  def sessions(conn, _params) do
    current_identifier = current_device_identifier(conn)
    sessions = Accounts.list_sessions(conn.assigns.current_user.id)
    json(conn, %{sessions: Enum.map(sessions, &device_session_json(&1, current_identifier))})
  end

  def delete_session(conn, %{"id" => session_id}) do
    case current_device_identifier(conn) do
      nil ->
        conn |> put_status(400) |> json(%{error: "X-Vibe-Device-ID header is required"})

      identifier ->
        case Accounts.revoke_session(conn.assigns.current_user.id, session_id, identifier) do
          {:ok, _} ->
            send_resp(conn, 204, "")

          {:error, :current_session} ->
            conn
            |> put_status(409)
            |> json(%{error: "The current session cannot be revoked"})

          {:error, :not_found} ->
            conn |> put_status(404) |> json(%{error: "Session not found"})
        end
    end
  end

  # DELETE /api/account/devices/:id
  def delete(conn, %{"id" => device_id}) do
    user_id = conn.assigns.current_user.id

    case Accounts.revoke_device(user_id, device_id) do
      {:ok, _device} ->
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Device not found"})
    end
  end

  # POST /api/account/devices/pairing Unauthenticated:
  def start_pairing(conn, params) do
    attrs = %{
      "requester_device_identifier" => params["requesterDeviceId"],
      "requester_name" => params["requesterName"],
      "requester_platform" => params["platform"],
      "requester_public_key" => params["requesterPublicKey"]
    }

    case Accounts.start_link_request(attrs) do
      {:ok, code, request} ->
        conn
        |> put_status(:created)
        |> json(%{code: code, expiresAt: request.expires_at})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "Invalid pairing request", details: changeset_errors(changeset)})
    end
  end

  # POST /api/account/devices/pairing/:code/approve Authenticated:
  def approve_pairing(conn, %{"code" => code} = params) do
    user_id = conn.assigns.current_user.id
    wrapped_key_envelope = params["wrappedKeyEnvelope"]

    case Accounts.approve_link_request(user_id, code, wrapped_key_envelope) do
      {:ok, _request} ->
        json(conn, %{success: true})

      {:error, reason} when is_atom(reason) ->
        conn |> put_status(410) |> json(%{error: to_string(reason)})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "Invalid approval", details: changeset_errors(changeset)})
    end
  end

  # POST /api/account/devices/pairing/:code/claim Unauthenticated:
  def claim_pairing(conn, %{"code" => code}) do
    case Accounts.claim_link_request(code) do
      {:ok,
       %{user_id: user_id, device: device, session_token: token, wrapped_key_envelope: envelope}} ->
        json(conn, %{
          userId: user_id,
          device: device_json(device),
          sessionToken: token,
          wrappedKeyEnvelope: envelope
        })

      {:error, reason} when is_atom(reason) ->
        conn |> put_status(410) |> json(%{error: to_string(reason)})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "Unable to claim pairing request", details: changeset_errors(changeset)})
    end
  end

  defp device_json(device, current_identifier \\ nil) do
    %{
      id: device.id,
      deviceIdentifier: device.device_identifier,
      name: device.name,
      platform: device.platform,
      current: device.device_identifier == current_identifier,
      lastSeenAt: device.last_seen_at,
      createdAt: device.inserted_at
    }
  end

  defp device_session_json(session, current_identifier) do
    %{
      id: session.id,
      deviceId: session.account_device_id,
      name: session.account_device.name,
      platform: session.account_device.platform,
      lastSeenAt: session.last_used_at || session.inserted_at,
      createdAt: session.inserted_at,
      expiresAt: session.expires_at,
      current: session.account_device.device_identifier == current_identifier
    }
  end

  defp current_device_identifier(conn) do
    case get_req_header(conn, "x-vibe-device-id") do
      [identifier | _] ->
        case String.trim(identifier) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
