defmodule Vibe.MessageDeleteScopeTest do
  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Chat
  alias Vibe.Chat.{Message, MessageRead}
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    %{first: insert_user("delete_first"), second: insert_user("delete_second")}
  end

  test "either direct-chat participant can delete an incoming message for everyone", %{
    first: first,
    second: second
  } do
    chat_id = "delete-dm-#{System.unique_integer([:positive])}"
    assert {:ok, _room} = Chat.create_chat(chat_id, [first.id, second.id])
    message = insert_message(chat_id, first.id)

    assert {:ok, deleted} = Chat.delete_message(chat_id, message.id, second.id, true)
    assert deleted.id == message.id
    assert Repo.get(Message, message.id) == nil
  end

  test "ordinary group members still cannot delete another sender for everyone", %{
    first: first,
    second: second
  } do
    third = insert_user("delete_third")
    assert {:ok, room} = Chat.create_group(first.id, "Delete scope", [second.id, third.id])
    message = insert_message(room.id, first.id)

    assert {:error, :forbidden} = Chat.delete_message(room.id, message.id, second.id, true)
    assert Repo.get(Message, message.id)
  end

  test "a late read receipt for an already-deleted message is harmless", %{
    first: first,
    second: second
  } do
    chat_id = "delete-read-race-#{System.unique_integer([:positive])}"
    assert {:ok, _room} = Chat.create_chat(chat_id, [first.id, second.id])
    message = insert_message(chat_id, first.id)

    assert {:ok, _deleted} = Chat.delete_message(chat_id, message.id, first.id, true)
    assert {:ok, :message_missing} = Chat.mark_read(message.id, second.id)
    assert Repo.aggregate(MessageRead, :count) == 0
  end

  defp insert_message(chat_id, from_id) do
    Repo.insert!(%Message{
      id: Ecto.UUID.generate(),
      chat_id: chat_id,
      from_id: from_id,
      encrypted_content: "sealed",
      timestamp: System.system_time(:millisecond)
    })
  end

  defp insert_user(prefix) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      is_agent: false
    })
  end
end
