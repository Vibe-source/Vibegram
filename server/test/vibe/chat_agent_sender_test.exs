defmodule Vibe.ChatAgentSenderTest do
  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Chat
  alias Vibe.Repo

  @claude_agent_user_id "11111111-1111-1111-1111-111111111111"
  @legacy_vibe_ai_id "00000000-0000-0000-0000-000000000001"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    alice = insert_user("alice")
    bob = insert_user("bob")
    claude =
      Repo.get(User, @claude_agent_user_id) ||
        insert_user("claude", %{id: @claude_agent_user_id, is_agent: true})

    %{alice: alice, bob: bob, claude: claude}
  end

  # A missing chat_id used to reach Ecto and raise instead of failing closed.
  test "a spoofed sender with no chat_id is refused, not crashed", %{alice: alice} do
    assert {:error, :forbidden_sender} =
             Chat.add_message(
               %{
                 "id" => Ecto.UUID.generate(),
                 "from_id" => @claude_agent_user_id,
                 "content" => "no chat"
               },
               acting_user_id: alice.id
             )
  end

  # Regression test for the impersonation hole:
  test "a user cannot post as a bridge agent that has no role in this chat", %{
    alice: alice,
    bob: bob
  } do
    {:ok, room} = Chat.create_chat(Ecto.UUID.generate(), [alice.id, bob.id])

    attrs = message_attrs(room.id, @claude_agent_user_id)

    assert {:error, :forbidden_sender} = Chat.add_message(attrs, acting_user_id: alice.id)
  end

  test "a legitimate bridge-agent reply still succeeds", %{
    alice: alice,
    bob: bob,
    claude: claude
  } do
    {:ok, room} = Chat.create_chat(Ecto.UUID.generate(), [alice.id, bob.id, claude.id])

    attrs = message_attrs(room.id, claude.id)

    assert {:ok, %Vibe.Chat.Message{from_id: from_id}} =
             Chat.add_message(attrs, acting_user_id: alice.id)

    assert from_id == claude.id
  end

  test "the legacy Vibe AI persona can post only where it is actually configured", %{
    alice: alice,
    bob: bob
  } do
    {:ok, room} = Chat.create_chat(Ecto.UUID.generate(), [alice.id, bob.id])

    unconfigured_attrs = message_attrs(room.id, @legacy_vibe_ai_id)

    assert {:error, :forbidden_sender} =
             Chat.add_message(unconfigured_attrs, acting_user_id: alice.id)

    insert_legacy_ai_user()
    {:ok, _group_agent} = Vibe.Chat.GroupAgent.create(%{chat_id: room.id, system_prompt: "hi"})

    configured_attrs = message_attrs(room.id, @legacy_vibe_ai_id)

    assert {:ok, _message} = Chat.add_message(configured_attrs, acting_user_id: alice.id)
  end

  test "an ordinary user-to-self send still succeeds", %{alice: alice, bob: bob} do
    {:ok, room} = Chat.create_chat(Ecto.UUID.generate(), [alice.id, bob.id])

    attrs = message_attrs(room.id, alice.id)

    assert {:ok, _message} = Chat.add_message(attrs, acting_user_id: alice.id)
  end

  test "a spoofed non-agent sender is still refused", %{alice: alice, bob: bob} do
    {:ok, room} = Chat.create_chat(Ecto.UUID.generate(), [alice.id, bob.id])

    attrs = message_attrs(room.id, bob.id)

    assert {:error, :forbidden_sender} = Chat.add_message(attrs, acting_user_id: alice.id)
  end

  defp message_attrs(chat_id, from_id) do
    %{
      id: Ecto.UUID.generate(),
      chat_id: chat_id,
      from_id: from_id,
      encrypted_content: "hello",
      type: "text",
      timestamp: System.system_time(:millisecond)
    }
  end

  defp insert_user(prefix, attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      is_agent: false
    }

    Repo.insert!(struct(User, Map.merge(defaults, Map.new(attrs))))
  end

  defp insert_legacy_ai_user do
    Repo.get(User, @legacy_vibe_ai_id) ||
      Repo.insert!(
        struct(User, %{
          id: @legacy_vibe_ai_id,
          username: "vibeai_#{System.unique_integer([:positive])}",
          password_hash: "agent",
          public_key: "agent",
          device_id: "agent",
          is_agent: false
        })
      )
  end
end
