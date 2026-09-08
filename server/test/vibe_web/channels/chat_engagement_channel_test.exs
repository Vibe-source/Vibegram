defmodule VibeWeb.ChatEngagementChannelTest do
  @moduledoc "Reaction and view channel contract tests."

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Chat
  alias Vibe.Chat.Message
  alias Vibe.Repo
  alias VibeWeb.ChatChannel

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    author = insert_user("chan_author")
    viewer = insert_user("chan_viewer")
    {:ok, room} = Chat.create_group(author.id, "Channel engagement", [viewer.id])
    message = insert_message(room.id, author.id)
    :ok = Phoenix.PubSub.subscribe(Vibe.PubSub, "chat:#{room.id}")

    %{author: author, viewer: viewer, chat_id: room.id, message: message}
  end

  test "react-message replies with the caller's summary and broadcasts counts only", context do
    %{viewer: viewer, chat_id: chat_id, message: message} = context

    assert {:reply, {:ok, reply}, _socket} =
             ChatChannel.handle_in(
               "react-message",
               %{"messageId" => message.id, "emoji" => "👍"},
               socket_for(viewer.id, chat_id)
             )

    assert reply.action == "added"
    assert reply.reactions == [%{emoji: "👍", count: 1, isSelected: true}]

    assert_receive %Phoenix.Socket.Broadcast{
      event: "message-reaction-updated",
      payload: %{chatId: ^chat_id, messageId: broadcast_id, reactions: reactions, actorId: actor}
    }

    assert broadcast_id == message.id
    assert actor == viewer.id
    assert reactions == [%{emoji: "👍", count: 1}]
  end

  test "react-message on a foreign message is refused without a broadcast", context do
    %{viewer: viewer, chat_id: chat_id} = context

    assert {:reply, {:error, %{reason: "not_found"}}, _socket} =
             ChatChannel.handle_in(
               "react-message",
               %{"messageId" => Ecto.UUID.generate(), "emoji" => "👍"},
               socket_for(viewer.id, chat_id)
             )

    refute_receive %Phoenix.Socket.Broadcast{event: "message-reaction-updated"}
  end

  test "a malformed engagement payload is refused, not fatal", context do
    %{viewer: viewer, chat_id: chat_id} = context
    socket = socket_for(viewer.id, chat_id)

    assert {:reply, {:error, %{reason: "invalid_payload"}}, _socket} =
             ChatChannel.handle_in("react-message", %{"messageId" => "x"}, socket)

    assert {:reply, {:error, %{reason: "invalid_payload"}}, _socket} =
             ChatChannel.handle_in("messages-viewed", %{"messageIds" => "nope"}, socket)
  end

  test "messages-viewed broadcasts the fresh counts and skips the author", context do
    %{author: author, viewer: viewer, chat_id: chat_id, message: message} = context

    assert {:reply, {:ok, %{counts: counts}}, _socket} =
             ChatChannel.handle_in(
               "messages-viewed",
               %{"messageIds" => [message.id]},
               socket_for(viewer.id, chat_id)
             )

    assert counts == [%{messageId: message.id, viewCount: 1}]

    assert_receive %Phoenix.Socket.Broadcast{
      event: "message-view-counts-updated",
      payload: %{chatId: ^chat_id, counts: ^counts}
    }

    assert {:reply, {:ok, %{counts: []}}, _socket} =
             ChatChannel.handle_in(
               "messages-viewed",
               %{"messageIds" => [message.id]},
               socket_for(author.id, chat_id)
             )

    refute_receive %Phoenix.Socket.Broadcast{event: "message-view-counts-updated"}
  end

  test "edit-message broadcasts the persisted editedAt and keeps the send time", context do
    %{author: author, chat_id: chat_id, message: message} = context

    assert {:reply, :ok, _socket} =
             ChatChannel.handle_in(
               "edit-message",
               %{"messageId" => message.id, "encryptedContent" => "sealed-v2"},
               socket_for(author.id, chat_id)
             )

    assert_receive %Phoenix.Socket.Broadcast{
      event: "message-edited",
      payload: %{editedAt: edited_at, message: mirrored}
    }

    reloaded = Repo.get!(Message, message.id)
    assert reloaded.edited_at == edited_at
    assert reloaded.timestamp == message.timestamp
    assert mirrored[:timestamp] == message.timestamp
    assert mirrored[:editedAt] == edited_at
  end

  defp socket_for(user_id, chat_id) do
    %Phoenix.Socket{
      assigns: %{user_id: user_id},
      channel_pid: self(),
      joined: true,
      pubsub_server: Vibe.PubSub,
      serializer: Jason,
      topic: "chat:#{chat_id}",
      transport_pid: self()
    }
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
