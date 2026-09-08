defmodule Vibe.ChatClearMessagesTest do
  @moduledoc """
  Clearing is not deleting. `clear_messages/2` hides the caller's history and must leave
  membership, the chat and the peer's own copy alone.
  """

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Chat
  alias Vibe.Repo
  alias Vibe.Chat.Participant

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    me = insert_user("clear_me")
    peer = insert_user("clear_peer")
    chat_id = "chat-clear-#{System.unique_integer([:positive])}"
    {:ok, _} = Chat.create_chat(chat_id, [me.id, peer.id])
    %{me: me, peer: peer, chat_id: chat_id}
  end

  defp participant(chat_id, user_id) do
    Repo.get_by(Participant, chat_id: chat_id, user_id: user_id)
  end

  test "clearing stamps the watermark and keeps the participant", ctx do
    assert {:ok, %{cleared_at: cleared_at}} = Chat.clear_messages(ctx.chat_id, ctx.me.id)

    row = participant(ctx.chat_id, ctx.me.id)
    assert row.messages_cleared_at == cleared_at
    refute row.deleted
    refute row.archived
    assert Chat.is_participant?(ctx.chat_id, ctx.me.id)
  end

  test "clearing touches nobody else's copy", ctx do
    {:ok, _} = Chat.clear_messages(ctx.chat_id, ctx.me.id)

    peer_row = participant(ctx.chat_id, ctx.peer.id)
    assert is_nil(peer_row.messages_cleared_at)
    refute peer_row.deleted
  end

  test "deleting still marks the participant deleted", ctx do
    assert {:ok, _} = Chat.delete_chat(ctx.chat_id, ctx.me.id)
    assert participant(ctx.chat_id, ctx.me.id).deleted
  end

  test "a non-participant cannot clear a chat", ctx do
    outsider = insert_user("clear_outsider")
    assert {:error, _} = Chat.clear_messages(ctx.chat_id, outsider.id)
    assert is_nil(participant(ctx.chat_id, ctx.me.id).messages_cleared_at)
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
