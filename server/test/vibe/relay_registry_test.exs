defmodule Vibe.RelayRegistryTest do
  use ExUnit.Case, async: false

  alias Vibe.RelayRegistry

  setup do
    relay_id = "relay-test-#{System.unique_integer([:positive])}"
    owner_id = "owner-#{System.unique_integer([:positive])}"
    other_id = "other-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = RelayRegistry.unregister_relay(relay_id)
    end)

    {:ok, relay_id: relay_id, owner_id: owner_id, other_id: other_id}
  end

  defp base_relay(relay_id, user_id, opts \\ []) do
    %{
      relay_id: relay_id,
      user_id: user_id,
      invite_code: Keyword.get(opts, :invite_code, "invite-code-xyz"),
      invite_key: Keyword.get(opts, :invite_key, "invite-key-xyz"),
      is_public: Keyword.get(opts, :is_public, false),
      name: Keyword.get(opts, :name, "Test Relay"),
      max_peers: 5,
      current_peers: 0,
      region: "test",
      started_at: System.system_time(:second),
      last_heartbeat_at: System.system_time(:second),
      capabilities: []
    }
  end

  test "owner can register and re-register their relay id", %{
    relay_id: relay_id,
    owner_id: owner_id
  } do
    assert :ok = RelayRegistry.register_relay(base_relay(relay_id, owner_id))
    assert {:ok, relay} = RelayRegistry.get_relay(relay_id)
    assert RelayRegistry.relay_user_id(relay) == owner_id

    assert :ok =
             RelayRegistry.register_relay(
               base_relay(relay_id, owner_id, name: "Updated Name", invite_code: "new-code")
             )

    assert {:ok, updated} = RelayRegistry.get_relay(relay_id)
    assert updated.name == "Updated Name"
    assert RelayRegistry.relay_invite_code(updated) == "new-code"
  end

  test "different user cannot take over an existing relay id via register", %{
    relay_id: relay_id,
    owner_id: owner_id,
    other_id: other_id
  } do
    assert :ok = RelayRegistry.register_relay(base_relay(relay_id, owner_id))

    assert {:error, :forbidden} =
             RelayRegistry.register_relay(base_relay(relay_id, other_id, name: "Hijacked"))

    assert {:ok, relay} = RelayRegistry.get_relay(relay_id)
    assert RelayRegistry.relay_user_id(relay) == owner_id
    assert relay.name == "Test Relay"
  end

  test "different user cannot update an existing relay id", %{
    relay_id: relay_id,
    owner_id: owner_id,
    other_id: other_id
  } do
    assert :ok = RelayRegistry.register_relay(base_relay(relay_id, owner_id))

    assert {:error, :forbidden} =
             RelayRegistry.update_relay(relay_id, %{name: "Hijacked"}, as_user: other_id)

    assert {:ok, relay} = RelayRegistry.get_relay(relay_id)
    assert relay.name == "Test Relay"
  end

  test "owner can update and unregister their relay id", %{
    relay_id: relay_id,
    owner_id: owner_id
  } do
    assert :ok = RelayRegistry.register_relay(base_relay(relay_id, owner_id))

    assert :ok =
             RelayRegistry.update_relay(relay_id, %{current_peers: 2}, as_user: owner_id)

    assert {:ok, relay} = RelayRegistry.get_relay(relay_id)
    assert relay.current_peers == 2

    assert :ok =
             RelayRegistry.update_relay(relay_id, %{user_id: "attacker"}, as_user: owner_id)

    assert {:ok, still} = RelayRegistry.get_relay(relay_id)
    assert RelayRegistry.relay_user_id(still) == owner_id

    assert :ok = RelayRegistry.unregister_relay(relay_id, as_user: owner_id)
    assert :not_found = RelayRegistry.get_relay(relay_id)
  end

  test "different user cannot unregister an existing relay id", %{
    relay_id: relay_id,
    owner_id: owner_id,
    other_id: other_id
  } do
    assert :ok = RelayRegistry.register_relay(base_relay(relay_id, owner_id))

    assert {:error, :forbidden} =
             RelayRegistry.unregister_relay(relay_id, as_user: other_id)

    assert {:ok, _} = RelayRegistry.get_relay(relay_id)
  end
end
