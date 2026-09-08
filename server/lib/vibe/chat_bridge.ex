defmodule Vibe.ChatBridge do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Vibe.Accounts
  alias Vibe.Accounts.User
  alias Vibe.Chat
  alias Vibe.Chat.Message
  alias Vibe.Chat.MessageRead
  alias Vibe.Repo
  alias Vibe.RepoRLS
  alias Vibe.Storage

  @poll_limit 200
  @long_poll_timeout_ms 25_000
  @poll_sleep_ms 1_000
  @history_default_limit 30

  def open_session(%User{} = user, attrs) when is_map(attrs) do
    with :ok <- ensure_body_user_matches(user, attrs) do
      cursor = encode_cursor(current_cursor())

      {:ok,
       %{
         sessionId: Ecto.UUID.generate(),
         cursor: cursor,
         nextCursor: cursor,
         bridgeId:
           normalize_string(
             attrs["activeBridgeId"] || attrs[:activeBridgeId] || attrs["bridgeId"] ||
               attrs[:bridgeId]
           )
       }}
    end
  end

  def send_event(%User{} = user, attrs) when is_map(attrs) do
    event = normalize_string(attrs["event"] || attrs[:event]) || "message"
    chat_id = extract_chat_id(attrs)
    payload = extract_payload(attrs)

    case event do
      "message" ->
        send_message(user, chat_id, payload)

      "edit-message" ->
        edit_message(user, chat_id, payload)

      "message-edited" ->
        edit_message(user, chat_id, payload)

      "delete-message" ->
        delete_message(user, chat_id, payload)

      "message-deleted" ->
        delete_message(user, chat_id, payload)

      "typing" ->
        {:ok, %{accepted: true, ignored: true, event: event}}

      "stop-typing" ->
        {:ok, %{accepted: true, ignored: true, event: event}}

      "recording" ->
        {:ok, %{accepted: true, ignored: true, event: event}}

      "stop-recording" ->
        {:ok, %{accepted: true, ignored: true, event: event}}

      _ ->
        {:ok, %{accepted: true, ignored: true, event: event}}
    end
  end

  def ack_event(%User{} = user, attrs) when is_map(attrs) do
    event = normalize_string(attrs["event"] || attrs[:event])
    chat_id = extract_chat_id(attrs)
    payload = extract_payload(attrs)
    message_id = normalize_string(payload["messageId"] || payload[:messageId] || payload["id"])

    with {:ok, chat_id} <- require_chat_id(chat_id),
         {:ok, message_id} <- require_message_id(message_id),
         :ok <- ensure_participant(chat_id, user.id) do
      case event do
        "delivery-receipt" ->
          Chat.mark_delivered(message_id, user.id)

          receipt_payload = %{
            chatId: chat_id,
            messageId: message_id,
            readerId: user.id,
            status: "delivered"
          }

          broadcast_bridge_event("chat:#{chat_id}", "message-delivered", receipt_payload)
          Chat.broadcast_message_receipt(chat_id, message_id, user.id, "delivered")

          {:ok,
           %{
             accepted: true,
             chatId: chat_id,
             messageId: message_id,
             status: "delivered"
           }}

        "read-receipt" ->
          Chat.mark_read(message_id, user.id)

          receipt_payload = %{
            chatId: chat_id,
            messageId: message_id,
            readerId: user.id,
            status: "read"
          }

          broadcast_bridge_event("chat:#{chat_id}", "message-read", receipt_payload)
          Chat.broadcast_message_receipt(chat_id, message_id, user.id, "read")

          {:ok,
           %{
             accepted: true,
             chatId: chat_id,
             messageId: message_id,
             status: "read"
           }}

        _ ->
          {:error, :bad_request}
      end
    end
  end

  def home_snapshot(%User{} = user, attrs) when is_map(attrs) do
    with :ok <- ensure_body_user_matches(user, attrs) do
      {:ok, %{chats: Chat.list_chats(user.id)}}
    end
  end

  def chat_history(%User{} = user, attrs) when is_map(attrs) do
    chat_id =
      normalize_string(attrs["chatId"] || attrs[:chatId] || attrs["chat_id"] || attrs[:chat_id])

    saved_messages? =
      truthy?(attrs["savedMessages"] || attrs[:savedMessages] || attrs["saved_messages"]) ||
        chat_id == "saved_messages"

    limit = normalize_limit(attrs["limit"] || attrs[:limit])
    before = parse_history_cursor(attrs["before"] || attrs[:before])

    cond do
      saved_messages? ->
        page =
          user.id
          |> Chat.list_saved_messages()
          |> Enum.sort_by(&saved_message_sort_key/1)
          |> paginate_saved_messages(limit || @history_default_limit, before)

        {:ok,
         %{
           messages: page.messages,
           data: page.messages,
           nextCursor: page.next_cursor,
           hasMore: page.has_more
         }}

      is_binary(chat_id) and chat_id != "" ->
        with :ok <- ensure_participant(chat_id, user.id) do
          page =
            Chat.get_messages_for_user_page(
              chat_id,
              user.id,
              limit: limit || @history_default_limit,
              before: attrs["before"] || attrs[:before]
            )

          {:ok,
           %{
             messages: page.messages,
             data: page.messages,
             nextCursor: page.next_cursor,
             hasMore: page.has_more
           }}
        end

      true ->
        {:error, :bad_request}
    end
  end

  def peer_key(%User{} = user, attrs) when is_map(attrs) do
    peer_user_id =
      normalize_string(
        attrs["peerUserId"] || attrs[:peerUserId] || attrs["peer_user_id"] || attrs[:peer_user_id]
      )

    chat_id =
      normalize_string(attrs["chatId"] || attrs[:chatId] || attrs["chat_id"] || attrs[:chat_id])

    with {:ok, peer} <- resolve_peer_user(user, peer_user_id, chat_id) do
      {:ok,
       %{
         peerUserId: peer.id,
         userId: peer.id,
         username: peer.username,
         name: peer.name,
         profileImage: peer.profile_image,
         publicKey: peer.public_key,
         public_key: peer.public_key,
         identityKey: peer.identity_key,
         identity_key: peer.identity_key
       }}
    end
  end

  def poll(%User{} = user, attrs) when is_map(attrs) do
    cursor = parse_cursor(attrs["cursor"] || attrs[:cursor])
    topics = normalize_topics(attrs["topics"] || attrs[:topics])
    chat_ids = topics_to_chat_ids(topics, user.id)

    if chat_ids == [] do
      Process.sleep(@long_poll_timeout_ms)
      encoded = encode_cursor(cursor)
      {:ok, %{events: [], cursor: encoded, nextCursor: encoded, hasMore: false}}
    else
      wait_for_events(user.id, chat_ids, cursor, System.monotonic_time(:millisecond))
    end
  end

  def bundle do
    raw =
      System.get_env("BLACKOUT_BRIDGE_BUNDLE_JSON") ||
        System.get_env("VIBE_BRIDGE_BUNDLE_JSON")

    cond do
      !is_binary(raw) or String.trim(raw) == "" ->
        {:error, :not_found}

      true ->
        case Jason.decode(raw) do
          {:ok, decoded} when is_map(decoded) ->
            {:ok, decoded}

          {:ok, _other} ->
            {:error, :invalid_bundle}

          {:error, _reason} ->
            {:error, :invalid_bundle}
        end
    end
  end

  defp send_message(%User{} = user, chat_id, payload) do
    with {:ok, chat_id} <- require_chat_id(chat_id),
         :ok <- ensure_participant(chat_id, user.id),
         :ok <- ensure_can_send(chat_id, user.id),
         {:ok, message_attrs} <- build_message_attrs(chat_id, user.id, payload) do
      case get_existing_message(user.id, message_attrs.id) do
        %Message{} = existing ->
          if existing.chat_id == chat_id and existing.from_id == user.id do
            {:ok, send_message_response(existing)}
          else
            {:error, :conflict}
          end

        nil ->
          case Chat.add_message(message_attrs, acting_user_id: user.id) do
            {:ok, %Message{} = message} ->
              broadcast_bridge_message(message)
              {:ok, send_message_response(message)}

            {:error, _changeset} ->
              case get_existing_message(user.id, message_attrs.id) do
                %Message{} = existing
                when existing.chat_id == chat_id and existing.from_id == user.id ->
                  {:ok, send_message_response(existing)}

                _ ->
                  {:error, :unprocessable_entity}
              end
          end
      end
    end
  end

  defp edit_message(%User{} = user, chat_id, payload) do
    message_id = normalize_string(payload["messageId"] || payload[:messageId] || payload["id"])

    encrypted_content =
      normalize_string(
        payload["encryptedContent"] || payload[:encryptedContent] || payload["encrypted_content"]
      )

    edited_at =
      normalize_integer(payload["editedAt"] || payload[:editedAt] || payload["edited_at"])

    with {:ok, chat_id} <- require_chat_id(chat_id),
         {:ok, message_id} <- require_message_id(message_id),
         {:ok, encrypted_content} <- require_encrypted_content(encrypted_content),
         :ok <- ensure_participant(chat_id, user.id),
         {:ok, message} <-
           Chat.edit_message(chat_id, message_id, user.id, encrypted_content, edited_at) do
      mutation_payload = %{
        chatId: chat_id,
        messageId: message_id,
        encryptedContent: encrypted_content,
        editedAt: edited_at,
        message:
          message
          |> Chat.client_message_payload()
          |> Chat.mirrored_message_payload()
      }

      broadcast_bridge_event("chat:#{chat_id}", "message-edited", mutation_payload)
      Chat.broadcast_user_chat_event(chat_id, "message-edited", mutation_payload)

      {:ok,
       %{
         accepted: true,
         chatId: chat_id,
         messageId: message_id,
         events: [
           %{
             topic: "chat:#{chat_id}",
             event: "message-edited",
             payload: %{
               chatId: chat_id,
               messageId: message_id,
               encryptedContent: encrypted_content,
               editedAt: edited_at
             }
           }
         ]
       }}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :invalid_id} -> {:error, :bad_request}
      {:error, _reason} -> {:error, :unprocessable_entity}
    end
  end

  defp delete_message(%User{} = user, chat_id, payload) do
    message_id = normalize_string(payload["messageId"] || payload[:messageId] || payload["id"])

    for_everyone =
      truthy?(payload["forEveryone"] || payload[:forEveryone] || payload["for_everyone"], true)

    with {:ok, chat_id} <- require_chat_id(chat_id),
         {:ok, message_id} <- require_message_id(message_id),
         :ok <- ensure_participant(chat_id, user.id),
         {:ok, _message} <- Chat.delete_message(chat_id, message_id, user.id, for_everyone) do
      mutation_payload = %{
        chatId: chat_id,
        messageId: message_id,
        deletedBy: user.id,
        forEveryone: for_everyone
      }

      broadcast_bridge_event("chat:#{chat_id}", "message-deleted", mutation_payload)

      Chat.broadcast_user_chat_event(
        chat_id,
        "message-deleted",
        mutation_payload,
        if(for_everyone, do: nil, else: [user.id])
      )

      {:ok,
       %{
         accepted: true,
         chatId: chat_id,
         messageId: message_id,
         forEveryone: for_everyone,
         events: [
           %{
             topic: "chat:#{chat_id}",
             event: "message-deleted",
             payload: %{
               chatId: chat_id,
               messageId: message_id,
               deletedBy: user.id,
               forEveryone: for_everyone
             }
           }
         ]
       }}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :invalid_id} -> {:error, :bad_request}
      {:error, _reason} -> {:error, :unprocessable_entity}
    end
  end

  defp send_message_response(%Message{} = message) do
    %{
      accepted: true,
      chatId: message.chat_id,
      messageId: message.id,
      status: message.status || "sent",
      events: [message_frame(message)]
    }
  end

  defp broadcast_bridge_message(%Message{} = message) do
    payload = %{
      id: message.id,
      messageId: message.id,
      chatId: message.chat_id,
      fromId: message.from_id,
      timestamp: message.timestamp,
      type: message.type,
      encryptedContent: message.encrypted_content,
      status: message.status,
      mediaUrl: rewrite_media_url(message.media_url),
      replyToId: message.reply_to_id
    }

    VibeWeb.Endpoint.broadcast("chat:#{message.chat_id}", "message", payload)

    mirrored_message = Chat.mirrored_message_payload(payload)

    participant_ids = Chat.get_participant_ids(message.chat_id) || []

    Enum.each(participant_ids, fn pid ->
      if pid != message.from_id do
        VibeWeb.Endpoint.broadcast("user:#{pid}", "new_message", %{
          chatId: message.chat_id,
          fromId: message.from_id,
          messageId: message.id,
          message: mirrored_message
        })
      end
    end)
  rescue
    _ -> :ok
  end

  defp broadcast_bridge_event(topic, event, payload) do
    VibeWeb.Endpoint.broadcast(topic, event, payload)
  rescue
    _ -> :ok
  end

  defp wait_for_events(user_id, chat_ids, cursor, started_ms) do
    events = fetch_poll_events(user_id, chat_ids, cursor)

    cond do
      events != [] ->
        next_cursor = next_cursor_for_events(events)
        encoded = encode_cursor(next_cursor)

        {:ok,
         %{
           events: Enum.map(events, & &1.frame),
           cursor: encoded,
           nextCursor: encoded,
           hasMore: false
         }}

      System.monotonic_time(:millisecond) - started_ms >= @long_poll_timeout_ms ->
        encoded = encode_cursor(cursor)
        {:ok, %{events: [], cursor: encoded, nextCursor: encoded, hasMore: false}}

      true ->
        Process.sleep(@poll_sleep_ms)
        wait_for_events(user_id, chat_ids, cursor, started_ms)
    end
  end

  defp fetch_poll_events(user_id, chat_ids, cursor) do
    from_dt = cursor.ms |> max(0) |> ms_to_naive()

    message_events =
      RepoRLS.with_user(user_id, fn ->
        Repo.all(
          from(m in Message,
            where: m.chat_id in ^chat_ids and m.inserted_at >= ^from_dt,
            order_by: [asc: m.inserted_at, asc: m.id],
            limit: ^@poll_limit
          )
        )
      end)
      |> ensure_list()
      |> Enum.map(&message_event/1)
      |> Enum.filter(&cursor_after?(&1, cursor))

    delivered_events =
      RepoRLS.with_user(user_id, fn ->
        Repo.all(
          from(m in Message,
            where:
              m.chat_id in ^chat_ids and m.from_id == ^user_id and m.status == "delivered" and
                m.updated_at >= ^from_dt,
            order_by: [asc: m.updated_at, asc: m.id],
            limit: ^@poll_limit
          )
        )
      end)
      |> ensure_list()
      |> Enum.map(&delivered_event/1)
      |> Enum.filter(&cursor_after?(&1, cursor))

    read_events =
      RepoRLS.with_user(user_id, fn ->
        Repo.all(
          from(r in MessageRead,
            join: m in Message,
            on: m.id == r.message_id,
            where:
              m.chat_id in ^chat_ids and m.from_id == ^user_id and r.reader_id != ^user_id and
                r.inserted_at >= ^from_dt,
            order_by: [asc: r.inserted_at, asc: r.message_id, asc: r.reader_id],
            limit: ^@poll_limit,
            select: %{
              inserted_at: r.inserted_at,
              reader_id: r.reader_id,
              message_id: m.id,
              chat_id: m.chat_id
            }
          )
        )
      end)
      |> ensure_list()
      |> Enum.map(&read_event/1)
      |> Enum.filter(&cursor_after?(&1, cursor))

    (message_events ++ delivered_events ++ read_events)
    |> Enum.sort_by(fn event -> {event.cursor_ms, event.cursor_token} end)
    |> Enum.take(@poll_limit)
  end

  defp message_event(%Message{} = message) do
    inserted_ms = naive_to_ms(message.inserted_at) || max(message.timestamp || 0, 0)

    %{
      cursor_ms: inserted_ms,
      cursor_token: "message:#{message.id}",
      frame: message_frame(message)
    }
  end

  defp delivered_event(%Message{} = message) do
    updated_ms = naive_to_ms(message.updated_at) || max(message.timestamp || 0, 0)

    %{
      cursor_ms: updated_ms,
      cursor_token: "delivered:#{message.id}",
      frame: %{
        topic: "chat:#{message.chat_id}",
        event: "message-delivered",
        payload: %{
          chatId: message.chat_id,
          messageId: message.id
        }
      }
    }
  end

  defp read_event(%{
         inserted_at: inserted_at,
         reader_id: reader_id,
         message_id: message_id,
         chat_id: chat_id
       }) do
    inserted_ms = naive_to_ms(inserted_at) || 0
    normalized_message_id = normalize_string(message_id) || ""
    normalized_chat_id = normalize_string(chat_id) || ""

    %{
      cursor_ms: inserted_ms,
      cursor_token: "read:#{normalized_message_id}:#{reader_id}",
      frame: %{
        topic: "chat:#{normalized_chat_id}",
        event: "message-read",
        payload: %{
          chatId: normalized_chat_id,
          messageId: normalized_message_id,
          readerId: reader_id
        }
      }
    }
  end

  defp message_frame(%Message{} = message) do
    %{
      topic: "chat:#{message.chat_id}",
      event: "message",
      payload: %{
        id: message.id,
        messageId: message.id,
        chatId: message.chat_id,
        fromId: message.from_id,
        timestamp: message.timestamp,
        type: message.type,
        encryptedContent: message.encrypted_content,
        status: message.status,
        mediaUrl: rewrite_media_url(message.media_url),
        replyToId: message.reply_to_id
      }
    }
  end

  defp next_cursor_for_events(events) do
    last = List.last(events)
    %{ms: last.cursor_ms, token: last.cursor_token}
  end

  defp current_cursor do
    %{ms: System.system_time(:millisecond), token: ""}
  end

  defp parse_cursor(nil), do: %{ms: 0, token: ""}
  defp parse_cursor(""), do: %{ms: 0, token: ""}

  defp parse_cursor(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [ms_text, token] ->
        %{ms: normalize_integer(ms_text) || 0, token: token || ""}

      [ms_text] ->
        %{ms: normalize_integer(ms_text) || 0, token: ""}
    end
  end

  defp parse_cursor(value) when is_integer(value), do: %{ms: value, token: ""}
  defp parse_cursor(_value), do: %{ms: 0, token: ""}

  defp encode_cursor(%{ms: ms, token: token}) when is_integer(ms) and is_binary(token) do
    if token == "", do: Integer.to_string(ms), else: "#{ms}:#{token}"
  end

  defp cursor_after?(event, cursor) do
    event.cursor_ms > cursor.ms ||
      (event.cursor_ms == cursor.ms && event.cursor_token > cursor.token)
  end

  defp topics_to_chat_ids(topics, user_id) do
    topic_chat_ids =
      topics
      |> Enum.map(fn topic ->
        case topic do
          "chat:" <> chat_id -> normalize_string(chat_id)
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.filter(topic_chat_ids, fn chat_id ->
      Chat.is_participant?(chat_id, user_id)
    end)
  end

  defp normalize_topics(value) when is_list(value) do
    value
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_topics(value) when is_binary(value), do: [value]
  defp normalize_topics(_value), do: []

  defp resolve_peer_user(%User{} = user, peer_user_id, chat_id) do
    cond do
      is_binary(peer_user_id) and peer_user_id != "" ->
        case Accounts.get_user(peer_user_id) do
          %User{} = peer -> {:ok, peer}
          _ -> {:error, :not_found}
        end

      is_binary(chat_id) and chat_id != "" ->
        with :ok <- ensure_participant(chat_id, user.id),
             participant_ids when is_list(participant_ids) <- Chat.get_participant_ids(chat_id),
             resolved_peer_id when is_binary(resolved_peer_id) <-
               Enum.find(participant_ids, &(&1 != user.id)),
             %User{} = peer <- Accounts.get_user(resolved_peer_id) do
          {:ok, peer}
        else
          _ -> {:error, :not_found}
        end

      true ->
        {:error, :bad_request}
    end
  end

  defp build_message_attrs(chat_id, from_id, payload) when is_map(payload) do
    message_id =
      normalize_string(
        payload["id"] || payload[:id] || payload["messageId"] || payload[:messageId]
      )

    encrypted_content =
      normalize_string(
        payload["encryptedContent"] || payload[:encryptedContent] || payload["encrypted_content"]
      )

    timestamp =
      normalize_integer(payload["timestamp"] || payload[:timestamp]) ||
        System.system_time(:millisecond)

    type = normalize_string(payload["type"] || payload[:type]) || "text"

    media_url =
      normalize_string(payload["mediaUrl"] || payload[:mediaUrl] || payload["media_url"])

    reply_to_id =
      normalize_string(payload["replyToId"] || payload[:replyToId] || payload["reply_to_id"])

    with {:ok, message_id} <- require_message_id(message_id),
         {:ok, encrypted_content} <- require_encrypted_content(encrypted_content) do
      {:ok,
       %{
         id: message_id,
         chat_id: chat_id,
         from_id: from_id,
         encrypted_content: encrypted_content,
         type: type,
         timestamp: timestamp,
         media_url: media_url,
         reply_to_id: reply_to_id,
         status: "sent"
       }}
    end
  end

  defp get_existing_message(user_id, message_id) when is_binary(message_id) do
    RepoRLS.with_user(user_id, fn ->
      Repo.get(Message, message_id)
    end)
  end

  defp get_existing_message(_user_id, _message_id), do: nil

  defp ensure_body_user_matches(%User{} = user, attrs) do
    requested_user_id =
      normalize_string(attrs["userId"] || attrs[:userId] || attrs["user_id"] || attrs[:user_id])

    if is_nil(requested_user_id) || requested_user_id == user.id do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp ensure_participant(chat_id, user_id) do
    if Chat.is_participant?(chat_id, user_id) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp ensure_can_send(chat_id, user_id) do
    if Chat.can_send?(chat_id, user_id) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp require_chat_id(chat_id) when is_binary(chat_id) and chat_id != "", do: {:ok, chat_id}
  defp require_chat_id(_chat_id), do: {:error, :bad_request}

  defp require_message_id(message_id) when is_binary(message_id) and message_id != "",
    do: {:ok, message_id}

  defp require_message_id(_message_id), do: {:error, :bad_request}

  defp require_encrypted_content(value) when is_binary(value) and value != "", do: {:ok, value}
  defp require_encrypted_content(_value), do: {:error, :bad_request}

  defp extract_chat_id(attrs) when is_map(attrs) do
    topic_chat_id =
      case attrs["topic"] || attrs[:topic] do
        "chat:" <> chat_id -> chat_id
        _ -> nil
      end

    normalize_string(attrs["chatId"] || attrs[:chatId] || attrs["chat_id"] || topic_chat_id)
  end

  defp extract_payload(attrs) when is_map(attrs) do
    case attrs["payload"] || attrs[:payload] do
      payload when is_map(payload) -> payload
      _ -> attrs
    end
  end

  defp normalize_limit(value) do
    case normalize_integer(value) do
      int when is_integer(int) and int > 0 -> min(int, 100)
      _ -> nil
    end
  end

  defp parse_history_cursor(nil), do: nil
  defp parse_history_cursor(""), do: nil

  defp parse_history_cursor(cursor) when is_binary(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"timestamp" => timestamp, "id" => id}} <- Jason.decode(raw),
         ts when is_integer(ts) <- normalize_integer(timestamp),
         normalized_id when is_binary(normalized_id) <- normalize_string(id) do
      %{timestamp: ts, id: normalized_id}
    else
      _ -> nil
    end
  end

  defp parse_history_cursor(_cursor), do: nil

  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(_value), do: []

  defp paginate_saved_messages(messages, limit, before) when is_list(messages) do
    filtered =
      case before do
        %{timestamp: timestamp, id: id} ->
          Enum.filter(messages, fn message ->
            message_timestamp = saved_message_sort_key(message)
            message_id = normalize_string(Map.get(message, :id) || Map.get(message, "id")) || ""
            message_timestamp < timestamp or (message_timestamp == timestamp and message_id < id)
          end)

        _ ->
          messages
      end

    filtered_desc = Enum.reverse(filtered)
    has_more = length(filtered_desc) > limit
    page_desc = Enum.take(filtered_desc, limit)

    next_cursor =
      if has_more do
        page_desc
        |> List.last()
        |> encode_saved_message_cursor()
      else
        nil
      end

    %{
      messages: Enum.reverse(page_desc),
      next_cursor: next_cursor,
      has_more: has_more
    }
  end

  defp encode_saved_message_cursor(message) do
    id =
      normalize_string(Map.get(message, :id) || Map.get(message, "id"))

    timestamp = saved_message_sort_key(message)

    if is_binary(id) do
      Jason.encode!(%{timestamp: timestamp, id: id})
      |> Base.url_encode64(padding: false)
    else
      nil
    end
  end

  defp saved_message_sort_key(message) do
    normalize_integer(Map.get(message, :timestamp) || Map.get(message, "timestamp")) || 0
  end

  defp rewrite_media_url(url), do: Storage.rewrite_public_url(url)

  defp ms_to_naive(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_naive()
  end

  defp naive_to_ms(nil), do: nil

  defp naive_to_ms(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp normalize_integer(value) when is_integer(value), do: value
  defp normalize_integer(value) when is_float(value), do: trunc(value)

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when value in [true, false], do: nil

  defp normalize_string(value) when is_atom(value) do
    value |> Atom.to_string() |> normalize_string()
  end

  defp normalize_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_string(_value), do: nil

  defp truthy?(value, default \\ false)
  defp truthy?(nil, default), do: default
  defp truthy?(value, _default) when is_boolean(value), do: value
  defp truthy?(value, _default) when is_integer(value), do: value != 0

  defp truthy?(value, _default) when is_binary(value) do
    normalized = String.downcase(String.trim(value))
    normalized in ["1", "true", "yes", "on"]
  end

  defp truthy?(_value, default), do: default
end
