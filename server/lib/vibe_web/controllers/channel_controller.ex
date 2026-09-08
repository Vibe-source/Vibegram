defmodule VibeWeb.ChannelController do
  use VibeWeb, :controller
  alias Vibe.Chat

  def create(conn, params) when is_map(params) do
    params =
      if is_binary(params["name"]) do
        params
      else
        Map.put(params, "name", params["channelName"] || params["title"])
      end

    case Chat.create_channel(conn.assigns.current_user.id, params) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  def index(conn, _params), do: json(conn, Chat.list_channels())

  def show(conn, %{"id" => channel_id}) do
    case Chat.get_channel_profile(channel_id, conn.assigns.current_user.id) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  def update(conn, %{"id" => channel_id} = params) do
    actor_id = conn.assigns.current_user.id

    case Chat.update_channel(channel_id, actor_id, params) do
      {:ok, room} ->
        json(
          conn,
          Chat.canonical_room_summary(room, role: Chat.get_user_role(channel_id, actor_id))
        )

      {:error, reason} ->
        respond_error(conn, reason)
    end
  end

  def join(conn, %{"id" => channel_id}) do
    case Chat.join_channel(channel_id, conn.assigns.current_user.id) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  def leave(conn, %{"id" => channel_id}) do
    case Chat.leave_channel(channel_id, conn.assigns.current_user.id) do
      {:ok, _} -> json(conn, %{success: true})
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  def analytics(conn, %{"id" => channel_id}) do
    user_id = conn.assigns.current_user.id

    if Chat.get_user_role(channel_id, user_id) in ["owner", "admin"] do
      json(conn, Chat.get_channel_analytics(channel_id, user_id))
    else
      respond_error(conn, :not_authorized)
    end
  end

  def create_invite(conn, %{"id" => channel_id} = params) do
    case Chat.create_channel_invite_link(channel_id, conn.assigns.current_user.id, params) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  def rotate_invite(conn, params), do: create_invite(conn, params)

  def resolve_link(conn, params) do
    case Chat.resolve_channel_link(link_input(params)) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  def join_link(conn, params) do
    case Chat.join_channel_link(conn.assigns.current_user.id, link_input(params)) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  def join_requests(conn, %{"id" => channel_id}) do
    case Chat.list_channel_join_requests(channel_id, conn.assigns.current_user.id) do
      {:ok, requests} -> json(conn, %{requests: requests})
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  def decide_join_request(conn, %{"id" => channel_id, "request_id" => request_id} = params) do
    decision = params["decision"] || params["status"]

    case Chat.decide_channel_join_request(
           channel_id,
           request_id,
           conn.assigns.current_user.id,
           decision
         ) do
      {:ok, request} -> json(conn, request)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  def agents(conn, %{"id" => channel_id}) do
    case Chat.list_channel_agents(channel_id, conn.assigns.current_user.id) do
      {:ok, agents} -> json(conn, %{agents: agents})
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  def attach_agent(conn, %{"id" => channel_id} = params) do
    agent_id = params["agentId"] || params["agent_id"]

    case Chat.attach_channel_agent(channel_id, conn.assigns.current_user.id, agent_id, params) do
      {:ok, assignment} -> json(conn, assignment)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  def update_agent(conn, %{"id" => channel_id, "agent_id" => agent_id} = params) do
    case Chat.update_channel_agent(channel_id, conn.assigns.current_user.id, agent_id, params) do
      {:ok, assignment} -> json(conn, assignment)
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  def detach_agent(conn, %{"id" => channel_id, "agent_id" => agent_id}) do
    case Chat.detach_channel_agent(channel_id, conn.assigns.current_user.id, agent_id) do
      :ok -> json(conn, %{success: true})
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  defp link_input(params) do
    cond do
      is_binary(params["link"]) -> params["link"]
      is_binary(params["shareLink"]) -> params["shareLink"]
      is_binary(params["token"]) -> "/j/#{params["token"]}"
      is_binary(params["slug"]) -> "/r/#{params["slug"]}"
      true -> ""
    end
  end

  defp respond_error(conn, reason) do
    {status, message} =
      case reason do
        :invalid_name -> {:bad_request, "Channel name is required"}
        :invalid_access_type -> {:bad_request, "Invalid access type"}
        :invalid_public_slug -> {:bad_request, "Invalid public slug"}
        :invalid_member_ids -> {:bad_request, "Invalid channel members"}
        :invalid_link -> {:bad_request, "Invalid room link"}
        :invalid_decision -> {:bad_request, "Invalid decision"}
        :not_found -> {:not_found, "Channel not found"}
        :not_a_channel -> {:bad_request, "Not a channel"}
        :not_member -> {:forbidden, "Not a channel member"}
        :not_authorized -> {:forbidden, "Not authorized"}
        :agent_not_owned -> {:forbidden, "Agent is not owned by this user"}
        :link_required -> {:forbidden, "A valid channel link is required"}
        :link_not_found -> {:not_found, "Room link not found"}
        :link_revoked -> {:gone, "Room link was revoked"}
        :link_expired -> {:gone, "Room link expired"}
        :link_exhausted -> {:gone, "Room link has no remaining uses"}
        :public_channel -> {:bad_request, "Public channels use their public link"}
        :already_decided -> {:conflict, "Join request was already decided"}
        :agent_already_member -> {:conflict, "Agent user is already a channel member"}
        %Ecto.Changeset{} -> {:unprocessable_entity, "Channel data is invalid"}
        value when is_binary(value) -> {:bad_request, value}
        _ -> {:bad_request, "Channel request failed"}
      end

    conn |> put_status(status) |> json(%{error: message})
  end
end
