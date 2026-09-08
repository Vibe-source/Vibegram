defmodule VibeWeb.RelayChannel do
  @moduledoc """
  Phoenix Channel for the VibeNet relay network.
  """

  use VibeWeb, :channel

  alias Vibe.RelayRegistry

  @impl true
  def join("relay:directory", _payload, socket) do
    relays = RelayRegistry.list_public_relays()
    {:ok, %{relays: relays}, socket}
  end

  def join("relay:lookup", %{"invite_code" => code}, socket) do
    case RelayRegistry.find_by_invite_code(code) do
      {:ok, relay} ->
        {:ok, relay, socket}

      :not_found ->
        {:error, %{reason: "relay_not_found"}}
    end
  end

  def join("relay:" <> relay_id, %{"role" => "client"} = payload, socket) do
    user_id = socket.assigns.user_id

    case RelayRegistry.get_relay(relay_id) do
      :not_found ->
        {:error, %{reason: "relay_not_found"}}

      {:ok, relay} ->
        if client_authorized?(relay, user_id, payload) do
          socket =
            socket
            |> assign(:relay_id, relay_id)
            |> assign(:role, "client")

          {:ok, socket}
        else
          {:error, %{reason: "forbidden"}}
        end
    end
  end

  def join("relay:" <> relay_id, payload, socket) do
    user_id = socket.assigns.user_id
    invite_code = payload["invite_code"] || payload["inviteCode"]
    invite_key = payload["invite_key"] || payload["inviteKey"]
    is_public = payload["is_public"] || payload["isPublic"] || false
    name = payload["name"] || "Unnamed Relay"
    max_peers = payload["max_peers"] || payload["maxPeers"] || 5
    region = payload["region"] || detect_region(socket)

    case RelayRegistry.register_relay(%{
           relay_id: relay_id,
           user_id: user_id,
           invite_code: invite_code,
           invite_key: invite_key,
           is_public: is_public,
           name: name,
           max_peers: max_peers,
           current_peers: 0,
           region: region,
           started_at: System.system_time(:second),
           last_heartbeat_at: System.system_time(:second),
           capabilities: payload["capabilities"] || []
         }) do
      :ok ->
        if is_public do
          VibeWeb.Endpoint.broadcast!("relay:directory", "relay_added", %{
            relay_id: relay_id,
            name: name,
            max_peers: max_peers,
            current_peers: 0,
            region: region,
            invite_code: invite_code
          })
        end

        socket =
          socket
          |> assign(:relay_id, relay_id)
          |> assign(:role, "relay")

        {:ok, socket}

      {:error, :forbidden} ->
        {:error, %{reason: "forbidden"}}

      {:error, reason} ->
        {:error, %{reason: to_string(reason)}}
    end
  end

  # ─── Peer signaling (client pushes these to reach the relay host) ─────

  @impl true
  def handle_in("peer_connect", %{"shared_secret" => shared_secret}, socket) do
    _ = shared_secret

    broadcast_from!(socket, "peer_connect", %{
      peer_id: socket.assigns.user_id,
      transport: "packet_mesh",
      shared_secret_redacted: true
    })

    {:noreply, socket}
  end

  def handle_in("peer_connect", payload, socket) do
    broadcast_from!(socket, "peer_connect", payload)
    {:noreply, socket}
  end

  def handle_in("peer_disconnect", payload, socket) do
    broadcast_from!(socket, "peer_disconnect", payload)
    {:noreply, socket}
  end

  # ─── Data forwarding ─────────────────────────────────────────────

  def handle_in("peer_data", %{"peer_id" => peer_id, "data" => data}, socket) do
    broadcast_from!(socket, "peer_data", %{
      peer_id: peer_id,
      data: data
    })

    {:noreply, socket}
  end

  def handle_in("peer_data", %{"data" => data}, socket) do
    broadcast_from!(socket, "peer_data", %{
      peer_id: socket.assigns.user_id,
      data: data
    })

    {:noreply, socket}
  end

  def handle_in("peer_accepted", payload, socket) do
    with :ok <- require_relay_role(socket) do
      broadcast!(socket, "peer_accepted", payload)

      RelayRegistry.update_relay(
        socket.assigns.relay_id,
        %{current_peers: (payload["current_peers"] || 0) + 1},
        as_user: socket.assigns.user_id
      )

      {:noreply, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("peer_rejected", payload, socket) do
    with :ok <- require_relay_role(socket) do
      broadcast!(socket, "peer_rejected", payload)
      {:noreply, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("peer_kicked", payload, socket) do
    with :ok <- require_relay_role(socket) do
      broadcast!(socket, "peer_disconnect", payload)
      {:noreply, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("announce", payload, socket) do
    with :ok <- require_relay_role(socket) do
      relay_id = socket.assigns.relay_id
      region = payload["region"] || detect_region(socket)

      case RelayRegistry.update_relay(
             relay_id,
             %{
               is_public: true,
               current_peers: payload["current_peers"] || 0,
               name: payload["name"],
               max_peers: payload["max_peers"],
               invite_code: payload["invite_code"] || payload["inviteCode"],
               invite_key: payload["invite_key"] || payload["inviteKey"],
               region: region,
               capabilities: payload["capabilities"] || [],
               last_heartbeat_at: System.system_time(:second)
             },
             as_user: socket.assigns.user_id
           ) do
        :ok ->
          VibeWeb.Endpoint.broadcast!("relay:directory", "relay_added", %{
            relay_id: relay_id,
            name: payload["name"] || "Relay Node",
            max_peers: payload["max_peers"] || 5,
            current_peers: payload["current_peers"] || 0,
            region: region,
            invite_code: payload["invite_code"] || payload["inviteCode"]
          })

          {:reply, :ok, socket}

        :not_found ->
          {:reply, {:error, %{reason: "relay_not_found"}}, socket}

        {:error, :forbidden} ->
          {:reply, {:error, %{reason: "forbidden"}}, socket}
      end
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("heartbeat", payload, socket) do
    with :ok <- require_relay_role(socket) do
      relay_id = socket.assigns.relay_id

      case RelayRegistry.update_relay(
             relay_id,
             %{
               current_peers: payload["current_peers"] || 0,
               capabilities: payload["capabilities"] || [],
               last_heartbeat_at: System.system_time(:second)
             },
             as_user: socket.assigns.user_id
           ) do
        :ok ->
          {:reply, :ok, socket}

        :not_found ->
          {:reply, {:error, %{reason: "relay_not_found"}}, socket}

        {:error, :forbidden} ->
          {:reply, {:error, %{reason: "forbidden"}}, socket}
      end
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("mesh_fragment", payload, socket) do
    case Vibe.MeshAssembler.submit_fragment(payload) do
      {:ok, reconstructed_payload} ->
        broadcast!(socket, "mesh_assembled", %{
          set_id: payload["set_id"],
          payload: Base.encode64(reconstructed_payload),
          from_relay: socket.assigns.relay_id
        })

        {:reply, :ok, socket}

      :pending ->
        {:reply, {:ok, %{status: "pending"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("update_status", payload, socket) do
    with :ok <- require_relay_role(socket) do
      relay_id = socket.assigns.relay_id

      updates =
        payload
        |> Enum.reduce(%{}, fn
          {"current_peers", v}, acc -> Map.put(acc, :current_peers, v)
          {"name", v}, acc when is_binary(v) -> Map.put(acc, :name, v)
          {"max_peers", v}, acc -> Map.put(acc, :max_peers, v)
          _, acc -> acc
        end)

      case RelayRegistry.update_relay(relay_id, updates, as_user: socket.assigns.user_id) do
        :ok ->
          VibeWeb.Endpoint.broadcast!("relay:directory", "relay_updated", %{
            relay_id: relay_id,
            current_peers: payload["current_peers"] || 0
          })

          {:reply, :ok, socket}

        :not_found ->
          {:reply, {:error, %{reason: "relay_not_found"}}, socket}

        {:error, :forbidden} ->
          {:reply, {:error, %{reason: "forbidden"}}, socket}
      end
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("ping_relay", %{"relay_id" => relay_id}, socket) do
    {:reply, {:ok, %{relay_id: relay_id, pong_at: System.system_time(:millisecond)}}, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:role] == "relay" do
      relay_id = socket.assigns[:relay_id]
      user_id = socket.assigns[:user_id]

      if relay_id do
        case RelayRegistry.unregister_relay(relay_id, as_user: user_id) do
          :ok ->
            VibeWeb.Endpoint.broadcast!("relay:directory", "relay_removed", %{
              relay_id: relay_id
            })

            VibeWeb.Endpoint.broadcast!("relay:#{relay_id}", "relay_closed", %{})

          _ ->
            :ok
        end
      end
    end

    :ok
  end

  # ─── Authorization helpers ─────────────────────────────────────

  defp require_relay_role(socket) do
    if socket.assigns[:role] == "relay" do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp client_authorized?(relay, user_id, payload) do
    cond do
      RelayRegistry.relay_public?(relay) ->
        true

      RelayRegistry.relay_user_id(relay) == user_id ->
        true

      invite_credential_matches?(relay, payload) ->
        true

      true ->
        false
    end
  end

  defp invite_credential_matches?(relay, payload) do
    provided_code =
      payload_string(payload, "invite_code") || payload_string(payload, "inviteCode")

    provided_key = payload_string(payload, "invite_key") || payload_string(payload, "inviteKey")

    stored_code = RelayRegistry.relay_invite_code(relay)
    stored_key = RelayRegistry.relay_invite_key(relay)

    credential_match?(stored_code, provided_code) or credential_match?(stored_key, provided_key)
  end

  defp payload_string(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp credential_match?(stored, provided)
       when is_binary(stored) and is_binary(provided) and stored != "" and provided != "" do
    byte_size(stored) == byte_size(provided) and Plug.Crypto.secure_compare(stored, provided)
  end

  defp credential_match?(_, _), do: false

  defp detect_region(_socket) do
    "unknown"
  end
end
