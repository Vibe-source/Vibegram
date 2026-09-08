defmodule VibeWeb.ChatController do
  use VibeWeb, :controller
  alias Vibe.Chat
  alias Vibe.Accounts
  alias Vibe.Agents
  alias Vibe.AI.LocalAgentWorker
  require Logger

  def create(conn, %{"friendId" => friend_id}) do
    my_id = conn.assigns.current_user.id

    case Accounts.get_user(friend_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "User not found"})

      %{is_agent: true} ->
        if Agents.published_agent_user?(friend_id) or
             LocalAgentWorker.resolve_by_agent_user_id(friend_id) != nil do
          do_create_chat(conn, my_id, friend_id)
        else
          conn |> put_status(:forbidden) |> json(%{error: "Agent not available"})
        end

      _user ->
        do_create_chat(conn, my_id, friend_id)
    end
  end

  defp do_create_chat(conn, my_id, friend_id) do
    case Chat.ensure_dm_chat(my_id, friend_id) do
      {:ok, chat_id, "created"} ->
        json(conn, %{chatId: chat_id, messages: [], nextCursor: nil, hasMore: false})

      {:ok, chat_id, "restored"} ->
        json(conn, %{chatId: chat_id, messages: [], nextCursor: nil, hasMore: false})

      {:ok, chat_id, _status} ->
        page = Chat.get_messages_for_user_page(chat_id, my_id, limit: 30)

        json(conn, %{
          chatId: chat_id,
          messages: page.messages,
          nextCursor: page.next_cursor,
          hasMore: page.has_more
        })

      _ ->
        conn |> put_status(500) |> json(%{error: "Failed to create chat"})
    end
  end

  def messages(conn, %{"chat_id" => chat_id}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      page =
        Chat.get_messages_for_user_page(
          chat_id,
          user_id,
          limit: parse_limit(conn.params["limit"]),
          before: conn.params["before"]
        )

      json(conn, %{
        messages: page.messages,
        nextCursor: page.next_cursor,
        hasMore: page.has_more
      })
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def delete_message(conn, %{"chat_id" => chat_id, "message_id" => message_id} = params) do
    user_id = conn.assigns.current_user.id

    for_everyone =
      case Map.get(params, "for_everyone", true) do
        v when v in [true, "true", "1", 1] -> true
        _ -> false
      end

    case Chat.delete_message(chat_id, message_id, user_id, for_everyone) do
      {:ok, _message} ->
        mutation_payload = %{
          chatId: chat_id,
          messageId: message_id,
          deletedBy: user_id,
          forEveryone: for_everyone
        }

        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message-deleted", mutation_payload)

        Chat.broadcast_user_chat_event(
          chat_id,
          "message-deleted",
          mutation_payload,
          if(for_everyone, do: nil, else: [user_id])
        )

        json(conn, %{success: true, messageId: message_id, forEveryone: for_everyone})

      {:error, :invalid_id} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid message id"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "Not allowed"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Message not found"})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  def message_reactions(conn, %{"chat_id" => chat_id, "message_id" => message_id}) do
    user_id = conn.assigns.current_user.id

    case Chat.message_reaction_detail(chat_id, message_id, user_id) do
      {:ok, groups} ->
        json(conn, %{
          chatId: chat_id,
          messageId: message_id,
          total: Enum.reduce(groups, 0, &(&1.count + &2)),
          reactions: groups
        })

      {:error, :invalid_id} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid message id"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Message not found"})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  def report_message(conn, %{"chat_id" => chat_id, "message_id" => message_id} = params) do
    user_id = conn.assigns.current_user.id

    case Chat.report_message(chat_id, message_id, user_id, params) do
      {:ok, %{report: report, blocked: blocked}} ->
        json(conn, %{
          success: true,
          blocked: blocked,
          report: %{
            id: report.id,
            chatId: report.chat_id,
            messageId: report.source_message_id,
            reason: report.reason,
            details: report.details,
            status: report.status,
            reportedUserId: report.reported_user_id,
            createdAt: report.inserted_at
          }
        })

      {:error, :invalid_id} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid message id"})

      {:error, :invalid_reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid reason", reasons: Chat.report_reasons()})

      {:error, :details_too_long} ->
        conn |> put_status(:bad_request) |> json(%{error: "Details too long"})

      {:error, :invalid_details} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid details"})

      {:error, :invalid_target} ->
        conn |> put_status(:bad_request) |> json(%{error: "Cannot report this message"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Message not found"})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  def list_pinned_messages(conn, %{"chat_id" => chat_id}) do
    user_id = conn.assigns.current_user.id

    cond do
      chat_id == "saved_messages" ->
        json(conn, %{data: []})

      true ->
        case Chat.list_pinned_messages_for_user(chat_id, user_id) do
          {:ok, pins} ->
            Logger.info(
              "[ChatController] list_pinned_messages chat_id=#{chat_id} user_id=#{user_id} count=#{length(pins)}"
            )

            json(conn, %{data: pins})

          {:error, :forbidden} ->
            Logger.warning(
              "[ChatController] list_pinned_messages forbidden chat_id=#{chat_id} user_id=#{user_id}"
            )

            conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
        end
    end
  end

  def pin_message(conn, %{"chat_id" => chat_id, "message_id" => message_id} = params) do
    user_id = conn.assigns.current_user.id

    pinned =
      case Map.get(params, "pinned", true) do
        v when v in [true, "true", "1", 1] -> true
        _ -> false
      end

    Logger.info(
      "[ChatController] pin_message request chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id} pinned=#{pinned}"
    )

    case Chat.set_message_pin(chat_id, message_id, user_id, pinned) do
      {:ok, :unpinned} ->
        Logger.info(
          "[ChatController] pin_message ok chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id} pinned=false"
        )

        json(conn, %{success: true, pinned: false, messageId: message_id})

      {:ok, _pin} ->
        Logger.info(
          "[ChatController] pin_message ok chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id} pinned=true"
        )

        json(conn, %{success: true, pinned: true, messageId: message_id})

      {:error, :invalid_id} ->
        Logger.warning(
          "[ChatController] pin_message invalid_id chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id}"
        )

        conn |> put_status(:bad_request) |> json(%{error: "Invalid message id"})

      {:error, :forbidden} ->
        Logger.warning(
          "[ChatController] pin_message forbidden chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id}"
        )

        conn |> put_status(:forbidden) |> json(%{error: "Not allowed"})

      {:error, :not_found} ->
        Logger.warning(
          "[ChatController] pin_message not_found chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id}"
        )

        conn |> put_status(:not_found) |> json(%{error: "Message not found"})

      {:error, reason} ->
        Logger.warning(
          "[ChatController] pin_message error chat_id=#{chat_id} user_id=#{user_id} message_id=#{message_id} reason=#{inspect(reason)}"
        )

        conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  def index(conn, %{"user_id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      archived = Map.get(conn.params, "archived") in [true, "true", "1", 1]

      chats =
        case Chat.list_chats(current_id, archived: archived) do
          list when is_list(list) -> list
          _ -> []
        end

      json(conn, chats)
    end
  end

  def mute(conn, %{"chat_id" => chat_id, "muted" => muted}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      {count, _} = Chat.set_muted(chat_id, user_id, muted)
      json(conn, %{success: count > 0})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def pin(conn, %{"chat_id" => chat_id, "pinned" => pinned}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      {count, _} = Chat.set_pinned(chat_id, user_id, pinned)
      json(conn, %{success: count > 0})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def mark_unread(conn, %{"chat_id" => chat_id, "unread" => unread}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      {count, _} = Chat.set_marked_unread(chat_id, user_id, unread)
      json(conn, %{success: count > 0})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def archive(conn, %{"chat_id" => chat_id, "archived" => archived}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      {count, _} = Chat.set_archived(chat_id, user_id, archived)
      json(conn, %{success: count > 0, archived: archived})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  @doc """
  Clear this user's copy of a chat's messages. The chat, its membership and its
  encryption survive — `delete/2` is the destructive one.
  """
  def clear_messages(conn, %{"chat_id" => chat_id}) do
    user_id = conn.assigns.current_user.id

    case Chat.clear_messages(chat_id, user_id) do
      {:ok, result} ->
        Chat.broadcast_user_chat_event(
          chat_id,
          "chat-cleared",
          %{chatId: chat_id, clearedAt: result.cleared_at},
          [user_id]
        )

        json(conn, %{success: true, chatId: chat_id, clearedAt: result.cleared_at})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: reason})
    end
  end

  def delete(conn, %{"chat_id" => chat_id} = params) do
    user_id = conn.assigns.current_user.id

    delete_for_everyone =
      truthy?(
        params["deleteForEveryone"] || params["delete_for_everyone"] || params["forEveryone"] ||
          params["for_everyone"]
      )

    if Chat.is_participant?(chat_id, user_id) do
      case Chat.delete_chat(chat_id, user_id, delete_for_everyone: delete_for_everyone) do
        {:ok, result} ->
          Chat.broadcast_user_chat_event(
            chat_id,
            "chat-deleted",
            %{
              chatId: chat_id,
              deletedBy: user_id,
              forEveryone: result.for_everyone
            },
            result.target_user_ids
          )

          json(conn, %{
            success: true,
            deleteForEveryone: result.for_everyone,
            deletedCount: result.deleted_count
          })

        {:error, reason} ->
          conn |> put_status(400) |> json(%{error: reason})
      end
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  defp parse_limit(nil), do: nil

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp parse_limit(limit) when is_integer(limit), do: limit
  defp parse_limit(_limit), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp truthy?(_value), do: false
end
