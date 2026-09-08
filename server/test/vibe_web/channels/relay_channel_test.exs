defmodule VibeWeb.RelayChannelTest do
  use ExUnit.Case, async: false

  alias Vibe.RelayRegistry
  alias VibeWeb.RelayChannel

  setup do
    relay_id = "relay-ch-#{System.unique_integer([:positive])}"
    owner_id = "owner-#{System.unique_integer([:positive])}"
    other_id = "other-#{System.unique_integer([:positive])}"
    invite_code = "code-#{System.unique_integer([:positive])}"
    invite_key = "key-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = RelayRegistry.unregister_relay(relay_id)
    end)

    {:ok,
     relay_id: relay_id,
     owner_id: owner_id,
     other_id: other_id,
     invite_code: invite_code,
     invite_key: invite_key}
  end

  defp socket_for(user_id) do
    %Phoenix.Socket{
      assigns: %{user_id: user_id},
      transport_pid: self(),
      serializer: Jason
    }
  end

  defp register_private!(relay_id, owner_id, invite_code, invite_key) do
    assert :ok =
             RelayRegistry.register_relay(%{
               relay_id: relay_id,
               user_id: owner_id,
               invite_code: invite_code,
               invite_key: invite_key,
               is_public: false,
               name: "Private Relay",
               max_peers: 5,
               current_peers: 0,
               region: "test",
               started_at: System.system_time(:second),
               last_heartbeat_at: System.system_time(:second),
               capabilities: []
             })
  end

  defp register_public!(relay_id, owner_id) do
    assert :ok =
             RelayRegistry.register_relay(%{
               relay_id: relay_id,
               user_id: owner_id,
               invite_code: nil,
               invite_key: nil,
               is_public: true,
               name: "Public Relay",
               max_peers: 5,
               current_peers: 0,
               region: "test",
               started_at: System.system_time(:second),
               last_heartbeat_at: System.system_time(:second),
               capabilities: []
             })
  end

  test "private relay client join is rejected without invite", %{
    relay_id: relay_id,
    owner_id: owner_id,
    other_id: other_id,
    invite_code: invite_code,
    invite_key: invite_key
  } do
    register_private!(relay_id, owner_id, invite_code, invite_key)

    assert {:error, %{reason: "forbidden"}} =
             RelayChannel.join(
               "relay:#{relay_id}",
               %{"role" => "client"},
               socket_for(other_id)
             )
  end

  test "private relay client join is accepted with matching invite_code", %{
    relay_id: relay_id,
    owner_id: owner_id,
    other_id: other_id,
    invite_code: invite_code,
    invite_key: invite_key
  } do
    register_private!(relay_id, owner_id, invite_code, invite_key)

    assert {:ok, socket} =
             RelayChannel.join(
               "relay:#{relay_id}",
               %{"role" => "client", "invite_code" => invite_code},
               socket_for(other_id)
             )

    assert socket.assigns.role == "client"
    assert socket.assigns.relay_id == relay_id
  end

  test "private relay client join is accepted with inviteCode camelCase", %{
    relay_id: relay_id,
    owner_id: owner_id,
    other_id: other_id,
    invite_code: invite_code,
    invite_key: invite_key
  } do
    register_private!(relay_id, owner_id, invite_code, invite_key)

    assert {:ok, _socket} =
             RelayChannel.join(
               "relay:#{relay_id}",
               %{"role" => "client", "inviteCode" => invite_code},
               socket_for(other_id)
             )
  end

  test "private relay client join is accepted with matching invite_key", %{
    relay_id: relay_id,
    owner_id: owner_id,
    other_id: other_id,
    invite_code: invite_code,
    invite_key: invite_key
  } do
    register_private!(relay_id, owner_id, invite_code, invite_key)

    assert {:ok, _socket} =
             RelayChannel.join(
               "relay:#{relay_id}",
               %{"role" => "client", "invite_key" => invite_key},
               socket_for(other_id)
             )
  end

  test "owner may join their private relay as client without invite", %{
    relay_id: relay_id,
    owner_id: owner_id,
    invite_code: invite_code,
    invite_key: invite_key
  } do
    register_private!(relay_id, owner_id, invite_code, invite_key)

    assert {:ok, _socket} =
             RelayChannel.join(
               "relay:#{relay_id}",
               %{"role" => "client"},
               socket_for(owner_id)
             )
  end

  test "public relay client join is accepted without invite", %{
    relay_id: relay_id,
    owner_id: owner_id,
    other_id: other_id
  } do
    register_public!(relay_id, owner_id)

    assert {:ok, _socket} =
             RelayChannel.join(
               "relay:#{relay_id}",
               %{"role" => "client"},
               socket_for(other_id)
             )
  end

  test "non-owner cannot join as relay host for an existing id", %{
    relay_id: relay_id,
    owner_id: owner_id,
    other_id: other_id,
    invite_code: invite_code,
    invite_key: invite_key
  } do
    register_private!(relay_id, owner_id, invite_code, invite_key)

    assert {:error, %{reason: "forbidden"}} =
             RelayChannel.join(
               "relay:#{relay_id}",
               %{"name" => "Hijack", "invite_code" => "stolen"},
               socket_for(other_id)
             )

    assert {:ok, relay} = RelayRegistry.get_relay(relay_id)
    assert RelayRegistry.relay_user_id(relay) == owner_id
  end

  test "owner can join as relay host for their id", %{
    relay_id: relay_id,
    owner_id: owner_id
  } do
    assert {:ok, socket} =
             RelayChannel.join(
               "relay:#{relay_id}",
               %{"name" => "My Relay", "is_public" => false, "invite_code" => "abc"},
               socket_for(owner_id)
             )

    assert socket.assigns.role == "relay"
    assert {:ok, relay} = RelayRegistry.get_relay(relay_id)
    assert RelayRegistry.relay_user_id(relay) == owner_id
  end

  test "client role cannot announce or update_status", %{
    relay_id: relay_id,
    owner_id: owner_id,
    other_id: other_id,
    invite_code: invite_code,
    invite_key: invite_key
  } do
    register_private!(relay_id, owner_id, invite_code, invite_key)

    assert {:ok, client_socket} =
             RelayChannel.join(
               "relay:#{relay_id}",
               %{"role" => "client", "invite_code" => invite_code},
               socket_for(other_id)
             )

    assert {:reply, {:error, %{reason: "forbidden"}}, _} =
             RelayChannel.handle_in("announce", %{"name" => "x"}, client_socket)

    assert {:reply, {:error, %{reason: "forbidden"}}, _} =
             RelayChannel.handle_in("heartbeat", %{}, client_socket)

    assert {:reply, {:error, %{reason: "forbidden"}}, _} =
             RelayChannel.handle_in("update_status", %{"current_peers" => 9}, client_socket)
  end
end
