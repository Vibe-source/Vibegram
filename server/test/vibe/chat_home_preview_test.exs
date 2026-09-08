defmodule Vibe.ChatHomePreviewTest do
  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Chat
  alias Vibe.Chat.Message
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    me = insert_user("preview_me")
    peer = insert_user("preview_peer")
    chat_id = "chat-preview-#{System.unique_integer([:positive])}"
    {:ok, _} = Chat.create_chat(chat_id, [me.id, peer.id])
    %{me: me, peer: peer, chat_id: chat_id}
  end

  test "home preview returns only the newest bounded messages in ascending order", ctx do
    ids = for timestamp <- 1..6, do: insert_message(ctx, timestamp).id

    messages = listed_messages(ctx)
    assert Enum.map(messages, & &1.id) == [List.last(ids)]
    assert Enum.map(messages, & &1.timestamp) == Enum.sort(Enum.map(messages, & &1.timestamp))
  end

  test "home preview still excludes messages before the clear watermark", ctx do
    for timestamp <- 1..6, do: insert_message(ctx, timestamp)
    assert {:ok, _} = Chat.clear_messages(ctx.chat_id, ctx.me.id)

    fresh = insert_message(ctx, System.system_time(:millisecond) + 1_000)
    assert Enum.map(listed_messages(ctx), & &1.id) == [fresh.id]
  end

  defp listed_messages(ctx) do
    Chat.list_chats(ctx.me.id)
    |> Enum.find(&(&1.chatId == ctx.chat_id))
    |> Map.fetch!(:messages)
  end

  defp insert_message(ctx, timestamp) do
    Repo.insert!(%Message{
      id: Ecto.UUID.generate(),
      chat_id: ctx.chat_id,
      from_id: ctx.peer.id,
      encrypted_content: "ciphertext",
      timestamp: timestamp
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
