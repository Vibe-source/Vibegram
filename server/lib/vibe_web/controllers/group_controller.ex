defmodule VibeWeb.GroupController do
  use VibeWeb, :controller
  alias Vibe.Accounts
  alias Vibe.AI.LocalAgentWorker
  alias Vibe.Agents
  alias Vibe.Chat

  def create(conn, %{"name" => name, "memberIds" => member_ids} = params) do
    creator_id = conn.assigns.current_user.id
    avatar_url = params["avatarUrl"]
    description = params["description"]
    ensure_local_agent_users(member_ids)

    invalid_agent =
      Enum.find(member_ids, fn uid ->
        case Accounts.get_user(uid) do
          %{is_agent: true} -> not addable_agent_user?(uid, creator_id)
          _ -> false
        end
      end)

    if invalid_agent do
      conn |> put_status(:forbidden) |> json(%{error: "Agent not available"})
    else
      case Chat.create_group(creator_id, name, member_ids, avatar_url, description) do
        {:ok, room} ->
          json(conn, Chat.canonical_room_summary(room, role: "owner"))

        {:error, reason} ->
          conn |> put_status(500) |> json(%{error: "Failed to create group: #{inspect(reason)}"})
      end
    end
  end

  def add_members(conn, %{"id" => chat_id, "memberIds" => member_ids}) do
    requester_id = conn.assigns.current_user.id
    settings = Chat.get_participant_settings(chat_id, requester_id)
    ensure_local_agent_users(member_ids)

    if settings && settings.role in ["owner", "admin"] do
      results =
        Enum.map(member_ids, fn uid ->
          case Accounts.get_user(uid) do
            %{is_agent: true} ->
              if addable_agent_user?(uid, requester_id) do
                case Chat.add_member(chat_id, uid, "member", actor_id: requester_id) do
                  {:ok, _} -> %{userId: uid, added: true}
                  _ -> %{userId: uid, added: false}
                end
              else
                %{userId: uid, added: false}
              end

            _ ->
              case Chat.add_member(chat_id, uid, "member", actor_id: requester_id) do
                {:ok, _} -> %{userId: uid, added: true}
                _ -> %{userId: uid, added: false}
              end
          end
        end)

      json(conn, %{results: results})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not authorized"})
    end
  end

  # Our own team (server-runtime workers) is private: only an allowlisted owner can
  # add them to a group. Public agents stay addable by anyone.
  defp addable_agent_user?(uid, requester_id) do
    case LocalAgentWorker.resolve_by_agent_user_id(uid) do
      nil ->
        Agents.published_agent_user?(uid)

      worker ->
        not LocalAgentWorker.server_runtime?(worker) or
          LocalAgentWorker.dispatch_allowed?(worker, requester_id)
    end
  end

  defp ensure_local_agent_users(member_ids) when is_list(member_ids) do
    if Enum.any?(member_ids, &(LocalAgentWorker.resolve_by_agent_user_id(&1) != nil)) do
      LocalAgentWorker.ensure_agent_users()
    end
  end

  defp ensure_local_agent_users(_), do: :ok

  def remove_member(conn, %{"id" => chat_id, "user_id" => user_id}) do
    requester_id = conn.assigns.current_user.id
    settings = Chat.get_participant_settings(chat_id, requester_id)

    if settings && settings.role in ["owner", "admin"] do
      case Chat.remove_member(chat_id, user_id, actor_id: requester_id) do
        {1, _} -> json(conn, %{success: true})
        _ -> conn |> put_status(400) |> json(%{error: "Failed to remove member"})
      end
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not authorized"})
    end
  end

  def update(conn, %{"id" => chat_id} = params) do
    actor_id = conn.assigns.current_user.id

    case Chat.update_group(chat_id, actor_id, params) do
      {:ok, room} ->
        json(conn, %{
          chatId: room.id,
          name: room.name,
          description: room.description,
          avatarUrl: room.avatar_url
        })

      {:error, reason} ->
        respond_group_error(conn, reason)
    end
  end

  def delete(conn, %{"id" => chat_id}) do
    actor_id = conn.assigns.current_user.id

    case Chat.delete_group(chat_id, actor_id) do
      {:ok, _} -> json(conn, %{success: true})
      {:error, reason} -> respond_group_error(conn, reason)
    end
  end

  def leave(conn, %{"id" => chat_id}) do
    actor_id = conn.assigns.current_user.id

    case Chat.leave_group(chat_id, actor_id) do
      {:ok, _} -> json(conn, %{success: true})
      {:error, reason} -> respond_group_error(conn, reason)
    end
  end

  def set_role(conn, %{"id" => chat_id, "user_id" => user_id, "role" => role}) do
    actor_id = conn.assigns.current_user.id

    case Chat.set_member_role(chat_id, actor_id, user_id, role) do
      {:ok, participant} ->
        json(conn, %{success: true, userId: user_id, role: participant.role})

      {:error, reason} ->
        respond_group_error(conn, reason)
    end
  end

  defp respond_group_error(conn, reason) do
    {status, message} =
      case reason do
        :not_found -> {:not_found, "Group not found"}
        :not_authorized -> {:forbidden, "Not authorized"}
        :not_member -> {:forbidden, "Not a member"}
        :owner_cannot_leave -> {:forbidden, "Owner can't leave — delete the group instead"}
        :cannot_change_owner -> {:forbidden, "The owner's role can't be changed"}
        :invalid_role -> {:bad_request, "Invalid role"}
        _ -> {:bad_request, "Group update failed"}
      end

    conn |> put_status(status) |> json(%{error: message})
  end
end
