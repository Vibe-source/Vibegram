defmodule Vibe.RealtimeProjectionTest do
  @moduledoc """
  Contract tests for the two pure pieces behind coexisting notifications and a real-time chat
  list: the APNs collapse identity.
  """
  use ExUnit.Case, async: true

  alias Vibe.Chat
  alias Vibe.Chat.Message
  alias Vibe.Notifications

  describe "push_collapse_id/1" do
    test "two different messages in one chat collapse independently" do
      first = Notifications.push_collapse_id(%{chatId: "chat-1", messageId: "msg-1"})
      second = Notifications.push_collapse_id(%{chatId: "chat-1", messageId: "msg-2"})

      assert first != ""
      assert second != ""
      refute first == second
    end

    test "the same message redelivered keeps one collapse identity" do
      data = %{chatId: "chat-1", messageId: "msg-1"}
      assert Notifications.push_collapse_id(data) == Notifications.push_collapse_id(data)
    end

    test "accepts string and snake_case keys" do
      assert Notifications.push_collapse_id(%{"messageId" => "msg-1"}) == "msg-1"
      assert Notifications.push_collapse_id(%{message_id: "msg-2"}) == "msg-2"
    end

    test "is empty when no message id is supplied so the header is dropped" do
      assert Notifications.push_collapse_id(%{chatId: "chat-1"}) == ""
      assert Notifications.push_collapse_id(%{messageId: "   "}) == ""
      assert Notifications.push_collapse_id(nil) == ""
    end

    test "never exceeds the APNs collapse identifier limit" do
      long_id = String.duplicate("a", 200)
      assert byte_size(Notifications.push_collapse_id(%{messageId: long_id})) == 64
    end
  end

  describe "mirrored_message_payload/1" do
    test "keeps everything the first frame of an opened conversation needs" do
      payload = %{
        "id" => "msg-1",
        "chatId" => "chat-1",
        "fromId" => "user-1",
        "type" => "image",
        "encryptedContent" => "cipher",
        "plainContent" => "hello",
        "mediaUrl" => "https://cdn.example/photo.jpg",
        "replyToId" => "msg-0",
        "timestamp" => 1_700_000_000_000,
        "isAgentMessage" => true,
        "agentName" => "Reporter",
        "metadata" => %{"thumbnailBase64" => "tiny", "caption" => "look"}
      }

      mirrored = Chat.mirrored_message_payload(payload)

      assert mirrored["id"] == "msg-1"
      assert mirrored["chatId"] == "chat-1"
      assert mirrored["fromId"] == "user-1"
      assert mirrored["type"] == "image"
      assert mirrored["encryptedContent"] == "cipher"
      assert mirrored["plainContent"] == "hello"
      assert mirrored["mediaUrl"] == "https://cdn.example/photo.jpg"
      assert mirrored["replyToId"] == "msg-0"
      assert mirrored["timestamp"] == 1_700_000_000_000
      assert mirrored["isAgentMessage"] == true
      assert mirrored["agentName"] == "Reporter"
      assert mirrored["metadata"]["thumbnailBase64"] == "tiny"
      assert mirrored["metadata"]["caption"] == "look"
    end

    test "drops sealed blobs that must not be multiplied per participant" do
      payload = %{
        "id" => "msg-1",
        "agentBridgeAttachmentsEnc" => ["huge"],
        "metadata" => %{
          "agentBridgeAttachmentsEnc" => ["huge"],
          "attachmentThumbnailsB64" => ["huge"],
          "thumbnailBase64" => "tiny"
        }
      }

      mirrored = Chat.mirrored_message_payload(payload)

      refute Map.has_key?(mirrored, "agentBridgeAttachmentsEnc")
      refute Map.has_key?(mirrored["metadata"], "agentBridgeAttachmentsEnc")
      refute Map.has_key?(mirrored["metadata"], "attachmentThumbnailsB64")
      assert mirrored["metadata"]["thumbnailBase64"] == "tiny"
    end

    test "compacts atom-keyed metadata too" do
      mirrored =
        Chat.mirrored_message_payload(%{
          id: "msg-1",
          metadata: %{"attachmentThumbnailsB64" => ["huge"], "caption" => "hi"}
        })

      refute Map.has_key?(mirrored[:metadata], "attachmentThumbnailsB64")
      assert mirrored[:metadata]["caption"] == "hi"
    end

    test "refuses an oversized payload rather than fanning it out per participant" do
      oversized = %{"id" => "msg-1", "metadata" => %{"caption" => String.duplicate("x", 32_768)}}
      assert Chat.mirrored_message_payload(oversized) == nil
    end

    test "returns nil when the caller has no payload, so the key can be omitted" do
      assert Chat.mirrored_message_payload(nil) == nil
      assert Chat.mirrored_message_payload("not a map") == nil
    end
  end

  describe "user-topic realtime projection" do
    test "fans one event to each unique participant and supplies the chat id" do
      first_user = "projection-first-#{System.unique_integer([:positive])}"
      second_user = "projection-second-#{System.unique_integer([:positive])}"
      first_topic = "user:#{first_user}"
      second_topic = "user:#{second_user}"

      :ok = Phoenix.PubSub.subscribe(Vibe.PubSub, first_topic)
      :ok = Phoenix.PubSub.subscribe(Vibe.PubSub, second_topic)

      assert :ok =
               Chat.broadcast_user_chat_event(
                 "chat-realtime",
                 "message-read",
                 %{messageId: "message-1", status: "read"},
                 [first_user, first_user, "", second_user]
               )

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^first_topic,
        event: "message-read",
        payload: %{chatId: "chat-realtime", messageId: "message-1", status: "read"}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^second_topic,
        event: "message-read",
        payload: %{chatId: "chat-realtime", messageId: "message-1", status: "read"}
      }

      refute_receive %Phoenix.Socket.Broadcast{topic: ^first_topic}, 10
    end

    test "keeps an explicit chat id and exposes a compact canonical edit row" do
      user_id = "projection-user-#{System.unique_integer([:positive])}"
      topic = "user:#{user_id}"
      :ok = Phoenix.PubSub.subscribe(Vibe.PubSub, topic)

      message = %Message{
        id: Ecto.UUID.generate(),
        chat_id: "chat-canonical",
        from_id: Ecto.UUID.generate(),
        encrypted_content: "cipher",
        type: "text",
        timestamp: 1_700_000_000_000,
        status: "sent",
        metadata: %{"caption" => "edited"}
      }

      canonical =
        message
        |> Chat.client_message_payload()
        |> Chat.mirrored_message_payload()

      assert canonical.id == message.id
      assert canonical.chat_id == "chat-canonical"
      assert canonical.from_id == message.from_id
      assert canonical.encrypted_content == "cipher"

      assert :ok =
               Chat.broadcast_user_chat_event(
                 "ignored-chat",
                 "message-edited",
                 %{"chatId" => "chat-canonical", "message" => canonical},
                 [user_id]
               )

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^topic,
        event: "message-edited",
        payload: %{"chatId" => "chat-canonical", "message" => ^canonical}
      }
    end
  end
end
