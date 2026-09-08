defmodule VibeWeb.BridgeControllerRelayTest do
  use ExUnit.Case, async: false

  alias Vibe.RelayRegistry

  setup do
    relay_id = "bridge-relay-#{System.unique_integer([:positive])}"
    owner_id = "owner-#{System.unique_integer([:positive])}"
    other_id = "other-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = RelayRegistry.unregister_relay(relay_id)
    end)

    {:ok, relay_id: relay_id, owner_id: owner_id, other_id: other_id}
  end

  test "cross-user register is rejected at the registry boundary used by the controller", %{
    relay_id: relay_id,
    owner_id: owner_id,
    other_id: other_id
  } do
    assert :ok =
             RelayRegistry.register_relay(%{
               relay_id: relay_id,
               user_id: owner_id,
               invite_code: "owner-code",
               invite_key: nil,
               is_public: false,
               name: "Owner Relay",
               max_peers: 5,
               current_peers: 0,
               region: "test",
               started_at: System.system_time(:second),
               last_heartbeat_at: System.system_time(:second),
               capabilities: []
             })

    assert {:error, :forbidden} =
             RelayRegistry.register_relay(%{
               relay_id: relay_id,
               user_id: other_id,
               invite_code: "stolen",
               invite_key: nil,
               is_public: false,
               name: "Hijacked",
               max_peers: 5,
               current_peers: 0,
               region: "test",
               started_at: System.system_time(:second),
               last_heartbeat_at: System.system_time(:second),
               capabilities: []
             })

    assert {:error, :forbidden} =
             RelayRegistry.update_relay(
               relay_id,
               %{name: "Hijacked", invite_code: "stolen"},
               as_user: other_id
             )

    assert {:ok, relay} = RelayRegistry.get_relay(relay_id)
    assert RelayRegistry.relay_user_id(relay) == owner_id
    assert relay.name == "Owner Relay"
    assert RelayRegistry.relay_invite_code(relay) == "owner-code"
  end

  test "owner can update an existing relay id via ownership-aware update", %{
    relay_id: relay_id,
    owner_id: owner_id
  } do
    assert :ok =
             RelayRegistry.register_relay(%{
               relay_id: relay_id,
               user_id: owner_id,
               invite_code: "owner-code",
               invite_key: nil,
               is_public: false,
               name: "Owner Relay",
               max_peers: 5,
               current_peers: 0,
               region: "test",
               started_at: System.system_time(:second),
               last_heartbeat_at: System.system_time(:second),
               capabilities: []
             })

    assert :ok =
             RelayRegistry.update_relay(
               relay_id,
               %{
                 name: "Updated Bridge Relay",
                 invite_code: "new-code",
                 bridge_url: "https://example.com/bridge"
               },
               as_user: owner_id
             )

    assert {:ok, relay} = RelayRegistry.get_relay(relay_id)
    assert relay.name == "Updated Bridge Relay"
    assert RelayRegistry.relay_invite_code(relay) == "new-code"
    assert relay.bridge_url == "https://example.com/bridge"
  end
end
