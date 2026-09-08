defmodule VibeWeb.BridgeController do
  use VibeWeb, :controller

  alias Vibe.ChatBridge
  alias Vibe.PacketBootstrap
  alias Vibe.RelayRegistry

  def bundle(conn, _params) do
    case ChatBridge.bundle() do
      {:ok, bundle} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(bundle)

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "bridge_bundle_missing"})

      {:error, :invalid_bundle} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "bridge_bundle_invalid"})
    end
  end

  def open_session(conn, params) do
    with {:ok, payload} <- ChatBridge.open_session(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def send(conn, params) do
    with {:ok, payload} <- ChatBridge.send_event(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def poll(conn, params) do
    with {:ok, payload} <- ChatBridge.poll(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def ack(conn, params) do
    with {:ok, payload} <- ChatBridge.ack_event(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def home_snapshot(conn, params) do
    with {:ok, payload} <- ChatBridge.home_snapshot(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def chat_history(conn, params) do
    with {:ok, payload} <- ChatBridge.chat_history(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def peer_key(conn, params) do
    with {:ok, payload} <- ChatBridge.peer_key(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def packet_bootstrap(conn, _params) do
    {:ok, payload} = PacketBootstrap.issue_for_user(conn.assigns.current_user)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(payload)
  end

  def register_relay(conn, params) do
    user = conn.assigns.current_user

    relay_id =
      normalize_string(params["relayId"] || params["relay_id"]) ||
        "relay_#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}"

    name = normalize_string(params["name"]) || "Relay"
    invite_code = normalize_string(params["inviteCode"] || params["invite_code"])

    with {:ok, descriptor} <- normalize_relay_descriptor(relay_id, params),
         :ok <- ensure_relay_writable(relay_id, user.id) do
      share_data =
        descriptor
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      share_link = "vibe://bridge?d=#{share_data}"

      relay_body = %{
        relay_id: relay_id,
        user_id: user.id,
        invite_code: invite_code,
        invite_key: nil,
        is_public: false,
        name: name,
        max_peers: 5,
        current_peers: 0,
        region: "unknown",
        started_at: System.system_time(:second),
        last_heartbeat_at: System.system_time(:second),
        capabilities: descriptor[:capabilities] || [],
        external_ip: descriptor[:host],
        bridge_url: descriptor[:baseUrl],
        share_link: share_link,
        bridge_descriptor: descriptor
      }

      relay_result =
        case RelayRegistry.get_relay(relay_id) do
          :not_found ->
            case RelayRegistry.register_relay(relay_body) do
              :ok -> :ok
              {:error, :forbidden} -> {:error, :forbidden}
              {:error, reason} -> {:error, reason}
            end

          {:ok, _existing} ->
            RelayRegistry.update_relay(
              relay_id,
              %{
                invite_code: invite_code,
                name: name,
                external_ip: descriptor[:host],
                bridge_url: descriptor[:baseUrl],
                share_link: share_link,
                bridge_descriptor: descriptor,
                capabilities: descriptor[:capabilities] || [],
                last_heartbeat_at: System.system_time(:second)
              },
              as_user: user.id
            )
        end

      case relay_result do
        :ok ->
          VibeWeb.Endpoint.broadcast!("relay:directory", "relay_updated", %{
            relay_id: relay_id,
            name: name,
            current_peers: 0,
            invite_code: invite_code,
            external_ip: descriptor[:host],
            bridge_url: descriptor[:baseUrl],
            share_link: share_link,
            bridge_descriptor: descriptor
          })

          json(conn, %{
            relayId: relay_id,
            userId: user.id,
            externalIp: descriptor[:host],
            bridgeUrl: descriptor[:baseUrl],
            shareLink: share_link,
            shareData: share_data,
            descriptor: descriptor,
            name: name,
            inviteCode: invite_code
          })

        {:error, :forbidden} ->
          conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})

        :not_found ->
          conn |> put_status(:not_found) |> json(%{error: "relay_not_found"})
      end
    else
      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  # Reject cross-user takeover of an existing relay id.
  defp ensure_relay_writable(relay_id, user_id) do
    case RelayRegistry.get_relay(relay_id) do
      :not_found ->
        :ok

      {:ok, existing} ->
        if RelayRegistry.relay_user_id(existing) == user_id do
          :ok
        else
          {:error, :forbidden}
        end
    end
  end

  def resolve_relay_bridge(conn, params) do
    invite_code =
      normalize_string(params["inviteCode"] || params["invite_code"])

    with code when is_binary(code) <- invite_code,
         {:ok, relay} <- RelayRegistry.find_by_invite_code(code),
         descriptor when is_map(descriptor) <-
           relay[:bridge_descriptor] || relay["bridge_descriptor"] do
      json(conn, %{
        inviteCode: code,
        relayId: relay[:relay_id] || relay["relay_id"],
        name: relay[:name] || relay["name"],
        bridgeUrl: relay[:bridge_url] || relay["bridge_url"],
        externalIp: relay[:external_ip] || relay["external_ip"],
        shareLink: relay[:share_link] || relay["share_link"],
        descriptor: descriptor
      })
    else
      nil ->
        conn |> put_status(:bad_request) |> json(%{error: "invite_code_required"})

      :not_found ->
        conn |> put_status(:not_found) |> json(%{error: "relay_not_found"})

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "bridge_not_found"})
    end
  end

  defp normalize_relay_descriptor(relay_id, params) do
    now_ms = System.system_time(:millisecond)

    raw =
      params["descriptor"] ||
        params["bridgeDescriptor"] ||
        params["bridge_descriptor"] ||
        params["packetDescriptor"] ||
        params["packet_descriptor"]

    with descriptor when is_map(descriptor) <- decode_descriptor(raw),
         base_url when is_binary(base_url) <-
           normalize_string(descriptor["baseUrl"] || descriptor["base_url"]),
         true <- String.starts_with?(String.downcase(base_url), "https://"),
         {:ok, uri} <- validate_public_https_uri(base_url),
         pins when is_list(pins) and pins != [] <-
           normalize_pin_list(descriptor["spkiPins"] || descriptor["spki_pins"]),
         expires_at when is_integer(expires_at) <-
           normalize_integer(descriptor["expiresAt"] || descriptor["expires_at"]),
         :ok <- validate_future_expiry(expires_at, now_ms) do
      {:ok,
       %{
         id: normalize_string(descriptor["id"]) || relay_id,
         host: uri.host,
         port: uri.port || 443,
         transport: "https",
         origin: "community",
         priority: normalize_integer(descriptor["priority"]) || 50,
         weight: normalize_integer(descriptor["weight"]) || 100,
         baseUrl: base_url,
         spkiPins: pins,
         expiresAt: expires_at,
         capabilities: normalize_string_list(descriptor["capabilities"]) || ["packet_mesh"]
       }}
    else
      nil -> {:error, :bridge_descriptor_missing}
      false -> {:error, :bridge_descriptor_must_use_https}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :bridge_descriptor_invalid}
    end
  end

  defp decode_descriptor(nil), do: nil

  defp decode_descriptor(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> nil
    end
  end

  defp decode_descriptor(value) when is_map(value), do: value
  defp decode_descriptor(_value), do: nil

  defp validate_public_https_uri(base_url) do
    uri = URI.parse(base_url)

    cond do
      is_nil(uri.host) ->
        {:error, :bridge_descriptor_host_missing}

      uri.host in ["127.0.0.1", "0.0.0.0", "::1", "localhost"] ->
        {:error, :bridge_descriptor_host_invalid}

      true ->
        {:ok, uri}
    end
  end

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp validate_future_expiry(expires_at, now_ms) when expires_at > now_ms, do: :ok
  defp validate_future_expiry(_expires_at, _now_ms), do: {:error, :bridge_descriptor_expired}

  defp normalize_pin_list(value) when is_list(value) do
    value
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_pin_list(_value), do: []

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_value), do: nil

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_value), do: nil

  defp render_bridge_error(conn, {:error, :bad_request}) do
    conn |> put_status(:bad_request) |> json(%{error: "bad_request"})
  end

  defp render_bridge_error(conn, {:error, :forbidden}) do
    conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
  end

  defp render_bridge_error(conn, {:error, :not_found}) do
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end

  defp render_bridge_error(conn, {:error, :conflict}) do
    conn |> put_status(:conflict) |> json(%{error: "conflict"})
  end

  defp render_bridge_error(conn, {:error, :unprocessable_entity}) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "unprocessable_entity"})
  end

  defp render_bridge_error(conn, {:error, reason}) do
    conn |> put_status(:bad_request) |> json(%{error: to_string(reason)})
  end
end
