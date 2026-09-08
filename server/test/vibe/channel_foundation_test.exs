defmodule Vibe.ChannelFoundationTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.AI.StandaloneAgent
  alias Vibe.Chat
  alias Vibe.Chat.ChannelAgentAssignment
  alias Vibe.Chat.ChannelInviteLink
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    owner = insert_user("channel_owner")
    member = insert_user("channel_member")
    second_member = insert_user("channel_member_two")

    %{owner: owner, member: member, second_member: second_member}
  end

  test "group create has canonical list parity, description, counts, and creation activity", %{
    owner: owner,
    member: member
  } do
    assert {:ok, room} = Chat.create_group(owner.id, "Research", [member.id], nil, nil)
    created = Chat.canonical_room_summary(room, role: "owner")
    listed = Chat.list_chats(owner.id) |> Enum.find(&(&1.chatId == room.id))

    assert created.type == "group"
    assert created.isGroup
    refute created.isChannel
    assert created.description == nil
    assert created.memberCount == 2
    assert created.createdAt > 0
    assert created.lastMessageAt == created.createdAt

    assert listed.type == created.type
    assert listed.name == created.name
    assert listed.description == created.description
    assert listed.memberCount == created.memberCount
    assert listed.createdAt == created.createdAt
    assert listed.lastMessageAt == created.lastMessageAt
  end

  test "private create returns a one-time raw link but persists only its digest", %{
    owner: owner,
    member: member
  } do
    assert {:ok, payload} =
             Chat.create_channel(owner.id, %{
               "name" => "Private notes",
               "description" => nil,
               "memberIds" => [member.id],
               "accessType" => "private"
             })

    assert payload.type == "channel"
    assert payload.isGroup and payload.isChannel
    assert payload.role == "owner"
    assert payload.description == nil
    assert payload.memberCount == 2
    assert payload.subscriberCount == 2
    assert payload.createdAt > 0
    assert payload.lastMessageAt == payload.createdAt
    assert "/j/" <> token = payload.shareLink

    link = Repo.one!(from_link(payload.chatId))
    assert link.token_hint == String.slice(token, -6, 6)
    assert link.token_digest == :crypto.hash(:sha256, token)
    assert :binary.match(:erlang.term_to_binary(link), token) == :nomatch

    listed = Chat.list_chats(owner.id) |> Enum.find(&(&1.chatId == payload.chatId))
    assert listed.shareLink == nil
    assert listed.accessType == "private"
    assert listed.memberCount == payload.memberCount
    assert listed.subscriberCount == payload.subscriberCount
  end

  test "public slugs are normalized and unique", %{owner: owner, member: member} do
    assert {:ok, first} =
             Chat.create_channel(owner.id, %{
               "name" => "News",
               "accessType" => "public",
               "publicSlug" => "  Daily_News  "
             })

    assert first.publicSlug == "daily-news"
    assert first.shareLink == "/r/daily-news"
    assert {:ok, resolved} = Chat.resolve_channel_link("https://vibe.example/r/daily-news")
    assert resolved.chatId == first.chatId

    assert {:error, %Ecto.Changeset{}} =
             Chat.create_channel(member.id, %{
               "name" => "Copy",
               "accessType" => "public",
               "publicSlug" => "DAILY NEWS"
             })

    assert {:error, :invalid_public_slug} =
             Chat.create_channel(owner.id, %{
               "name" => "Bad",
               "accessType" => "public",
               "publicSlug" => "x"
             })
  end

  test "private links enforce rotation, expiry, and use exhaustion", %{
    owner: owner,
    member: member,
    second_member: second_member
  } do
    payload = create_private_channel(owner)
    old_link = payload.shareLink

    assert {:ok, rotated} =
             Chat.create_channel_invite_link(payload.chatId, owner.id, %{"maxUses" => 1})

    assert {:error, :link_revoked} = Chat.resolve_channel_link(old_link)

    assert {:ok, %{status: "joined"}} = Chat.join_channel_link(member.id, rotated.shareLink)
    assert {:error, :link_exhausted} = Chat.join_channel_link(second_member.id, rotated.shareLink)

    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

    assert {:ok, expired} =
             Chat.create_channel_invite_link(payload.chatId, owner.id, %{"expiresAt" => past})

    assert {:error, :link_expired} = Chat.resolve_channel_link(expired.shareLink)
  end

  test "approval-required links create pending requests and only admins decide", %{
    owner: owner,
    member: member,
    second_member: outsider
  } do
    assert {:ok, payload} =
             Chat.create_channel(owner.id, %{
               "name" => "Review queue",
               "accessType" => "private",
               "joinApprovalRequired" => true,
               "memberIds" => [member.id]
             })

    assert {:ok, %{status: "pending", request: request}} =
             Chat.join_channel_link(outsider.id, payload.shareLink)

    refute Chat.is_participant?(payload.chatId, outsider.id)

    assert {:error, :not_authorized} =
             Chat.decide_channel_join_request(payload.chatId, request.id, member.id, "approve")

    assert {:ok, %{status: "approved"}} =
             Chat.decide_channel_join_request(payload.chatId, request.id, owner.id, "approve")

    assert Chat.get_user_role(payload.chatId, outsider.id) == "subscriber"
  end

  test "agent admins publish with intersection policy but never gain human admin authority", %{
    owner: owner,
    member: member
  } do
    agent =
      insert_agent(owner, enabled_tools: ["search", "documents"], output_modes: ["text", "voice"])

    other_owner = insert_user("other_owner")
    other_agent = insert_agent(other_owner)
    payload = create_private_channel(owner)

    assert {:ok, assignment} =
             Chat.attach_channel_agent(payload.chatId, owner.id, agent.id, %{
               "allowedTools" => ["search", "not-owned"],
               "allowedOutputModes" => ["text"],
               "permissions" => %{"publish" => true}
             })

    assert assignment.role == "agent_admin"
    assert assignment.roleLabel == "Agent admin"
    assert assignment.effectiveTools == ["search"]
    assert assignment.effectiveOutputModes == ["text"]
    assert Chat.can_send?(payload.chatId, agent.agent_user_id)
    refute Chat.can_send?(payload.chatId, member.id)

    assert {:ok, policy} = Chat.channel_agent_policy(payload.chatId, agent)
    assert policy.enabled_tools == ["search"]
    assert policy.output_modes == ["text"]

    assert {:error, :not_authorized} =
             Chat.update_channel(payload.chatId, agent.agent_user_id, %{"name" => "No"})

    assert {:ok, _fully_restricted} =
             Chat.update_channel_agent(payload.chatId, owner.id, agent.id, %{
               "allowedTools" => [],
               "allowedOutputModes" => []
             })

    assert {:ok, fully_restricted_policy} = Chat.channel_agent_policy(payload.chatId, agent)
    assert fully_restricted_policy.enabled_tools == []
    assert fully_restricted_policy.output_modes == []

    assert {:error, :not_authorized} =
             Chat.attach_channel_agent(payload.chatId, agent.agent_user_id, other_agent.id)

    assert {:error, :agent_not_owned} =
             Chat.attach_channel_agent(payload.chatId, owner.id, other_agent.id)

    assert {:ok, disabled} =
             Chat.update_channel_agent(payload.chatId, owner.id, agent.id, %{
               "status" => "disabled"
             })

    assert disabled.status == "disabled"
    refute Chat.can_send?(payload.chatId, agent.agent_user_id)
    assert {:error, :chat_not_attached} = Chat.channel_agent_policy(payload.chatId, agent)

    assert :ok = Chat.detach_channel_agent(payload.chatId, owner.id, agent.id)
    assert Repo.get_by(ChannelAgentAssignment, chat_id: payload.chatId, agent_id: agent.id) == nil
    assert Chat.get_user_role(payload.chatId, agent.agent_user_id) == nil

    assert {:error, :chat_not_attached} =
             StandaloneAgent.invoke(agent, %{
               "message" => "publish",
               "responseMode" => "send",
               "vibeChatId" => payload.chatId
             })
  end

  test "attaching an agent does not overwrite an unrelated default destination", %{owner: owner} do
    agent = insert_agent(owner, default_destination_chat_id: "existing-room")
    payload = create_private_channel(owner)

    assert {:ok, _} = Chat.attach_channel_agent(payload.chatId, owner.id, agent.id)
    assert Repo.get!(Agent, agent.id).default_destination_chat_id == "existing-room"
  end

  test "interval assignments are durably scheduled and atomically claimed", %{owner: owner} do
    agent = insert_agent(owner, enabled_tools: ["search"], output_modes: ["text"])
    payload = create_private_channel(owner)

    assert {:ok, attached} =
             Chat.attach_channel_agent(payload.chatId, owner.id, agent.id, %{
               "triggerConfig" => %{"type" => "interval", "everyMinutes" => 60}
             })

    assert attached.allowedTools == ["search"]
    assert attached.allowedOutputModes == ["text"]
    assert %DateTime{} = attached.nextTriggerAt

    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    from(a in ChannelAgentAssignment, where: a.id == ^attached.id)
    |> Repo.update_all(set: [next_trigger_at: past])

    assert {:ok, [claimed]} = Chat.claim_due_channel_agent_assignments(1)
    assert claimed.id == attached.id

    reloaded = Repo.get!(ChannelAgentAssignment, attached.id)
    assert reloaded.last_trigger_status == "running"
    assert DateTime.compare(reloaded.next_trigger_at, DateTime.utc_now()) == :gt

    assert {:ok, completed} =
             Chat.complete_channel_agent_trigger(attached.id, "completed")

    assert completed.last_trigger_status == "completed"
  end

  test "protected channel payloads are rejected by server copy enforcement", %{owner: owner} do
    assert {:ok, payload} =
             Chat.create_channel(owner.id, %{
               "name" => "Protected",
               "restrictSavingContent" => true
             })

    assert Chat.content_copy_restricted?(%{"forwardedFromChatId" => payload.chatId})
    refute Chat.content_copy_restricted?(%{"forwardedFromChatId" => "unrelated"})

    assert {:error, :content_saving_restricted} =
             Chat.save_message(%{
               "user_id" => owner.id,
               "original_message_id" => Ecto.UUID.generate(),
               "type" => "text",
               "source_chat_id" => payload.chatId
             })
  end

  test "channel create attaches selected owned agents in the same canonical result", %{
    owner: owner,
    member: member
  } do
    agent = insert_agent(owner)

    assert {:ok, payload} =
             Chat.create_channel(owner.id, %{
               "name" => "Publisher room",
               "memberIds" => [member.id],
               "agentAdminIds" => [agent.id]
             })

    assert payload.memberCount == 3
    assert payload.subscriberCount == 2

    assert Enum.any?(
             payload.members,
             &(&1.userId == agent.agent_user_id and &1.role == "agent_admin")
           )

    assert Repo.get_by!(ChannelAgentAssignment, chat_id: payload.chatId, agent_id: agent.id)
    assert Chat.can_send?(payload.chatId, agent.agent_user_id)
  end

  defp create_private_channel(owner) do
    assert {:ok, payload} =
             Chat.create_channel(owner.id, %{"name" => "Private", "accessType" => "private"})

    payload
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

  defp insert_agent(owner, attrs \\ []) do
    shadow = insert_user("agent_shadow", %{is_agent: true})

    defaults = %{
      owner_user_id: owner.id,
      agent_user_id: shadow.id,
      status: "published",
      display_name: "Publisher",
      enabled_tools: [],
      output_modes: ["text"],
      webhook_secret_hash: "hash",
      secret_hint: "hint"
    }

    agent = Repo.insert!(struct(Agent, Map.merge(defaults, Map.new(attrs))))
    Repo.preload(agent, :agent_user)
  end

  defp from_link(chat_id) do
    import Ecto.Query
    from(link in ChannelInviteLink, where: link.chat_id == ^chat_id)
  end
end
