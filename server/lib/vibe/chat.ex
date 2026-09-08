defmodule Vibe.Chat do
  import Ecto.Query, warn: false
  require Logger
  alias Vibe.ChatHomeCache
  alias Vibe.Accounts
  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.Repo
  alias Vibe.RepoRLS
  alias Vibe.Storage

  alias Vibe.Accounts.UserBlock

  alias Vibe.Chat.{
    Room,
    Message,
    Participant,
    ChannelInviteLink,
    ChannelJoinRequest,
    ChannelAgentAssignment,
    MessageRead,
    MessageReaction,
    MessageReport,
    MessageView,
    SavedMessage,
    ScheduledPost,
    PinnedMessage,
    AgentMessageCrypto
  }

  @agent_user_id "00000000-0000-0000-0000-000000000001"
  @home_preview_message_limit 1
  @history_default_limit 30
  @history_max_limit 100

  # Sealed/base64 blob fields that exist only for the open chat surface.
  @mirror_dropped_keys [
    "agentBridgeAttachmentsEnc",
    "attachmentThumbnailsB64",
    :agentBridgeAttachmentsEnc,
    :attachmentThumbnailsB64
  ]
  # Hard ceiling on one mirrored message.
  @mirror_max_bytes 16_384

  @doc """
  Compact copy of a chat-topic `message` payload, for the per-user `new_message` mirror.
  """
  def mirrored_message_payload(payload) when is_map(payload) do
    compacted =
      payload
      |> Map.drop(@mirror_dropped_keys)
      |> compact_mirrored_metadata("metadata")
      |> compact_mirrored_metadata(:metadata)

    case Jason.encode(compacted) do
      {:ok, encoded} when byte_size(encoded) <= @mirror_max_bytes -> compacted
      _ -> nil
    end
  end

  def mirrored_message_payload(_payload), do: nil

  defp compact_mirrored_metadata(payload, key) do
    case Map.get(payload, key) do
      metadata when is_map(metadata) ->
        Map.put(payload, key, Map.drop(metadata, @mirror_dropped_keys))

      _ ->
        payload
    end
  end

  def save_message(attrs) do
    if content_copy_restricted?(attrs) do
      {:error, :content_saving_restricted}
    else
      %SavedMessage{}
      |> SavedMessage.changeset(attrs)
      |> Repo.insert(on_conflict: :nothing)
    end
  end

  @doc "Returns true when a save/forward payload names a protected source channel."
  def content_copy_restricted?(attrs) when is_map(attrs) do
    source_chat_id =
      attrs["sourceChatId"] || attrs["source_chat_id"] || attrs["forwardedFromChatId"] ||
        attrs["forwarded_from_chat_id"] || attrs[:source_chat_id] ||
        attrs[:forwarded_from_chat_id]

    case present_string(source_chat_id) do
      nil ->
        false

      chat_id ->
        Repo.exists?(
          from(room in Room,
            where:
              room.id == ^chat_id and room.type == "channel" and
                room.restrict_saving_content == true
          )
        )
    end
  end

  def content_copy_restricted?(_), do: false

  def unsave_message(user_id, original_message_id) do
    from(sm in SavedMessage,
      where: sm.user_id == ^user_id and sm.original_message_id == ^original_message_id
    )
    |> Repo.delete_all()
  end

  def list_saved_messages(user_id) do
    Repo.all(
      from(sm in SavedMessage,
        where: sm.user_id == ^user_id,
        order_by: [desc: sm.timestamp]
      )
    )
    |> Enum.map(&to_client_saved_message/1)
  end

  @doc "Toggles the caller's private Saved Messages reaction; one emoji per saved item."
  def toggle_saved_message_reaction(user_id, original_message_id, emoji) do
    with {:ok, normalized} <- normalize_emoji(emoji),
         {:ok, actor_id} <- normalize_saved_message_actor(user_id),
         {:ok, key} <- normalize_saved_message_key(original_message_id) do
      Repo.transaction(fn ->
        case lock_saved_message(actor_id, key) do
          %SavedMessage{} = saved -> apply_saved_message_reaction(saved, normalized)
          nil -> Repo.rollback(:not_found)
        end
      end)
    end
  end

  defp lock_saved_message(user_id, original_message_id) do
    Repo.one(
      from(sm in SavedMessage,
        where: sm.user_id == ^user_id and sm.original_message_id == ^original_message_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp apply_saved_message_reaction(%SavedMessage{} = saved, emoji) do
    {next, action} =
      cond do
        saved.reaction_emoji == emoji -> {nil, :removed}
        is_nil(saved.reaction_emoji) or saved.reaction_emoji == "" -> {emoji, :added}
        true -> {emoji, :replaced}
      end

    from(sm in SavedMessage, where: sm.id == ^saved.id)
    |> Repo.update_all(
      set: [
        reaction_emoji: next,
        updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      ]
    )

    %{
      original_message_id: saved.original_message_id,
      action: action,
      emoji: emoji,
      reactions: saved_message_reactions(next)
    }
  end

  defp normalize_saved_message_actor(user_id) do
    case present_string(user_id) do
      nil -> {:error, :invalid_id}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_saved_message_key(original_message_id) do
    case present_string(original_message_id) do
      nil -> {:error, :invalid_id}
      trimmed -> {:ok, trimmed}
    end
  end

  defp saved_message_reactions(emoji) when is_binary(emoji) and emoji != "",
    do: [%{emoji: emoji, count: 1, isSelected: true}]

  defp saved_message_reactions(_emoji), do: []

  def is_participant?(chat_id, user_id) do
    Vibe.Cache.fetch(participant_cache_key(chat_id, user_id), 30_000, fn ->
      Repo.exists?(
        from(p in Participant,
          where:
            p.chat_id == ^chat_id and p.user_id == ^user_id and
              (is_nil(p.deleted) or p.deleted == false)
        )
      )
    end)
  end

  defp participant_cache_key(chat_id, user_id), do: {:participant, chat_id, user_id}

  def get_participant_ids(chat_id) do
    Repo.all(
      from(p in Participant,
        where: p.chat_id == ^chat_id,
        select: p.user_id
      )
    )
  end

  def get_participant_settings(chat_id, user_id) do
    Repo.one(from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id))
  end

  def get_all_participant_settings(chat_id) do
    Repo.all(from(p in Participant, where: p.chat_id == ^chat_id))
  end

  @doc false
  def broadcast_user_chat_event(chat_id, event, payload, user_ids \\ nil)
      when is_binary(chat_id) and is_binary(event) and is_map(payload) do
    recipients =
      case user_ids do
        ids when is_list(ids) -> ids
        _ -> get_participant_ids(chat_id)
      end

    payload =
      if Map.has_key?(payload, :chatId) or Map.has_key?(payload, "chatId") or
           Map.has_key?(payload, :chat_id) or Map.has_key?(payload, "chat_id") do
        payload
      else
        Map.put(payload, :chatId, chat_id)
      end

    recipients
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.each(fn user_id ->
      VibeWeb.Endpoint.broadcast!("user:#{user_id}", event, payload)
    end)

    :ok
  end

  @doc false
  def broadcast_message_receipt(chat_id, message_id, actor_id, status)
      when status in ["delivered", "read"] do
    case get_message(chat_id, message_id, actor_id) do
      %Message{from_id: sender_id}
      when is_binary(sender_id) and sender_id != "" and sender_id != actor_id ->
        broadcast_user_chat_event(
          chat_id,
          "message-#{status}",
          %{
            chatId: chat_id,
            messageId: message_id,
            readerId: actor_id,
            status: status
          },
          [sender_id]
        )

      _ ->
        :ok
    end
  end

  def list_chats(user_id, opts \\ []) do
    archived = Keyword.get(opts, :archived, false)
    loader = fn -> list_chats_uncached(user_id, archived: archived) end

    if !archived and is_binary(user_id) and String.trim(user_id) != "" do
      ChatHomeCache.fetch(user_id, loader)
    else
      loader.()
    end
  end

  defp visible_transcript_messages(query) do
    from(m in query,
      where:
        fragment(
          "COALESCE(?->>'hiddenFromTranscript', ?->>'hidden_from_transcript', 'false') NOT IN ('true', '1')",
          m.metadata,
          m.metadata
        ) and
          fragment(
            "LOWER(COALESCE(?->>'eventInboxRole', ?->>'event_inbox_role', '')) NOT IN ('raw_event', 'inbox_item')",
            m.metadata,
            m.metadata
          )
    )
  end

  defp list_chats_uncached(user_id, opts) do
    archived = Keyword.get(opts, :archived, false)

    result =
      RepoRLS.with_user(user_id, fn ->
        user_chats_query =
          from(p in Participant,
            where:
              p.user_id == ^user_id and
                (is_nil(p.deleted) or p.deleted == false) and
                fragment("COALESCE(?, false) = ?", p.archived, ^archived),
            select: {p.chat_id, p}
          )

        results = Repo.all(user_chats_query)
        chat_ids = Enum.map(results, fn {chat_id, _} -> chat_id end)

        rooms =
          from(r in Room, where: r.id in ^chat_ids)
          |> Repo.all()
          |> Map.new(fn r -> {r.id, r} end)

        friend_participants =
          from(p in Participant,
            where: p.chat_id in ^chat_ids and p.user_id != ^user_id,
            preload: [:user]
          )
          |> Repo.all()
          |> Enum.group_by(& &1.chat_id)

        agent_friend_user_ids =
          friend_participants
          |> Map.values()
          |> List.flatten()
          |> Enum.filter(&(&1.user && &1.user.is_agent))
          |> Enum.map(& &1.user_id)
          |> Enum.uniq()

        agent_friends_by_user_id =
          if agent_friend_user_ids == [] do
            %{}
          else
            from(a in Agent,
              where: a.agent_user_id in ^agent_friend_user_ids,
              select:
                {a.agent_user_id,
                 %{
                   agent_id: a.id,
                   display_name: a.display_name,
                   avatar_url: a.avatar_url,
                   approval_rules: a.approval_rules
                 }}
            )
            |> Repo.all()
            |> Map.new()
          end

        ranked_query =
          from(m in Message,
            where: m.chat_id in ^chat_ids
          )
          |> visible_transcript_messages()
          |> then(fn query ->
            from(m in query,
              select: %{
                id: m.id,
                rnk: row_number() |> over(partition_by: m.chat_id, order_by: [desc: m.timestamp])
              }
            )
          end)

        top_message_ids =
          if chat_ids == [] do
            []
          else
            from(r in subquery(ranked_query),
              where: r.rnk <= ^@home_preview_message_limit,
              select: r.id
            )
            |> Repo.all()
          end

        last_messages_by_chat =
          if top_message_ids == [] do
            %{}
          else
            from(m in Message,
              where: m.id in ^top_message_ids,
              order_by: [asc: m.timestamp]
            )
            |> Repo.all()
            |> Enum.group_by(& &1.chat_id)
          end

        seed_reactions = batched_reaction_summaries(top_message_ids, user_id)

        group_channel_ids =
          Enum.filter(chat_ids, fn id ->
            room = Map.get(rooms, id)
            room && room.type in ["group", "channel"]
          end)

        group_members =
          if group_channel_ids != [] do
            from(p in Participant,
              where:
                p.chat_id in ^group_channel_ids and
                  (is_nil(p.deleted) or p.deleted == false),
              preload: [:user],
              order_by: [asc: p.inserted_at]
            )
            |> Repo.all()
            |> Enum.group_by(& &1.chat_id)
          else
            %{}
          end

        Enum.map(results, fn {chat_id, my_settings} ->
          room = Map.get(rooms, chat_id)
          room_type = if(room, do: room.type, else: "dm")

          friend_p =
            if room_type == "dm" do
              List.first(Map.get(friend_participants, chat_id, []))
            else
              nil
            end

          friend_agent =
            if(friend_p, do: Map.get(agent_friends_by_user_id, friend_p.user_id), else: nil)

          cleared_at_ms =
            if my_settings.messages_cleared_at do
              my_settings.messages_cleared_at
              |> DateTime.from_naive!("Etc/UTC")
              |> DateTime.to_unix(:millisecond)
            end

          chat_messages = Map.get(last_messages_by_chat, chat_id, [])

          chat_messages =
            if cleared_at_ms do
              Enum.filter(chat_messages, &(&1.timestamp > cleared_at_ms))
            else
              chat_messages
            end

          members =
            if room_type in ["group", "channel"] do
              Map.get(group_members, chat_id, [])
              |> Enum.map(fn member ->
                %{
                  userId: member.user_id,
                  name:
                    present_string(member.user && member.user.name) ||
                      present_string(member.user && member.user.username),
                  avatarUrl: present_string(member.user && member.user.profile_image),
                  role: member.role || "member"
                }
              end)
            else
              nil
            end

          messages_for_client =
            chat_messages
            |> Enum.map(&to_client_message/1)
            |> apply_reaction_summaries(seed_reactions)

          last_activity_at =
            case List.last(chat_messages) do
              %{timestamp: ts} when is_integer(ts) ->
                ts

              _ ->
                if room && room.inserted_at do
                  room.inserted_at
                  |> DateTime.from_naive!("Etc/UTC")
                  |> DateTime.to_unix(:millisecond)
                else
                  0
                end
            end

          created_at =
            if room && room.inserted_at do
              room.inserted_at
              |> DateTime.from_naive!("Etc/UTC")
              |> DateTime.to_unix(:millisecond)
            else
              0
            end

          room_members = Map.get(group_members, chat_id, [])
          member_count = if room_type in ["group", "channel"], do: length(room_members), else: nil

          subscriber_count =
            if room_type == "channel" do
              Enum.count(room_members, &(&1.role != "agent_admin"))
            end

          %{
            chatId: chat_id,
            type: room_type,
            isGroup: room_type in ["group", "channel"],
            isChannel: room_type == "channel",
            lastMessageAt: last_activity_at,
            messagesClearedAt: cleared_at_ms,
            createdAt: created_at,
            name: if(room, do: room.name, else: nil),
            description: if(room, do: room.description, else: nil),
            avatarUrl: if(room, do: room.avatar_url, else: nil),
            creatorId: if(room, do: room.creator_id, else: nil),
            memberCount: member_count,
            subscriberCount: subscriber_count,
            accessType: if(room_type == "channel", do: room.access_type || "private", else: nil),
            publicSlug: if(room_type == "channel", do: room.public_slug, else: nil),
            shareLink: nil,
            joinApprovalRequired:
              if(room_type == "channel", do: room.join_approval_required || false, else: nil),
            restrictSavingContent:
              if(room_type == "channel", do: room.restrict_saving_content || false, else: nil),
            role: my_settings.role,
            friendId: if(friend_p, do: friend_p.user_id, else: nil),
            friendName:
              present_chat_friend_name(
                if(friend_p, do: friend_p.user, else: nil),
                friend_agent
              ),
            friendIsAgent: !!friend_agent,
            friendAgentId: if(friend_agent, do: friend_agent.agent_id, else: nil),
            friendAgentEventInboxMode:
              if(friend_agent, do: friend_agent_event_inbox_mode(friend_agent), else: nil),
            friendAgentSummaryWindowHours:
              if(friend_agent, do: friend_agent_event_inbox_window_hours(friend_agent), else: nil),
            acceptsIncomingChat:
              if(friend_agent, do: friend_agent_accepts_incoming_chat(friend_agent), else: nil),
            friendImage:
              present_chat_friend_image(
                if(friend_p, do: friend_p.user, else: nil),
                friend_agent
              ),
            friendTier:
              present_chat_friend_tier(
                if(friend_p, do: friend_p.user, else: nil),
                friend_agent
              ),
            members: members,
            messages: messages_for_client,
            unreadCount: 0,
            archived: my_settings.archived,
            pinned: my_settings.pinned,
            muted: my_settings.muted
          }
        end)
      end)

    case result do
      chats when is_list(chats) ->
        chats

      {:error, reason} ->
        Logger.error("[Chat] list_chats failed user_id=#{user_id}: #{inspect(reason)}")
        []

      other ->
        Logger.error("[Chat] list_chats unexpected result user_id=#{user_id}: #{inspect(other)}")
        []
    end
  end

  defp present_chat_friend_name(user, agent_payload) do
    present_string(agent_payload && agent_payload.display_name) ||
      present_string(user && user.name) ||
      present_string(user && user.username)
  end

  defp present_chat_friend_image(user, agent_payload) do
    present_string(agent_payload && agent_payload.avatar_url) ||
      present_string(user && user.profile_image)
  end

  defp present_chat_friend_tier(user, agent_payload) do
    if agent_payload do
      present_string(user && user.tier) || "gold"
    else
      present_string(user && user.tier)
    end
  end

  defp present_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present_string(_), do: nil

  def find_chat_between_users(u1, u2) do
    query =
      from(r in Room,
        join: p1 in Participant,
        on: p1.chat_id == r.id,
        join: p2 in Participant,
        on: p2.chat_id == r.id,
        where: r.type == "dm" and p1.user_id == ^u1 and p2.user_id == ^u2,
        select: r.id,
        limit: 1
      )

    Repo.one(query)
  end

  def ensure_dm_chat(user_id, peer_user_id) when is_binary(user_id) and is_binary(peer_user_id) do
    case find_chat_between_users(user_id, peer_user_id) do
      chat_id when is_binary(chat_id) ->
        status =
          case restore_if_deleted(chat_id, user_id) do
            :restored -> "restored"
            _ -> "existing"
          end

        {:ok, chat_id, status}

      nil ->
        chat_id = deterministic_dm_chat_id(user_id, peer_user_id)

        try do
          case create_chat(chat_id, [user_id, peer_user_id]) do
            {:ok, _room} ->
              {:ok, chat_id, "created"}

            {:error, reason} ->
              {:error, reason}

            other ->
              {:error, other}
          end
        rescue
          Ecto.ConstraintError ->
            status =
              case restore_if_deleted(chat_id, user_id) do
                :restored -> "restored"
                _ -> "existing"
              end

            {:ok, chat_id, status}
        end
    end
  end

  def get_chat(id) do
    Repo.get(Room, id) |> Repo.preload(:participants)
  end

  def create_chat(id, user_ids) do
    result =
      Repo.transaction(fn ->
        room = Repo.insert!(%Room{id: id, is_group: length(user_ids) > 2})

        Enum.each(user_ids, fn uid ->
          Repo.insert!(%Participant{chat_id: id, user_id: uid})
        end)

        room
      end)

    case result do
      {:ok, room} ->
        Enum.each(user_ids, &Vibe.Cache.invalidate(participant_cache_key(id, &1)))
        ChatHomeCache.invalidate_users(user_ids)
        {:ok, room}

      other ->
        other
    end
  end

  defp deterministic_dm_chat_id(u1, u2) do
    :crypto.hash(:sha256, Enum.sort([u1, u2]) |> Enum.join("|"))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  def add_message(attrs, opts \\ []) do
    acting_user_id =
      normalize_actor_id(Keyword.get(opts, :acting_user_id) || extract_from_id(attrs))

    from_id = normalize_actor_id(extract_from_id(attrs))
    chat_id = extract_chat_id(attrs)

    cond do
      is_binary(acting_user_id) and is_binary(from_id) and acting_user_id != from_id and
          not legitimate_agent_sender?(chat_id, from_id) ->
        {:error, :forbidden_sender}

      forward_restricted?(attrs, acting_user_id) ->
        {:error, :forward_restricted}

      true ->
        result =
          RepoRLS.with_user(acting_user_id || from_id, fn ->
            %Message{}
            |> Message.changeset(attrs)
            |> Repo.insert(on_conflict: :nothing, conflict_target: :id)
          end)

        case result do
          {:ok, %Message{} = message} ->
            invalidate_chat_home_cache(message.chat_id)
            {:ok, message}

          other ->
            other
        end
    end
  end

  defp legitimate_agent_sender?(chat_id, from_id) when is_binary(chat_id) and chat_id != "" do
    if legacy_group_agent_id?(from_id) do
      not is_nil(Vibe.Chat.GroupAgent.get_enabled_by_chat(chat_id))
    else
      agent_user?(from_id) and is_participant?(chat_id, from_id)
    end
  end

  defp legitimate_agent_sender?(_chat_id, _from_id), do: false

  defp agent_user?(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, _} -> match?(%User{is_agent: true}, Repo.get(User, user_id))
      :error -> false
    end
  end

  defp extract_chat_id(attrs) when is_map(attrs) do
    attrs[:chat_id] || attrs["chat_id"] || attrs[:chatId] || attrs["chatId"]
  end

  defp extract_chat_id(_), do: nil

  @doc """
  True when this payload is a forward of another user's message and that user
  has privacy_forward = "nobody" (or "contacts" and the actor is not a contact).
  """
  def forward_restricted?(attrs, acting_user_id \\ nil) when is_map(attrs) do
    meta = attrs["metadata"] || attrs[:metadata] || %{}

    is_forwarded =
      meta["isForwarded"] == true or meta["is_forwarded"] == true or
        present_string(
          meta["forwardedFromUserId"] || meta["forwarded_from_user_id"] ||
            meta["forwardedFromMessageId"] || meta["forwarded_from_message_id"]
        ) != nil

    author_id =
      present_string(
        meta["forwardedFromUserId"] || meta["forwarded_from_user_id"] ||
          meta[:forwardedFromUserId] || meta[:forwarded_from_user_id]
      )

    cond do
      not is_forwarded ->
        false

      is_nil(author_id) ->
        false

      is_binary(acting_user_id) and acting_user_id == author_id ->
        false

      true ->
        case Repo.get(User, author_id) do
          %User{privacy_forward: "nobody"} -> true
          _ -> false
        end
    end
  end

  def forward_restricted?(_, _), do: false

  def get_message(chat_id, message_id, user_id \\ nil) do
    RepoRLS.with_user(user_id, fn ->
      with {:ok, message_uuid} <- Ecto.UUID.cast(message_id) do
        Repo.one(
          from(m in Message,
            where: m.chat_id == ^chat_id and m.id == ^message_uuid
          )
        )
      else
        _ -> nil
      end
    end)
  end

  def get_messages(chat_id, user_id \\ nil) do
    RepoRLS.with_user(user_id, fn ->
      Message
      |> where([m], m.chat_id == ^chat_id)
      |> visible_transcript_messages()
      |> order_by([m], asc: m.timestamp)
      |> Repo.all()
      |> Enum.map(&to_client_message/1)
    end)
  end

  def get_messages_for_user(chat_id, user_id) do
    RepoRLS.with_user(user_id, fn ->
      participant =
        Repo.one(
          from(p in Participant,
            where: p.chat_id == ^chat_id and p.user_id == ^user_id,
            select: p.messages_cleared_at
          )
        )

      query =
        from(m in Message,
          where: m.chat_id == ^chat_id
        )
        |> visible_transcript_messages()

      query =
        if participant do
          cleared_at_ms =
            participant
            |> DateTime.from_naive!("Etc/UTC")
            |> DateTime.to_unix(:millisecond)

          from(m in query, where: m.timestamp > ^cleared_at_ms)
        else
          query
        end

      query
      |> order_by([m], asc: m.timestamp)
      |> Repo.all()
      |> Enum.map(&to_client_message/1)
    end)
  end

  def get_messages_for_user_page(chat_id, user_id, opts \\ []) do
    limit = normalize_history_limit(Keyword.get(opts, :limit))
    before = decode_history_cursor(Keyword.get(opts, :before))

    result =
      RepoRLS.with_user(user_id, fn ->
        participant =
          Repo.one(
            from(p in Participant,
              where: p.chat_id == ^chat_id and p.user_id == ^user_id,
              select: p.messages_cleared_at
            )
          )

        query =
          from(m in Message,
            where: m.chat_id == ^chat_id
          )
          |> visible_transcript_messages()

        query =
          if participant do
            cleared_at_ms =
              participant
              |> DateTime.from_naive!("Etc/UTC")
              |> DateTime.to_unix(:millisecond)

            from(m in query, where: m.timestamp > ^cleared_at_ms)
          else
            query
          end

        query =
          case before do
            %{timestamp: timestamp, id: id} ->
              from(m in query,
                where: m.timestamp < ^timestamp or (m.timestamp == ^timestamp and m.id < ^id)
              )

            _ ->
              query
          end

        Repo.all(
          from(m in query,
            order_by: [desc: m.timestamp, desc: m.id],
            limit: ^(limit + 1)
          )
        )
      end)

    case result do
      messages when is_list(messages) ->
        has_more = length(messages) > limit
        page_desc = Enum.take(messages, limit)

        next_cursor =
          if has_more do
            page_desc
            |> List.last()
            |> encode_history_cursor()
          else
            nil
          end

        %{
          messages:
            page_desc
            |> Enum.reverse()
            |> Enum.map(&to_client_message/1)
            |> decorate_engagement(chat_id, user_id),
          next_cursor: next_cursor,
          has_more: has_more
        }

      {:error, reason} ->
        Logger.error(
          "[Chat] get_messages_for_user_page failed chat_id=#{chat_id} user_id=#{user_id}: #{inspect(reason)}"
        )

        %{messages: [], next_cursor: nil, has_more: false}

      other ->
        Logger.error(
          "[Chat] get_messages_for_user_page unexpected result chat_id=#{chat_id} user_id=#{user_id}: #{inspect(other)}"
        )

        %{messages: [], next_cursor: nil, has_more: false}
    end
  end

  def mark_read(message_id, reader_id) do
    result =
      RepoRLS.with_user(reader_id, fn ->
        case from(m in Message, where: m.id == ^message_id)
             |> Repo.update_all(set: [status: "read"]) do
          {0, _} ->
            {:ok, :message_missing}

          {_count, _} ->
            %MessageRead{}
            |> MessageRead.changeset(%{message_id: message_id, reader_id: reader_id})
            |> Repo.insert(on_conflict: :nothing)
        end
      end)

    invalidate_home_cache_for_message(message_id)
    result
  end

  def mark_delivered(message_id, user_id \\ nil) do
    result =
      RepoRLS.with_user(user_id, fn ->
        from(m in Message, where: m.id == ^message_id and m.status == "sent")
        |> Repo.update_all(set: [status: "delivered"])
      end)

    invalidate_home_cache_for_message(message_id)
    result
  end

  def can_delete_message_for_everyone?(chat_id, user_id, from_id) do
    from_id == user_id ||
      case Repo.get(Room, chat_id) do
        %Room{} = room ->
          direct_room?(room) ||
            Repo.exists?(
              from(p in Participant,
                where:
                  p.chat_id == ^chat_id and
                    p.user_id == ^user_id and
                    p.role in ["owner", "admin"]
              )
            )

        nil ->
          false
      end
  end

  def consume_view_once_media(chat_id, message_id, user_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(message_id),
         true <- is_participant?(chat_id, user_id),
         %Message{} = message <-
           RepoRLS.with_user(user_id, fn ->
             Repo.one(from(m in Message, where: m.id == ^uuid and m.chat_id == ^chat_id))
           end) do
      meta = message.metadata || %{}
      ttl = media_ttl_seconds(meta)

      cond do
        meta["mediaExpired"] == true or meta["media_expired"] == true ->
          {:ok, :viewed}

        not view_once_media?(meta) and is_nil(ttl) ->
          {:error, :not_view_once}

        ttl in [nil, 0] ->
          expire_view_once_and_broadcast(message, user_id, "viewed")

        is_integer(ttl) and ttl > 0 ->
          schedule_view_once_expiry(message, user_id, ttl)

        true ->
          {:error, :not_view_once}
      end
    else
      false -> {:error, :forbidden}
      :error -> {:error, :invalid_id}
      nil -> {:error, :not_found}
      other -> other
    end
  end

  defp view_once_media?(meta) when is_map(meta) do
    meta["viewOnce"] == true or meta["view_once"] == true
  end

  defp view_once_media?(_), do: false

  defp schedule_view_once_expiry(%Message{} = message, user_id, ttl) when is_integer(ttl) and ttl > 0 do
    meta = message.metadata || %{}
    now = System.system_time(:millisecond)
    expires_at =
      case meta["mediaExpiresAt"] || meta["media_expires_at"] do
        n when is_integer(n) -> n
        _ -> now + ttl * 1000
      end

    if expires_at <= now do
      expire_view_once_and_broadcast(message, user_id, "expired")
    else
      unless is_integer(meta["mediaOpenedAt"] || meta["media_opened_at"]) do
        new_meta =
          Map.merge(meta, %{
            "mediaOpenedAt" => now,
            "mediaExpiresAt" => expires_at
          })

        _ =
          RepoRLS.with_user(user_id, fn ->
            message
            |> Message.changeset(%{metadata: new_meta})
            |> Repo.update()
          end)
      end

      remaining = max(expires_at - now, 0)

      Task.start(fn ->
        Process.sleep(remaining)
        _ = expire_view_once_and_broadcast(message, user_id, "expired")
      end)

      {:ok, :scheduled}
    end
  end

  defp expire_view_once_and_broadcast(%Message{} = message, user_id, reason) do
    RepoRLS.with_user(user_id, fn ->
      fresh =
        Repo.one(from(m in Message, where: m.id == ^message.id and m.chat_id == ^message.chat_id)) ||
          message

      meta = fresh.metadata || %{}

      if meta["mediaExpired"] == true or meta["media_expired"] == true do
        {:ok, :viewed}
      else
        tombstone_reason = if reason == "expired", do: "expired", else: "viewed"
        label = view_once_tombstone_label(fresh, tombstone_reason)
        metadata = view_once_tombstone_metadata(fresh, tombstone_reason, label)
        edited_at = System.system_time(:millisecond)

        case fresh
             |> Ecto.Changeset.change(%{
               type: "system",
               media_url: nil,
               encrypted_content: " ",
               metadata: metadata,
               edited_at: edited_at
             })
             |> Repo.update() do
          {:ok, updated} ->
            broadcast_view_once_tombstone(updated, user_id)
            {:ok, if(tombstone_reason == "expired", do: :expired, else: :viewed)}

          other ->
            other
        end
      end
    end)
  end

  defp view_once_tombstone_label(%Message{} = message, reason) do
    noun =
      case message.type do
        "video" -> "Video"
        _ -> "Photo"
      end

    if reason == "expired", do: "#{noun} expired", else: "#{noun} viewed"
  end

  defp view_once_tombstone_metadata(%Message{} = message, reason, label) do
    dropped = [
      "mediaUrl",
      "media_url",
      "localMediaUrl",
      "local_media_url",
      "mediaKey",
      "media_key",
      "thumbnailBase64",
      "thumbnail_base64",
      "attachmentThumbnailsB64",
      "attachmentUrls",
      "attachmentMediaKeys",
      "width",
      "height",
      "duration",
      "fileName",
      "file_name",
      "mimeType",
      "mime_type",
      "waveform",
      "isVideoNote"
    ]

    (message.metadata || %{})
    |> Map.drop(dropped)
    |> Map.merge(%{
      "mediaExpired" => true,
      "mediaExpiryReason" => reason,
      "text" => label,
      "service" => %{
        "kind" => "view_once_expired",
        "status" => "expired",
        "text" => label
      }
    })
  end

  defp broadcast_view_once_tombstone(%Message{} = updated, actor_id) do
    metadata = updated.metadata || %{}
    client = client_message_payload(updated) |> mirrored_message_payload()

    payload = %{
      chatId: updated.chat_id,
      messageId: updated.id,
      encryptedContent: "",
      editedAt: updated.edited_at,
      editedBy: actor_id,
      plainContent: metadata["text"],
      plaintext: metadata["text"],
      metadata: metadata,
      type: updated.type,
      message: client
    }

    VibeWeb.Endpoint.broadcast!("chat:#{updated.chat_id}", "message-edited", payload)
    broadcast_user_chat_event(updated.chat_id, "message-edited", payload)
    :ok
  end

  defp persist_expired_timed_media(%Message{} = message) do
    meta = message.metadata || %{}

    cond do
      meta["mediaExpired"] == true or meta["media_expired"] == true ->
        message

      timed_media_deadline_passed?(meta) ->
        case expire_view_once_and_broadcast(message, message.from_id, "expired") do
          {:ok, _} -> Repo.get(Message, message.id) || in_memory_view_once_tombstone(message)
          _ -> in_memory_view_once_tombstone(message)
        end

      true ->
        message
    end
  end

  defp persist_expired_timed_media(other), do: other

  defp timed_media_deadline_passed?(meta) when is_map(meta) do
    case meta["mediaExpiresAt"] || meta["media_expires_at"] do
      n when is_integer(n) -> n <= System.system_time(:millisecond)
      _ -> false
    end
  end

  defp timed_media_deadline_passed?(_), do: false

  defp in_memory_view_once_tombstone(%Message{} = message) do
    label = view_once_tombstone_label(message, "expired")
    %{
      message
      | type: "system",
        media_url: nil,
        encrypted_content: " ",
        metadata: view_once_tombstone_metadata(message, "expired", label)
    }
  end

  defp media_ttl_seconds(meta) when is_map(meta) do
    value = meta["mediaTtlSeconds"] || meta["media_ttl_seconds"]

    cond do
      is_integer(value) and value >= 0 -> value
      is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n >= 0 -> n
          _ -> nil
        end
      true -> nil
    end
  end

  def delete_message(chat_id, message_id, user_id, for_everyone \\ true) do
    result =
      RepoRLS.with_user(user_id, fn ->
        if not is_participant?(chat_id, user_id) do
          {:error, :forbidden}
        else
          case Ecto.UUID.cast(message_id) do
            :error ->
              {:error, :invalid_id}

            {:ok, uuid} ->
              case Repo.one(from(m in Message, where: m.id == ^uuid and m.chat_id == ^chat_id)) do
                nil ->
                  {:error, :not_found}

                %Message{} = message ->
                  if for_everyone &&
                       not can_delete_message_for_everyone?(chat_id, user_id, message.from_id) do
                    {:error, :forbidden}
                  else
                    Repo.transaction(fn ->
                      from(r in MessageRead, where: r.message_id == ^uuid) |> Repo.delete_all()

                      from(pm in PinnedMessage, where: pm.message_id == ^uuid)
                      |> Repo.delete_all()

                      Repo.delete!(message)
                    end)

                    {:ok, message}
                  end
              end
          end
        end
      end)

    case result do
      {:ok, %Message{} = message} ->
        invalidate_chat_home_cache(chat_id)
        {:ok, message}

      other ->
        other
    end
  end

  def edit_message(chat_id, message_id, user_id, encrypted_content, edited_at \\ nil) do
    result =
      RepoRLS.with_user(user_id, fn ->
        if not is_participant?(chat_id, user_id) do
          {:error, :forbidden}
        else
          case Ecto.UUID.cast(message_id) do
            :error ->
              {:error, :invalid_id}

            {:ok, uuid} ->
              case Repo.one(from(m in Message, where: m.id == ^uuid and m.chat_id == ^chat_id)) do
                nil ->
                  {:error, :not_found}

                %Message{} = message ->
                  if message.from_id != user_id do
                    {:error, :forbidden}
                  else
                    next_edited_at =
                      if is_integer(edited_at) and edited_at > 0,
                        do: edited_at,
                        else: :os.system_time(:millisecond)

                    message
                    |> Ecto.Changeset.change(
                      encrypted_content: encrypted_content,
                      edited_at: next_edited_at
                    )
                    |> Repo.update()
                  end
              end
          end
        end
      end)

    case result do
      {:ok, %Message{} = message} ->
        invalidate_chat_home_cache(chat_id)
        {:ok, message}

      other ->
        other
    end
  end


  @engagement_batch_limit 200
  @reaction_detail_limit 500
  @no_user_uuid "00000000-0000-0000-0000-000000000000"

  @doc "Toggles the same reaction off or replaces it, then returns fresh counts."
  def toggle_reaction(chat_id, message_id, user_id, emoji) do
    result =
      with {:ok, normalized} <- normalize_emoji(emoji),
           {:ok, uuid} <- cast_message_uuid(message_id) do
        RepoRLS.with_user(user_id, fn ->
          with :ok <- ensure_participant(chat_id, user_id),
               {:ok, _message} <- fetch_chat_message(chat_id, uuid),
               :ok <- ensure_reactions_enabled(chat_id) do
            action = apply_reaction(chat_id, uuid, user_id, normalized)

            {:ok,
             %{
               action: action,
               emoji: normalized,
               reactions: message_reactions(uuid, user_id)
             }}
          end
        end)
      end

    case result do
      {:ok, _payload} = success ->
        invalidate_chat_home_cache(chat_id)
        success

      other ->
        other
    end
  end

  @doc "Reaction summary for one message, with the caller's bucket flagged."
  def message_reactions(message_id, user_id \\ nil) do
    [message_id]
    |> message_reaction_summaries(user_id)
    |> Enum.flat_map(fn {_message_id, rows} -> rows end)
  end

  @doc "Batched `%{message_id => [%{emoji, count, isSelected}]}` for a page of messages."
  def message_reaction_summaries(message_ids, user_id \\ nil) do
    case normalize_message_uuids(message_ids) do
      [] ->
        %{}

      ids ->
        caller_id = normalize_actor_id(user_id) || @no_user_uuid

        from(r in MessageReaction,
          where: r.message_id in ^ids,
          group_by: [r.message_id, r.emoji],
          select: %{
            message_id: r.message_id,
            emoji: r.emoji,
            count: count(r.id),
            selected: fragment("bool_or(? = ?)", r.user_id, type(^caller_id, :binary_id))
          }
        )
        |> Repo.all()
        |> Enum.group_by(& &1.message_id)
        |> Map.new(fn {message_id, rows} ->
          {message_id,
           rows
           |> Enum.sort_by(&{-&1.count, &1.emoji})
           |> Enum.map(&%{emoji: &1.emoji, count: &1.count, isSelected: &1.selected == true})}
        end)
    end
  end

  @doc "Emoji-grouped actors for one message; the caller must be a participant."
  def message_reaction_detail(chat_id, message_id, user_id) do
    with {:ok, uuid} <- cast_message_uuid(message_id) do
      RepoRLS.with_user(user_id, fn ->
        with :ok <- ensure_participant(chat_id, user_id),
             {:ok, _message} <- fetch_chat_message(chat_id, uuid) do
          {:ok, reaction_detail_groups(uuid, user_id)}
        end
      end)
    end
  end

  @doc "Batched `%{message_id => view_count}`; messages with no views are absent."
  def message_view_counts(message_ids) do
    case normalize_message_uuids(message_ids) do
      [] ->
        %{}

      ids ->
        from(v in MessageView,
          where: v.message_id in ^ids,
          group_by: v.message_id,
          select: {v.message_id, count(v.id)}
        )
        |> Repo.all()
        |> Map.new()
    end
  end

  @doc "Records idempotent group/channel views, excluding the caller's own messages."
  def mark_messages_viewed(chat_id, user_id, message_ids) do
    ids = normalize_message_uuids(message_ids)

    cond do
      ids == [] ->
        {:error, :invalid_id}

      not is_participant?(chat_id, user_id) ->
        {:error, :forbidden}

      get_room_type(chat_id) not in ["group", "channel"] ->
        {:error, :unsupported_chat}

      true ->
        RepoRLS.with_user(user_id, fn -> insert_message_views(chat_id, user_id, ids) end)
    end
  end

  @doc "Files a moderation report without reading or copying message plaintext."
  def report_message(chat_id, message_id, reporter_id, attrs) when is_map(attrs) do
    with {:ok, uuid} <- cast_message_uuid(message_id),
         {:ok, reason} <- normalize_report_reason(attrs),
         {:ok, details} <- normalize_report_details(attrs) do
      block_sender =
        report_flag(attrs["blockSender"] || attrs["block_sender"] || attrs[:blockSender])

      RepoRLS.with_user(reporter_id, fn ->
        with :ok <- ensure_participant(chat_id, reporter_id),
             {:ok, message} <- fetch_chat_message(chat_id, uuid),
             :ok <- ensure_report_target(message, reporter_id) do
          insert_message_report(chat_id, message, reporter_id, reason, details, block_sender)
        end
      end)
    end
  end

  @doc "Report reasons accepted by `report_message/4`."
  def report_reasons, do: MessageReport.reasons()

  defp insert_message_views(chat_id, user_id, ids) do
    eligible =
      Repo.all(
        from(m in Message,
          where: m.id in ^ids and m.chat_id == ^chat_id and m.from_id != ^user_id,
          select: m.id
        )
      )

    if eligible == [] do
      {:ok, []}
    else
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      entries =
        Enum.map(eligible, fn message_id ->
          %{
            id: Ecto.UUID.generate(),
            message_id: message_id,
            chat_id: chat_id,
            user_id: user_id,
            inserted_at: now
          }
        end)

      Repo.insert_all(MessageView, entries,
        on_conflict: :nothing,
        conflict_target: [:message_id, :user_id]
      )

      counts = message_view_counts(eligible)
      {:ok, Enum.map(eligible, &%{messageId: &1, viewCount: Map.get(counts, &1, 0)})}
    end
  end

  defp insert_message_report(chat_id, %Message{} = message, reporter_id, reason, details, block?) do
    attrs = %{
      message_id: message.id,
      source_message_id: message.id,
      chat_id: chat_id,
      reporter_id: reporter_id,
      reported_user_id: message.from_id,
      reason: reason,
      details: details,
      status: "pending"
    }

    case %MessageReport{} |> MessageReport.changeset(attrs) |> Repo.insert() do
      {:ok, report} ->
        if block?, do: ensure_user_block(reporter_id, message.from_id)
        {:ok, %{report: report, blocked: Accounts.blocked?(reporter_id, message.from_id)}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp ensure_user_block(user_id, blocked_user_id) do
    %UserBlock{}
    |> UserBlock.changeset(%{user_id: user_id, blocked_user_id: blocked_user_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :blocked_user_id])
  end

  defp reaction_detail_groups(message_uuid, user_id) do
    actors =
      Repo.all(
        from(r in MessageReaction,
          join: u in User,
          on: u.id == r.user_id,
          where: r.message_id == ^message_uuid,
          order_by: [desc: r.updated_at, asc: r.user_id],
          limit: @reaction_detail_limit,
          select: %{
            emoji: r.emoji,
            user_id: r.user_id,
            name: u.name,
            username: u.username,
            avatar_url: u.profile_image,
            reacted_at: r.updated_at
          }
        )
      )
      |> Enum.group_by(& &1.emoji)

    message_uuid
    |> message_reactions(user_id)
    |> Enum.map(fn summary ->
      users =
        actors
        |> Map.get(summary.emoji, [])
        |> Enum.map(&reaction_actor_payload/1)

      Map.put(summary, :users, users)
    end)
  end

  defp reaction_actor_payload(actor) do
    %{
      userId: actor.user_id,
      name: present_string(actor.name) || present_string(actor.username),
      username: actor.username,
      avatarUrl: present_string(actor.avatar_url),
      reactedAt: naive_to_epoch_ms(actor.reacted_at)
    }
  end

  defp naive_to_epoch_ms(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp naive_to_epoch_ms(_at), do: nil

  defp apply_reaction(chat_id, message_uuid, user_id, emoji) do
    existing =
      Repo.one(
        from(r in MessageReaction,
          where: r.message_id == ^message_uuid and r.user_id == ^user_id
        )
      )

    cond do
      is_nil(existing) ->
        %MessageReaction{}
        |> MessageReaction.changeset(%{
          message_id: message_uuid,
          chat_id: chat_id,
          user_id: user_id,
          emoji: emoji
        })
        |> Repo.insert!(
          on_conflict: {:replace, [:emoji, :updated_at]},
          conflict_target: [:message_id, :user_id]
        )

        :added

      existing.emoji == emoji ->
        from(r in MessageReaction, where: r.id == ^existing.id) |> Repo.delete_all()
        :removed

      true ->
        from(r in MessageReaction, where: r.id == ^existing.id)
        |> Repo.update_all(
          set: [
            emoji: emoji,
            updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
          ]
        )

        :replaced
    end
  end

  defp ensure_participant(chat_id, user_id) do
    if is_participant?(chat_id, user_id), do: :ok, else: {:error, :forbidden}
  end

  defp fetch_chat_message(chat_id, message_uuid) do
    case Repo.one(from(m in Message, where: m.id == ^message_uuid and m.chat_id == ^chat_id)) do
      %Message{} = message -> {:ok, message}
      _ -> {:error, :not_found}
    end
  end

  defp ensure_reactions_enabled(chat_id) do
    case Repo.get(Room, chat_id) do
      %Room{} = room ->
        if channel_settings(room)["reactionsEnabled"] == false,
          do: {:error, :reactions_disabled},
          else: :ok

      _ ->
        {:error, :not_found}
    end
  end

  defp ensure_report_target(%Message{from_id: from_id}, reporter_id)
       when is_binary(from_id) and from_id != "" do
    if from_id == reporter_id, do: {:error, :invalid_target}, else: :ok
  end

  defp ensure_report_target(_message, _reporter_id), do: {:error, :invalid_target}

  defp normalize_emoji(emoji) when is_binary(emoji) do
    trimmed = String.trim(emoji)

    cond do
      trimmed == "" -> {:error, :invalid_emoji}
      byte_size(trimmed) > 64 -> {:error, :invalid_emoji}
      String.match?(trimmed, ~r/[[:space:][:cntrl:]]/u) -> {:error, :invalid_emoji}
      true -> {:ok, trimmed}
    end
  end

  defp normalize_emoji(_emoji), do: {:error, :invalid_emoji}

  defp cast_message_uuid(message_id) when is_binary(message_id) do
    case Ecto.UUID.cast(message_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_id}
    end
  end

  defp cast_message_uuid(_message_id), do: {:error, :invalid_id}

  defp normalize_message_uuids(message_ids) do
    message_ids
    |> List.wrap()
    |> Enum.flat_map(fn id ->
      case cast_message_uuid(id) do
        {:ok, uuid} -> [uuid]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(@engagement_batch_limit)
  end

  defp normalize_report_reason(attrs) do
    raw = attrs["reason"] || attrs[:reason]

    normalized =
      raw |> to_string() |> String.trim() |> String.downcase() |> String.replace("-", "_")

    if normalized in MessageReport.reasons(),
      do: {:ok, normalized},
      else: {:error, :invalid_reason}
  end

  defp normalize_report_details(attrs) do
    case attrs["details"] || attrs[:details] do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.trim(value) do
          "" ->
            {:ok, nil}

          trimmed ->
            if String.length(trimmed) > MessageReport.details_limit(),
              do: {:error, :details_too_long},
              else: {:ok, trimmed}
        end

      _ ->
        {:error, :invalid_details}
    end
  end

  defp report_flag(value), do: value in [true, "true", "1", 1, "yes"]

  def list_pinned_messages(chat_id, user_id) do
    RepoRLS.with_user(user_id, fn ->
      Repo.all(
        from(pm in PinnedMessage,
          join: m in Message,
          on: pm.message_id == m.id,
          where: pm.chat_id == ^chat_id and pm.user_id == ^user_id,
          order_by: [desc: pm.inserted_at],
          select: %{
            messageId: pm.message_id,
            chatId: pm.chat_id,
            pinnedAt: pm.inserted_at,
            timestamp: m.timestamp
          }
        )
      )
    end)
  end

  def list_pinned_messages_for_user(chat_id, user_id) do
    RepoRLS.with_user(user_id, fn ->
      rows =
        Repo.all(
          from(p in Participant,
            left_join: pm in PinnedMessage,
            on: pm.chat_id == p.chat_id and pm.user_id == p.user_id,
            left_join: m in Message,
            on: pm.message_id == m.id,
            where: p.chat_id == ^chat_id and p.user_id == ^user_id,
            order_by: [desc: pm.inserted_at],
            select: %{
              messageId: pm.message_id,
              chatId: pm.chat_id,
              pinnedAt: pm.inserted_at,
              timestamp: m.timestamp
            }
          )
        )

      case rows do
        [] -> {:error, :forbidden}
        rows -> {:ok, Enum.reject(rows, &(is_nil(&1.messageId) or is_nil(&1.timestamp)))}
      end
    end)
  end

  def set_message_pin(chat_id, message_id, user_id, pinned \\ true) do
    result =
      RepoRLS.with_user(user_id, fn ->
        if not is_participant?(chat_id, user_id) do
          {:error, :forbidden}
        else
          case Ecto.UUID.cast(message_id) do
            :error ->
              {:error, :invalid_id}

            {:ok, uuid} ->
              if pinned do
                case Repo.one(from(m in Message, where: m.id == ^uuid and m.chat_id == ^chat_id)) do
                  nil ->
                    {:error, :not_found}

                  _message ->
                    changeset =
                      %PinnedMessage{}
                      |> PinnedMessage.changeset(%{
                        user_id: user_id,
                        chat_id: chat_id,
                        message_id: uuid
                      })

                    case Repo.insert(changeset,
                           on_conflict: :nothing,
                           conflict_target: [:user_id, :chat_id, :message_id]
                         ) do
                      {:ok, pin} ->
                        {:ok, pin}

                      {:error, changeset} ->
                        {:error, changeset}
                    end
                end
              else
                from(pm in PinnedMessage,
                  where:
                    pm.user_id == ^user_id and pm.chat_id == ^chat_id and pm.message_id == ^uuid
                )
                |> Repo.delete_all()

                {:ok, :unpinned}
              end
          end
        end
      end)

    case result do
      {:ok, value} ->
        ChatHomeCache.invalidate_user(user_id)
        {:ok, value}

      other ->
        other
    end
  end

  @doc """
  If users have pinned an older agent-generated file message in this chat,
  move their pin to the newest agent file message.
  """
  def refresh_pinned_agent_file(chat_id, new_message_id) do
    with {:ok, new_uuid} <- Ecto.UUID.cast(new_message_id) do
      Repo.transaction(fn ->
        pinned_user_ids =
          Repo.all(
            from(pm in PinnedMessage,
              join: m in Message,
              on: m.id == pm.message_id,
              where:
                pm.chat_id == ^chat_id and
                  m.chat_id == ^chat_id and
                  m.from_id == ^@agent_user_id and
                  m.type == "file",
              select: pm.user_id,
              distinct: true
            )
          )

        if pinned_user_ids == [] do
          0
        else
          from(pm in PinnedMessage,
            join: m in Message,
            on: m.id == pm.message_id,
            where:
              pm.chat_id == ^chat_id and
                m.chat_id == ^chat_id and
                m.from_id == ^@agent_user_id and
                m.type == "file"
          )
          |> Repo.delete_all()

          Enum.each(pinned_user_ids, fn pinned_user_id ->
            %PinnedMessage{}
            |> PinnedMessage.changeset(%{
              user_id: pinned_user_id,
              chat_id: chat_id,
              message_id: new_uuid
            })
            |> Repo.insert(
              on_conflict: :nothing,
              conflict_target: [:user_id, :chat_id, :message_id]
            )
          end)

          length(pinned_user_ids)
        end
      end)
      |> case do
        {:ok, updated_count} -> {:ok, updated_count}
        {:error, reason} -> {:error, reason}
      end
    else
      :error ->
        {:error, :invalid_message_id}
    end
  end

  def set_muted(chat_id, user_id, muted) do
    result =
      from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
      |> Repo.update_all(set: [muted: muted])

    ChatHomeCache.invalidate_user(user_id)
    result
  end

  def set_pinned(chat_id, user_id, pinned) do
    result =
      from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
      |> Repo.update_all(set: [pinned: pinned])

    ChatHomeCache.invalidate_user(user_id)
    result
  end

  def set_marked_unread(chat_id, user_id, marked) do
    result =
      from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
      |> Repo.update_all(set: [marked_unread: marked])

    ChatHomeCache.invalidate_user(user_id)
    result
  end

  def set_archived(chat_id, user_id, archived) do
    result =
      from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
      |> Repo.update_all(set: [archived: archived])

    ChatHomeCache.invalidate_user(user_id)
    result
  end

  @doc """
  Hide this user's message history for a chat, keeping the chat itself.
  """
  def clear_messages(chat_id, user_id) when is_binary(chat_id) and is_binary(user_id) do
    if is_participant?(chat_id, user_id) do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      query =
        from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)

      case Repo.update_all(query, set: [messages_cleared_at: now]) do
        {count, _} when count > 0 ->
          Vibe.Cache.invalidate(participant_cache_key(chat_id, user_id))
          ChatHomeCache.invalidate_users([user_id])
          {:ok, %{cleared_at: now}}

        _ ->
          {:error, "Chat not found"}
      end
    else
      {:error, "Chat not found"}
    end
  end

  def clear_messages(_chat_id, _user_id), do: {:error, "Chat not found"}

  def delete_chat(chat_id, user_id, opts \\ []) do
    delete_for_everyone = Keyword.get(opts, :delete_for_everyone, false)

    unless is_participant?(chat_id, user_id) do
      {:error, "Chat not found"}
    else
      room = Repo.get(Room, chat_id)

      cond do
        delete_for_everyone and not direct_room?(room) ->
          {:error, "Delete for both sides is only available in direct chats"}

        true ->
          now = NaiveDateTime.utc_now()

          target_user_ids =
            if delete_for_everyone, do: get_participant_ids(chat_id), else: [user_id]

          target_query =
            if delete_for_everyone do
              from(p in Participant, where: p.chat_id == ^chat_id)
            else
              from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
            end

          case Repo.update_all(target_query,
                 set: [deleted: true, archived: false, messages_cleared_at: now]
               ) do
            {count, _} when count > 0 ->
              Enum.each(
                target_user_ids,
                &Vibe.Cache.invalidate(participant_cache_key(chat_id, &1))
              )

              ChatHomeCache.invalidate_users(target_user_ids)

              {:ok,
               %{
                 deleted_count: count,
                 for_everyone: delete_for_everyone,
                 target_user_ids: target_user_ids
               }}

            {0, _} ->
              {:error, "Chat not found"}

            _ ->
              {:error, "Failed to delete"}
          end
      end
    end
  end

  defp direct_room?(%Room{type: type, is_group: is_group}) do
    (is_nil(type) or type == "dm") and is_group != true
  end

  defp direct_room?(_), do: false

  def restore_if_deleted(chat_id, user_id) do
    participant =
      Repo.one(
        from(p in Participant,
          where: p.chat_id == ^chat_id and p.user_id == ^user_id
        )
      )

    cond do
      is_nil(participant) ->
        :not_deleted

      participant.deleted == true ->
        from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
        |> Repo.update_all(set: [deleted: false, archived: false])

        Vibe.Cache.invalidate(participant_cache_key(chat_id, user_id))
        ChatHomeCache.invalidate_user(user_id)
        :restored

      true ->
        :not_deleted
    end
  end


  def create_group(creator_id, name, member_ids, avatar_url \\ nil, description \\ nil) do
    id = Ecto.UUID.generate() |> String.slice(0, 12)
    all_member_ids = Enum.uniq([creator_id | member_ids])

    result =
      Repo.transaction(fn ->
        room =
          Repo.insert!(%Room{
            id: id,
            is_group: true,
            type: "group",
            name: name,
            description: present_string(description),
            avatar_url: avatar_url,
            creator_id: creator_id
          })

        Enum.each(all_member_ids, fn uid ->
          role = if uid == creator_id, do: "owner", else: "member"
          Repo.insert!(%Participant{chat_id: id, user_id: uid, role: role})
        end)

        room
      end)

    case result do
      {:ok, room} ->
        ChatHomeCache.invalidate_users(all_member_ids)
        {:ok, room}

      other ->
        other
    end
  end

  def canonical_room_summary(%Room{} = room, opts \\ []) do
    members = channel_member_payloads(room.id)
    member_count = length(members)

    %{
      chatId: room.id,
      type: room.type || if(room.is_group, do: "group", else: "dm"),
      isGroup: room.type in ["group", "channel"] or room.is_group == true,
      isChannel: room.type == "channel",
      name: room.name,
      description: room.description,
      avatarUrl: room.avatar_url,
      creatorId: room.creator_id,
      role: Keyword.get(opts, :role),
      members: members,
      memberCount: member_count,
      subscriberCount:
        if(room.type == "channel",
          do: Enum.count(members, &(&1.role != "agent_admin")),
          else: nil
        ),
      createdAt: room_created_at_ms(room),
      lastMessageAt: room_last_activity_ms(room),
      accessType: if(room.type == "channel", do: room.access_type || "private", else: nil),
      publicSlug: if(room.type == "channel", do: room.public_slug, else: nil),
      shareLink: Keyword.get(opts, :share_link),
      shareUrl: room_share_url(room, Keyword.get(opts, :share_link)),
      joinApprovalRequired:
        if(room.type == "channel", do: room.join_approval_required || false, else: nil),
      restrictSavingContent:
        if(room.type == "channel", do: room.restrict_saving_content || false, else: nil)
    }
  end

  def add_member(chat_id, user_id, role \\ "member", opts \\ []) do
    actor_id = opts[:actor_id]

    result =
      %Participant{}
      |> Participant.changeset(%{chat_id: chat_id, user_id: user_id})
      |> Participant.role_changeset(role)
      |> Repo.insert(on_conflict: :nothing)

    case result do
      {:ok, %Participant{}} ->
        maybe_insert_group_system_notice(
          chat_id,
          actor_id || user_id,
          user_id,
          if(actor_id && actor_id != user_id, do: "member_added", else: "member_joined")
        )

      _ ->
        :ok
    end

    Vibe.Cache.invalidate(participant_cache_key(chat_id, user_id))
    invalidate_chat_home_cache(chat_id)
    ChatHomeCache.invalidate_user(user_id)
    result
  end

  def remove_member(chat_id, user_id, opts \\ []) do
    actor_id = opts[:actor_id]

    result =
      from(p in Participant, where: p.chat_id == ^chat_id and p.user_id == ^user_id)
      |> Repo.delete_all()

    case result do
      {n, _} when is_integer(n) and n > 0 ->
        maybe_insert_group_system_notice(
          chat_id,
          actor_id || user_id,
          user_id,
          if(actor_id && actor_id != user_id, do: "member_removed", else: "member_left")
        )

      _ ->
        :ok
    end

    Vibe.Cache.invalidate(participant_cache_key(chat_id, user_id))
    invalidate_chat_home_cache(chat_id)
    ChatHomeCache.invalidate_user(user_id)
    result
  end


  @doc """
  Owner/admin edit of a group's name / description / avatar. `attrs` may carry any of "name",
  "description", "avatarUrl" (camel or snake case).
  """
  def update_group(chat_id, actor_id, attrs) do
    settings = get_participant_settings(chat_id, actor_id)
    room = Repo.get(Room, chat_id)

    cond do
      is_nil(room) or room.type not in ["group", "channel"] ->
        {:error, :not_found}

      is_nil(settings) or settings.role not in ["owner", "admin"] ->
        {:error, :not_authorized}

      true ->
        changes =
          %{}
          |> put_group_change(:name, attrs["name"] || attrs[:name])
          |> put_group_change(:description, attrs["description"] || attrs[:description])
          |> put_group_change(
            :avatar_url,
            attrs["avatarUrl"] || attrs["avatar_url"] || attrs[:avatar_url]
          )

        case room |> Room.changeset(changes) |> Repo.update() do
          {:ok, updated} ->
            ChatHomeCache.invalidate_users(group_member_ids(chat_id))
            {:ok, updated}

          error ->
            error
        end
    end
  end

  @doc """
  Owner-only promote/demote of a member between "admin" and "member". The room
  owner's role can never be changed.
  """
  def set_member_role(chat_id, actor_id, target_id, role) when role in ["admin", "member"] do
    actor = get_participant_settings(chat_id, actor_id)
    target = get_participant_settings(chat_id, target_id)

    cond do
      is_nil(actor) or actor.role != "owner" ->
        {:error, :not_authorized}

      is_nil(target) ->
        {:error, :not_found}

      target.role == "owner" ->
        {:error, :cannot_change_owner}

      target.role == "agent_admin" ->
        {:error, :invalid_role}

      true ->
        case target |> Participant.role_changeset(role) |> Repo.update() do
          {:ok, updated} ->
            invalidate_chat_home_cache(chat_id)
            ChatHomeCache.invalidate_user(target_id)
            {:ok, updated}

          error ->
            error
        end
    end
  end

  def set_member_role(_chat_id, _actor_id, _target_id, _role), do: {:error, :invalid_role}

  @doc """
  Owner-only hard delete of a group. FK cascades (`on_delete: :delete_all`) remove
  participants, messages, pinned/scheduled rows and any group agent.
  """
  def delete_group(chat_id, actor_id) do
    settings = get_participant_settings(chat_id, actor_id)
    room = Repo.get(Room, chat_id)

    cond do
      is_nil(room) or room.type not in ["group", "channel"] ->
        {:error, :not_found}

      is_nil(settings) or settings.role != "owner" ->
        {:error, :not_authorized}

      true ->
        member_ids = group_member_ids(chat_id)

        case Repo.delete(room) do
          {:ok, _} ->
            Vibe.Cache.invalidate({:participant, chat_id})
            ChatHomeCache.invalidate_users(member_ids)
            {:ok, chat_id}

          error ->
            error
        end
    end
  end

  @doc """
  A non-owner member leaves a group. The owner cannot leave (they delete instead).
  """
  def leave_group(chat_id, user_id) do
    case get_participant_settings(chat_id, user_id) do
      %Participant{role: "owner"} ->
        {:error, :owner_cannot_leave}

      %Participant{} = participant ->
        result = Repo.delete(participant)

        case result do
          {:ok, _} ->
            maybe_insert_group_system_notice(chat_id, user_id, user_id, "member_left")

          _ ->
            :ok
        end

        Vibe.Cache.invalidate(participant_cache_key(chat_id, user_id))
        invalidate_chat_home_cache(chat_id)
        ChatHomeCache.invalidate_user(user_id)
        result

      nil ->
        {:error, :not_member}
    end
  end

  defp group_member_ids(chat_id) do
    Repo.all(from(p in Participant, where: p.chat_id == ^chat_id, select: p.user_id))
  end

  defp maybe_insert_group_system_notice(chat_id, actor_id, target_id, action)
       when is_binary(chat_id) and is_binary(actor_id) and is_binary(target_id) and
              is_binary(action) do
    actor_name = display_name_for_user(actor_id)
    target_name = display_name_for_user(target_id)

    body =
      case action do
        "member_added" -> "#{actor_name} added #{target_name}"
        "member_joined" -> "#{target_name} joined the group"
        "member_removed" -> "#{actor_name} removed #{target_name}"
        "member_left" -> "#{target_name} left the group"
        _ -> nil
      end

    if is_binary(body) do
      service = Vibe.AI.AgentDecisions.membership_service_node(action, actor_name, target_name)

      payload =
        Jason.encode!(%{
          "text" => body,
          "systemAction" => action,
          "actorId" => actor_id,
          "targetId" => target_id,
          "actorName" => actor_name,
          "targetName" => target_name,
          "service" => service
        })

      msg_id = Ecto.UUID.generate()
      ts = System.system_time(:millisecond)

      attrs = %{
        id: msg_id,
        chat_id: chat_id,
        from_id: actor_id,
        encrypted_content: payload,
        type: "system",
        timestamp: ts,
        metadata: %{
          "systemAction" => action,
          "actorId" => actor_id,
          "targetId" => target_id,
          "actorName" => actor_name,
          "targetName" => target_name,
          "text" => body,
          "service" => service
        },
        status: "sent"
      }

      case add_message(attrs, acting_user_id: actor_id) do
        {:ok, _} ->
          broadcast_payload = %{
            "id" => msg_id,
            "chatId" => chat_id,
            "fromId" => actor_id,
            "from_id" => actor_id,
            "type" => "system",
            "timestamp" => ts,
            "encryptedContent" => payload,
            "text" => body,
            "metadata" => attrs.metadata,
            "status" => "sent"
          }

          VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message", broadcast_payload)

          mirrored_message = mirrored_message_payload(broadcast_payload)

          Enum.each(group_member_ids(chat_id), fn uid ->
            VibeWeb.Endpoint.broadcast!("user:#{uid}", "new_message", %{
              chat_id: chat_id,
              from_id: actor_id,
              message_id: msg_id,
              timestamp: ts,
              type: "system",
              message: mirrored_message
            })
          end)

          :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_insert_group_system_notice(_, _, _, _), do: :ok

  defp display_name_for_user(user_id) do
    case Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{username: name} when is_binary(name) and name != "" -> name
      _ -> "Someone"
    end
  end

  defp put_group_change(map, _key, nil), do: map

  defp put_group_change(map, key, value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: map, else: Map.put(map, key, trimmed)
  end

  defp put_group_change(map, key, value), do: Map.put(map, key, value)


  def create_channel(creator_id, attrs) when is_map(attrs),
    do: create_channel_from_attrs(creator_id, attrs)

  def create_channel(creator_id, name) when not is_map(name),
    do: create_channel(creator_id, name, nil, nil)

  def create_channel(creator_id, name, description),
    do: create_channel(creator_id, name, description, nil)

  def create_channel(creator_id, name, description, avatar_url) do
    with {:ok, payload} <-
           create_channel(creator_id, %{
             "name" => name,
             "description" => description,
             "avatarUrl" => avatar_url
           }) do
      {:ok, Repo.get!(Room, payload.chatId)}
    end
  end

  defp create_channel_from_attrs(creator_id, attrs) do
    with {:ok, normalized} <- normalize_channel_attrs(attrs),
         {:ok, member_ids} <- validate_human_member_ids(normalized.member_ids, creator_id),
         {:ok, agents} <- owned_channel_agents(creator_id, normalized.agent_admin_ids) do
      participant_ids =
        [creator_id | member_ids ++ Enum.map(agents, & &1.agent_user_id)]
        |> Enum.uniq()

      case Repo.transaction(fn ->
             id = Ecto.UUID.generate() |> String.slice(0, 12)

             room_changeset =
               Room.changeset(%Room{}, %{
                 id: id,
                 is_group: true,
                 type: "channel",
                 name: normalized.name,
                 description: normalized.description,
                 avatar_url: normalized.avatar_url,
                 creator_id: creator_id,
                 access_type: normalized.access_type,
                 public_slug: normalized.public_slug,
                 join_approval_required: normalized.join_approval_required,
                 restrict_saving_content: normalized.restrict_saving_content
               })

             room =
               case Repo.insert(room_changeset) do
                 {:ok, inserted} -> inserted
                 {:error, changeset} -> Repo.rollback(changeset)
               end

             Repo.insert!(%Participant{chat_id: id, user_id: creator_id, role: "owner"})

             Enum.each(member_ids, fn user_id ->
               Repo.insert!(%Participant{chat_id: id, user_id: user_id, role: "subscriber"})
             end)

             Enum.each(agents, fn agent ->
               attach_channel_agent_in_transaction!(room, agent, creator_id, %{})
             end)

             {share_link, _link} =
               if normalized.access_type == "private" do
                 create_invite_link_in_transaction!(room.id, creator_id, %{})
               else
                 {"/r/#{room.public_slug}", nil}
               end

             {room, share_link}
           end) do
        {:ok, {room, share_link}} ->
          ChatHomeCache.invalidate_users(participant_ids)
          {:ok, canonical_room_summary(room, role: "owner", share_link: share_link)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def join_channel(channel_id, user_id) do
    case Repo.get(Room, channel_id) do
      %Room{type: "channel", access_type: "public", join_approval_required: false} = room ->
        with {:ok, _} <- insert_channel_subscriber(room.id, user_id) do
          Vibe.Cache.invalidate(participant_cache_key(room.id, user_id))
          invalidate_chat_home_cache(room.id)
          ChatHomeCache.invalidate_user(user_id)
          {:ok, canonical_room_summary(room, role: "subscriber")}
        end

      %Room{type: "channel"} ->
        {:error, :link_required}

      _ ->
        {:error, :not_a_channel}
    end
  end

  def leave_channel(channel_id, user_id) do
    case Repo.one(
           from(p in Participant,
             where: p.chat_id == ^channel_id and p.user_id == ^user_id
           )
         ) do
      %Participant{role: "owner"} ->
        {:error, "Owner cannot leave channel"}

      %Participant{} = participant ->
        result = Repo.delete(participant)
        Vibe.Cache.invalidate(participant_cache_key(channel_id, user_id))
        invalidate_chat_home_cache(channel_id)
        ChatHomeCache.invalidate_user(user_id)
        result

      nil ->
        {:error, "Not a member"}
    end
  end

  def list_channels do
    Repo.all(
      from(r in Room,
        where: r.type == "channel" and r.access_type == "public",
        order_by: [desc: r.inserted_at],
        preload: [:creator]
      )
    )
    |> Enum.map(fn room ->
      canonical_room_summary(room)
      |> Map.put(:creatorName, if(room.creator, do: room.creator.username, else: nil))
    end)
  end

  @doc """
  Full channel profile for a participant: identity, settings, roster split into
  administrators vs subscribers, and recent actions from durable messages.
  """
  def get_channel_profile(channel_id, user_id) do
    case Repo.get(Room, channel_id) do
      %Room{type: "channel"} = room ->
        role = get_user_role(channel_id, user_id)

        if is_nil(role) do
          {:error, :not_member}
        else
          summary = canonical_room_summary(room, role: role)
          members = summary.members

          {:ok,
           Map.merge(summary, %{
             myRole: role,
             administrators: Enum.filter(members, fn m -> m.role in ["owner", "admin"] end),
             subscribers: Enum.filter(members, fn m -> m.role == "subscriber" end),
             agentAdministrators: Enum.filter(members, fn m -> m.role == "agent_admin" end),
             settings: channel_settings(room),
             recentActions: list_channel_recent_actions(channel_id, 40)
           })}
        end

      %Room{} ->
        {:error, :not_a_channel}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Owner/admin update of channel identity, access policy, or additive legacy settings.
  """
  def update_channel(channel_id, actor_id, attrs) when is_map(attrs) do
    room = Repo.get(Room, channel_id)

    cond do
      is_nil(room) or room.type != "channel" ->
        {:error, :not_found}

      not human_admin?(channel_id, actor_id) ->
        {:error, :not_authorized}

      true ->
        with {:ok, changes} <- channel_update_changes(room, attrs),
             {:ok, updated} <- room |> Room.changeset(changes) |> Repo.update() do
          ChatHomeCache.invalidate_users(group_member_ids(channel_id))
          {:ok, updated}
        end
    end
  end

  def create_channel_invite_link(channel_id, actor_id, attrs \\ %{}) do
    room = Repo.get(Room, channel_id)

    cond do
      is_nil(room) or room.type != "channel" ->
        {:error, :not_found}

      not human_admin?(channel_id, actor_id) ->
        {:error, :not_authorized}

      room.access_type != "private" ->
        {:error, :public_channel}

      true ->
        case Repo.transaction(fn ->
               now = DateTime.utc_now() |> DateTime.truncate(:second)
               updated_at = DateTime.to_naive(now)

               from(link in ChannelInviteLink,
                 where: link.chat_id == ^channel_id and is_nil(link.revoked_at)
               )
               |> Repo.update_all(set: [revoked_at: now, updated_at: updated_at])

               create_invite_link_in_transaction!(channel_id, actor_id, attrs)
             end) do
          {:ok, {share_link, link}} -> {:ok, invite_link_payload(link, share_link)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def rotate_channel_invite_link(channel_id, actor_id),
    do: create_channel_invite_link(channel_id, actor_id, %{})

  def channel_settings(%Room{} = room) do
    raw =
      room.channel_settings
      |> normalize_map()
      |> Map.drop(["inviteLink", "shareLink", "token"])

    defaults = %{
      "channelType" => room.access_type || "private",
      "accessType" => room.access_type || "private",
      "publicSlug" => room.public_slug,
      "joinApprovalRequired" => room.join_approval_required || false,
      "restrictSavingContent" => room.restrict_saving_content || false,
      "discussionsEnabled" => false,
      "reactionsEnabled" => true,
      "allowDirectMessages" => false,
      "autoTranslateEnabled" => false
    }

    Map.merge(defaults, raw)
  end

  def channel_settings(_), do: channel_settings(%Room{channel_settings: %{}})

  @doc """
  Normalized public-slug form of any text (`"Daily News"` -> `"daily-news"`), or `nil` when
  nothing slug-shaped survives.
  """
  def slugify_public_slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> String.slice(0, 48)
    |> case do
      slug -> if valid_public_slug?(slug), do: slug, else: nil
    end
  end

  @doc "True when `slug` is valid and no channel has claimed it yet."
  def public_slug_available?(slug) do
    case slugify_public_slug(slug) do
      nil -> false
      normalized -> not Repo.exists?(from(room in Room, where: room.public_slug == ^normalized))
    end
  end

  def resolve_channel_link(input) when is_binary(input) do
    with {:ok, reference} <- parse_room_link(input),
         {:ok, room, _link} <- resolve_room_reference(reference) do
      {:ok, link_room_summary(room)}
    end
  end

  def resolve_channel_link(_), do: {:error, :invalid_link}

  def join_channel_link(user_id, input) when is_binary(user_id) and is_binary(input) do
    with {:ok, reference} <- parse_room_link(input),
         {:ok, room, link} <- resolve_room_reference(reference) do
      cond do
        is_participant?(room.id, user_id) ->
          {:ok,
           %{
             status: "joined",
             room: canonical_room_summary(room, role: get_user_role(room.id, user_id))
           }}

        room.join_approval_required ->
          with {:ok, request} <- create_channel_join_request(room, user_id, link) do
            {:ok,
             %{
               status: "pending",
               request: join_request_payload(request),
               room: link_room_summary(room)
             }}
          end

        true ->
          join_channel_immediately(room, user_id, link)
      end
    end
  end

  def list_channel_join_requests(channel_id, actor_id) do
    if human_admin?(channel_id, actor_id) do
      requests =
        from(request in ChannelJoinRequest,
          where: request.chat_id == ^channel_id and request.status == "pending",
          preload: [:user],
          order_by: [asc: request.inserted_at]
        )
        |> Repo.all()
        |> Enum.map(&join_request_payload/1)

      {:ok, requests}
    else
      {:error, :not_authorized}
    end
  end

  def decide_channel_join_request(channel_id, request_id, actor_id, decision)
      when decision in ["approve", "reject"] do
    if human_admin?(channel_id, actor_id) do
      case Repo.transaction(fn ->
             request =
               from(request in ChannelJoinRequest,
                 where: request.id == ^request_id and request.chat_id == ^channel_id,
                 lock: "FOR UPDATE"
               )
               |> Repo.one()

             cond do
               is_nil(request) ->
                 Repo.rollback(:not_found)

               request.status != "pending" ->
                 Repo.rollback(:already_decided)

               decision == "reject" ->
                 review_join_request!(request, actor_id, "rejected")

               true ->
                 if request.invite_link_id, do: claim_invite_link!(request.invite_link_id)
                 insert_channel_subscriber!(channel_id, request.user_id)
                 review_join_request!(request, actor_id, "approved")
             end
           end) do
        {:ok, request} ->
          if request.status == "approved" do
            Vibe.Cache.invalidate(participant_cache_key(channel_id, request.user_id))
            invalidate_chat_home_cache(channel_id)
            ChatHomeCache.invalidate_user(request.user_id)
          end

          {:ok, join_request_payload(request)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_authorized}
    end
  end

  def decide_channel_join_request(_, _, _, _), do: {:error, :invalid_decision}

  def list_channel_agents(channel_id, actor_id) do
    if human_admin?(channel_id, actor_id) do
      assignments =
        from(assignment in ChannelAgentAssignment,
          where: assignment.chat_id == ^channel_id,
          preload: [agent: :agent_user],
          order_by: [asc: assignment.inserted_at]
        )
        |> Repo.all()
        |> Enum.map(&channel_agent_payload/1)

      {:ok, assignments}
    else
      {:error, :not_authorized}
    end
  end

  def attach_channel_agent(channel_id, actor_id, agent_id, attrs \\ %{}) do
    room = Repo.get(Room, channel_id)
    agent = if is_binary(agent_id), do: Vibe.Agents.get_agent(agent_id, actor_id)

    cond do
      is_nil(room) or room.type != "channel" ->
        {:error, :not_found}

      not human_admin?(channel_id, actor_id) ->
        {:error, :not_authorized}

      is_nil(agent) or agent.status == "archived" ->
        {:error, :agent_not_owned}

      true ->
        case Repo.transaction(fn ->
               attach_channel_agent_in_transaction!(room, agent, actor_id, attrs)
             end) do
          {:ok, assignment} ->
            Vibe.Cache.invalidate(participant_cache_key(channel_id, agent.agent_user_id))
            invalidate_chat_home_cache(channel_id)
            ChatHomeCache.invalidate_user(agent.agent_user_id)
            {:ok, channel_agent_payload(Repo.preload(assignment, agent: :agent_user))}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def update_channel_agent(channel_id, actor_id, agent_id, attrs) do
    assignment = Repo.get_by(ChannelAgentAssignment, chat_id: channel_id, agent_id: agent_id)
    agent = if is_binary(agent_id), do: Vibe.Agents.get_agent(agent_id, actor_id)

    cond do
      not human_admin?(channel_id, actor_id) ->
        {:error, :not_authorized}

      is_nil(assignment) ->
        {:error, :not_found}

      is_nil(agent) ->
        {:error, :agent_not_owned}

      true ->
        changes = assignment_policy_patch(assignment, attrs)

        with {:ok, updated} <-
               assignment |> ChannelAgentAssignment.changeset(changes) |> Repo.update() do
          {:ok, channel_agent_payload(Repo.preload(updated, agent: :agent_user))}
        end
    end
  end

  def detach_channel_agent(channel_id, actor_id, agent_id) do
    assignment = Repo.get_by(ChannelAgentAssignment, chat_id: channel_id, agent_id: agent_id)

    cond do
      not human_admin?(channel_id, actor_id) ->
        {:error, :not_authorized}

      is_nil(assignment) ->
        {:error, :not_found}

      true ->
        case Repo.transaction(fn ->
               agent = Repo.get!(Agent, agent_id)
               Repo.delete!(assignment)

               from(participant in Participant,
                 where:
                   participant.chat_id == ^channel_id and
                     participant.user_id == ^agent.agent_user_id and
                     participant.role == "agent_admin"
               )
               |> Repo.delete_all()

               if agent.default_destination_chat_id == channel_id do
                 agent |> Agent.changeset(%{default_destination_chat_id: nil}) |> Repo.update!()
               end

               agent.agent_user_id
             end) do
          {:ok, agent_user_id} ->
            Vibe.Cache.invalidate(participant_cache_key(channel_id, agent_user_id))
            invalidate_chat_home_cache(channel_id)
            ChatHomeCache.invalidate_user(agent_user_id)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Returns the room-scoped effective agent policy.
  """
  def channel_agent_policy(channel_id, %Agent{} = agent) do
    assignment =
      Repo.one(
        from(assignment in ChannelAgentAssignment,
          join: participant in Participant,
          on:
            participant.chat_id == assignment.chat_id and
              participant.user_id == ^agent.agent_user_id,
          where:
            assignment.chat_id == ^channel_id and assignment.agent_id == ^agent.id and
              assignment.status == "active" and participant.role == "agent_admin" and
              (is_nil(participant.deleted) or participant.deleted == false)
        )
      )

    case {Repo.get(Room, channel_id), assignment} do
      {%Room{type: "channel"}, %ChannelAgentAssignment{} = scoped} ->
        {:ok,
         %{
           enabled_tools: intersect_policy(agent.enabled_tools, scoped.allowed_tools),
           output_modes: intersect_policy(agent.output_modes, scoped.allowed_output_modes),
           trigger_config: scoped.trigger_config || %{},
           permissions: scoped.permissions || %{}
         }}

      {%Room{type: "channel"}, nil} ->
        {:error, :chat_not_attached}

      {%Room{}, _} ->
        if is_participant?(channel_id, agent.agent_user_id) do
          {:ok,
           %{
             enabled_tools: agent.enabled_tools || [],
             output_modes: agent.output_modes || [],
             trigger_config: %{},
             permissions: %{}
           }}
        else
          {:error, :chat_not_attached}
        end

      _ ->
        {:error, :chat_not_attached}
    end
  end

  @doc """
  Requester-aware agent policy: layers an `admin_mode` flag on top of `channel_agent_policy/2`
  without ever widening what it returns.
  """
  def effective_agent_policy(channel_id, %Agent{} = agent, requester_user_id) do
    with {:ok, base} <- channel_agent_policy(channel_id, agent) do
      {:ok, Map.put(base, :admin_mode, owner_admin_dm?(channel_id, agent, requester_user_id))}
    end
  end

  defp owner_admin_dm?(channel_id, %Agent{} = agent, requester_user_id)
       when is_binary(channel_id) and is_binary(requester_user_id) do
    requester_user_id == agent.owner_user_id and
      match?(%Room{type: "dm"}, Repo.get(Room, channel_id)) and
      owner_and_agent_only_participants?(channel_id, agent)
  end

  defp owner_admin_dm?(_channel_id, _agent, _requester_user_id), do: false

  defp owner_and_agent_only_participants?(channel_id, %Agent{} = agent) do
    participant_ids =
      Repo.all(
        from(p in Participant,
          where: p.chat_id == ^channel_id and (is_nil(p.deleted) or p.deleted == false),
          select: p.user_id
        )
      )
      |> MapSet.new()

    participant_ids == MapSet.new([agent.owner_user_id, agent.agent_user_id])
  end

  def channel_agent_event_enabled?(channel_id, %Agent{} = agent) do
    case Repo.get(Room, channel_id) do
      %Room{type: "channel"} ->
        case channel_agent_policy(channel_id, agent) do
          {:ok, %{trigger_config: config}} -> normalize_map(config)["type"] == "event"
          _ -> false
        end

      %Room{} ->
        true

      nil ->
        false
    end
  end

  @doc "Atomically claims due interval assignments and advances their next run."
  def claim_due_channel_agent_assignments(limit \\ 10) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    limit = limit |> max(1) |> min(50)

    case Repo.transaction(fn ->
           assignments =
             Repo.all(
               from(assignment in ChannelAgentAssignment,
                 where:
                   assignment.status == "active" and
                     not is_nil(assignment.next_trigger_at) and
                     assignment.next_trigger_at <= ^now,
                 order_by: [asc: assignment.next_trigger_at],
                 limit: ^limit,
                 lock: "FOR UPDATE SKIP LOCKED"
               )
             )

           Enum.map(assignments, fn assignment ->
             next_trigger_at = interval_next_trigger_at(assignment.trigger_config, now)

             assignment
             |> ChannelAgentAssignment.changeset(%{
               next_trigger_at: next_trigger_at,
               last_triggered_at: now,
               last_trigger_status: "running",
               last_trigger_error: nil
             })
             |> Repo.update!()
             |> Map.fetch!(:id)
           end)
         end) do
      {:ok, []} ->
        {:ok, []}

      {:ok, ids} ->
        claimed =
          Repo.all(
            from(assignment in ChannelAgentAssignment,
              where: assignment.id in ^ids,
              preload: [agent: :agent_user]
            )
          )

        {:ok, claimed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def complete_channel_agent_trigger(assignment_id, status, error \\ nil)
      when status in ["completed", "failed"] do
    case Repo.get(ChannelAgentAssignment, assignment_id) do
      nil ->
        {:error, :not_found}

      assignment ->
        assignment
        |> ChannelAgentAssignment.changeset(%{
          last_trigger_status: status,
          last_trigger_error: error |> present_string() |> truncate_string(1_000)
        })
        |> Repo.update()
    end
  end

  defp normalize_channel_attrs(attrs) do
    name = attrs |> channel_attr("name") |> present_string()
    settings = normalize_map(channel_attr(attrs, "settings"))

    access_type =
      (channel_attr(attrs, "accessType") || channel_attr(attrs, "access_type") ||
         channel_attr(attrs, "channelType") || settings["accessType"] ||
         settings["channelType"] || "private")
      |> to_string()

    public_slug =
      normalize_public_slug(
        channel_attr(attrs, "publicSlug") || channel_attr(attrs, "public_slug") ||
          settings["publicSlug"]
      )

    cond do
      is_nil(name) ->
        {:error, :invalid_name}

      access_type not in ["private", "public"] ->
        {:error, :invalid_access_type}

      access_type == "public" and is_nil(public_slug) ->
        {:error, :invalid_public_slug}

      access_type == "public" and not valid_public_slug?(public_slug) ->
        {:error, :invalid_public_slug}

      true ->
        {:ok,
         %{
           name: name,
           description: present_string(channel_attr(attrs, "description")),
           avatar_url:
             present_string(channel_attr(attrs, "avatarUrl") || channel_attr(attrs, "avatar_url")),
           access_type: access_type,
           public_slug: if(access_type == "public", do: public_slug),
           join_approval_required:
             truthy?(
               channel_attr(attrs, "joinApprovalRequired") ||
                 channel_attr(attrs, "join_approval_required")
             ),
           restrict_saving_content:
             truthy?(
               channel_attr(attrs, "restrictSavingContent") ||
                 channel_attr(attrs, "restrict_saving_content")
             ),
           member_ids:
             normalize_id_list(
               channel_attr(attrs, "memberIds") || channel_attr(attrs, "member_ids")
             ),
           agent_admin_ids:
             normalize_id_list(
               channel_attr(attrs, "agentAdminIds") || channel_attr(attrs, "agent_admin_ids")
             )
         }}
    end
  end

  defp channel_update_changes(room, attrs) do
    settings = normalize_map(channel_attr(attrs, "settings"))

    requested_access =
      channel_attr(attrs, "accessType") || channel_attr(attrs, "access_type") ||
        channel_attr(attrs, "channelType") || settings["accessType"] || settings["channelType"] ||
        room.access_type || "private"

    access_type = to_string(requested_access)

    requested_slug =
      if Map.has_key?(attrs, "publicSlug") or Map.has_key?(attrs, "public_slug") or
           Map.has_key?(attrs, :publicSlug) or Map.has_key?(attrs, :public_slug) do
        normalize_public_slug(
          channel_attr(attrs, "publicSlug") || channel_attr(attrs, "public_slug")
        )
      else
        normalize_public_slug(settings["publicSlug"]) || room.public_slug
      end

    cond do
      access_type not in ["private", "public"] ->
        {:error, :invalid_access_type}

      access_type == "public" and not valid_public_slug?(requested_slug) ->
        {:error, :invalid_public_slug}

      true ->
        identity =
          %{}
          |> put_present_change(:name, channel_attr(attrs, "name"))
          |> put_nullable_change(:description, attrs, ["description", :description])
          |> put_nullable_change(:avatar_url, attrs, [
            "avatarUrl",
            "avatar_url",
            :avatarUrl,
            :avatar_url
          ])

        policy = %{
          access_type: access_type,
          public_slug: if(access_type == "public", do: requested_slug),
          join_approval_required:
            boolean_or_existing(
              attrs,
              [
                "joinApprovalRequired",
                "join_approval_required",
                :joinApprovalRequired,
                :join_approval_required
              ],
              room.join_approval_required
            ),
          restrict_saving_content:
            boolean_or_existing(
              attrs,
              [
                "restrictSavingContent",
                "restrict_saving_content",
                :restrictSavingContent,
                :restrict_saving_content
              ],
              room.restrict_saving_content
            ),
          channel_settings: legacy_channel_settings_patch(room, attrs)
        }

        {:ok, Map.merge(identity, policy)}
    end
  end

  defp validate_human_member_ids(member_ids, creator_id) do
    ids = member_ids |> Enum.reject(&(&1 == creator_id)) |> Enum.uniq()

    if Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      users =
        if ids == [] do
          []
        else
          Repo.all(from(user in User, where: user.id in ^ids))
        end

      if length(users) == length(ids) and Enum.all?(users, &(&1.is_agent != true)) do
        {:ok, ids}
      else
        {:error, :invalid_member_ids}
      end
    else
      {:error, :invalid_member_ids}
    end
  end

  defp owned_channel_agents(_owner_id, []), do: {:ok, []}

  defp owned_channel_agents(owner_id, agent_ids) do
    ids = Enum.uniq(agent_ids)

    if Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      agents =
        Repo.all(
          from(agent in Agent,
            where:
              agent.id in ^ids and agent.owner_user_id == ^owner_id and
                agent.status != "archived",
            preload: [:agent_user]
          )
        )

      if length(agents) == length(ids), do: {:ok, agents}, else: {:error, :agent_not_owned}
    else
      {:error, :agent_not_owned}
    end
  end

  defp create_invite_link_in_transaction!(channel_id, actor_id, attrs) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    expires_at =
      normalize_expiry(channel_attr(attrs, "expiresAt") || channel_attr(attrs, "expires_at"))

    max_uses =
      normalize_positive_integer(
        channel_attr(attrs, "maxUses") || channel_attr(attrs, "max_uses")
      )

    link =
      %ChannelInviteLink{}
      |> ChannelInviteLink.changeset(%{
        chat_id: channel_id,
        token_digest: token_digest(token),
        token_hint: String.slice(token, -6, 6),
        created_by: actor_id,
        expires_at: expires_at,
        max_uses: max_uses
      })
      |> Repo.insert!()

    {"/j/#{token}", link}
  end

  defp invite_link_payload(link, share_link) do
    %{
      id: link.id,
      chatId: link.chat_id,
      tokenHint: link.token_hint,
      expiresAt: link.expires_at,
      maxUses: link.max_uses,
      useCount: link.use_count,
      revokedAt: link.revoked_at,
      shareLink: share_link,
      shareUrl: Vibe.Links.room_url(share_link)
    }
  end

  defp room_share_url(room, share_link) do
    cond do
      is_binary(share_link) ->
        Vibe.Links.room_url(share_link)

      room.type == "channel" and is_binary(room.public_slug) ->
        Vibe.Links.room_url("/r/#{room.public_slug}")

      true ->
        nil
    end
  end

  defp parse_room_link(input) do
    value = String.trim(input)

    cond do
      value == "" ->
        {:error, :invalid_link}

      String.starts_with?(value, "vibe://") ->
        parse_room_link_uri(URI.parse(value))

      String.contains?(value, "://") ->
        parse_room_link_uri(URI.parse(value))

      String.starts_with?(value, "/r/") ->
        {:ok, {:slug, value |> String.trim_leading("/r/") |> URI.decode()}}

      String.starts_with?(value, "/j/") ->
        {:ok, {:token, value |> String.trim_leading("/j/") |> URI.decode()}}

      true ->
        {:ok, {:raw, value}}
    end
  rescue
    _ -> {:error, :invalid_link}
  end

  defp parse_room_link_uri(%URI{scheme: "vibe", host: "room-link", query: query}) do
    params = URI.decode_query(query || "")

    cond do
      present_string(params["token"]) -> {:ok, {:token, params["token"]}}
      present_string(params["slug"]) -> {:ok, {:slug, params["slug"]}}
      true -> {:error, :invalid_link}
    end
  end

  defp parse_room_link_uri(%URI{path: path}) when is_binary(path), do: parse_room_link(path)
  defp parse_room_link_uri(_), do: {:error, :invalid_link}

  defp resolve_room_reference({:slug, slug}), do: resolve_public_slug(slug)
  defp resolve_room_reference({:token, token}), do: resolve_private_token(token)

  defp resolve_room_reference({:raw, value}) do
    case resolve_public_slug(value) do
      {:ok, _, _} = ok -> ok
      _ -> resolve_private_token(value)
    end
  end

  defp resolve_public_slug(slug) do
    normalized = normalize_public_slug(slug)

    case Repo.one(
           from(room in Room,
             where:
               room.type == "channel" and room.access_type == "public" and
                 room.public_slug == ^normalized
           )
         ) do
      %Room{} = room -> {:ok, room, nil}
      nil -> {:error, :link_not_found}
    end
  end

  defp resolve_private_token(token) do
    link = Repo.get_by(ChannelInviteLink, token_digest: token_digest(token))

    with %ChannelInviteLink{} = link <- link,
         :ok <- validate_invite_link(link),
         %Room{type: "channel", access_type: "private"} = room <- Repo.get(Room, link.chat_id) do
      {:ok, room, link}
    else
      nil -> {:error, :link_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :link_not_found}
    end
  end

  defp validate_invite_link(%ChannelInviteLink{} = link) do
    now = DateTime.utc_now()

    cond do
      not is_nil(link.revoked_at) -> {:error, :link_revoked}
      link.expires_at && DateTime.compare(link.expires_at, now) != :gt -> {:error, :link_expired}
      link.max_uses && link.use_count >= link.max_uses -> {:error, :link_exhausted}
      true -> :ok
    end
  end

  defp join_channel_immediately(room, user_id, nil) do
    with {:ok, _} <- insert_channel_subscriber(room.id, user_id) do
      Vibe.Cache.invalidate(participant_cache_key(room.id, user_id))
      invalidate_chat_home_cache(room.id)
      ChatHomeCache.invalidate_user(user_id)
      {:ok, %{status: "joined", room: canonical_room_summary(room, role: "subscriber")}}
    end
  end

  defp join_channel_immediately(room, user_id, %ChannelInviteLink{} = link) do
    case Repo.transaction(fn ->
           if is_participant?(room.id, user_id) do
             :already_joined
           else
             claim_invite_link!(link.id)
             insert_channel_subscriber!(room.id, user_id)
             :joined
           end
         end) do
      {:ok, _} ->
        Vibe.Cache.invalidate(participant_cache_key(room.id, user_id))
        invalidate_chat_home_cache(room.id)
        ChatHomeCache.invalidate_user(user_id)
        {:ok, %{status: "joined", room: canonical_room_summary(room, role: "subscriber")}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_invite_link!(link_id) do
    link =
      from(link in ChannelInviteLink, where: link.id == ^link_id, lock: "FOR UPDATE")
      |> Repo.one()

    case link && validate_invite_link(link) do
      :ok ->
        link
        |> ChannelInviteLink.changeset(%{use_count: link.use_count + 1})
        |> Repo.update!()

      {:error, reason} ->
        Repo.rollback(reason)

      nil ->
        Repo.rollback(:link_not_found)
    end
  end

  defp create_channel_join_request(room, user_id, link) do
    attrs = %{
      chat_id: room.id,
      user_id: user_id,
      invite_link_id: link && link.id,
      status: "pending"
    }

    case %ChannelJoinRequest{} |> ChannelJoinRequest.changeset(attrs) |> Repo.insert() do
      {:ok, request} ->
        {:ok, request}

      {:error, %Ecto.Changeset{} = changeset} ->
        request =
          Repo.one(
            from(request in ChannelJoinRequest,
              where:
                request.chat_id == ^room.id and request.user_id == ^user_id and
                  request.status == "pending"
            )
          )

        if request, do: {:ok, request}, else: {:error, changeset}
    end
  end

  defp review_join_request!(request, actor_id, status) do
    request
    |> ChannelJoinRequest.changeset(%{
      status: status,
      reviewer_id: actor_id,
      reviewed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()
  end

  defp join_request_payload(request) do
    user = if Ecto.assoc_loaded?(request.user), do: request.user

    %{
      id: request.id,
      chatId: request.chat_id,
      userId: request.user_id,
      userName: user && (present_string(user.name) || present_string(user.username)),
      userAvatarUrl: user && present_string(user.profile_image),
      status: request.status,
      reviewerId: request.reviewer_id,
      reviewedAt: request.reviewed_at,
      createdAt: naive_datetime_ms(request.inserted_at)
    }
  end

  defp insert_channel_subscriber(chat_id, user_id) do
    %Participant{}
    |> Participant.changeset(%{chat_id: chat_id, user_id: user_id})
    |> Participant.role_changeset("subscriber")
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:chat_id, :user_id])
  end

  defp insert_channel_subscriber!(chat_id, user_id) do
    case insert_channel_subscriber(chat_id, user_id) do
      {:ok, participant} -> participant
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp attach_channel_agent_in_transaction!(room, agent, actor_id, attrs) do
    case Repo.get_by(Participant, chat_id: room.id, user_id: agent.agent_user_id) do
      nil ->
        Repo.insert!(%Participant{
          chat_id: room.id,
          user_id: agent.agent_user_id,
          role: "agent_admin"
        })

      %Participant{role: "agent_admin"} ->
        :ok

      _ ->
        Repo.rollback(:agent_already_member)
    end

    assignment_attrs =
      assignment_policy_attrs(attrs, agent)
      |> Map.merge(%{
        chat_id: room.id,
        agent_id: agent.id,
        created_by: actor_id
      })

    assignment =
      case Repo.get_by(ChannelAgentAssignment, chat_id: room.id, agent_id: agent.id) do
        nil ->
          %ChannelAgentAssignment{}
          |> ChannelAgentAssignment.changeset(assignment_attrs)
          |> Repo.insert!()

        existing ->
          existing
          |> ChannelAgentAssignment.changeset(Map.put(assignment_attrs, :status, "active"))
          |> Repo.update!()
      end

    if is_nil(present_string(agent.default_destination_chat_id)) do
      agent |> Agent.changeset(%{default_destination_chat_id: room.id}) |> Repo.update!()
    end

    assignment
  end

  defp assignment_policy_attrs(attrs, agent \\ nil) do
    trigger_config =
      normalize_map(channel_attr(attrs, "triggerConfig") || channel_attr(attrs, "trigger_config"))

    status = present_string(channel_attr(attrs, "status")) || "active"

    %{
      allowed_tools:
        assignment_allowlist(
          attrs,
          ["allowedTools", "allowed_tools", :allowedTools, :allowed_tools],
          agent && agent.enabled_tools
        ),
      allowed_output_modes:
        assignment_allowlist(
          attrs,
          [
            "allowedOutputModes",
            "allowed_output_modes",
            :allowedOutputModes,
            :allowed_output_modes
          ],
          agent && agent.output_modes
        ),
      trigger_config: trigger_config,
      permissions: normalize_map(channel_attr(attrs, "permissions")),
      status: status,
      next_trigger_at: assignment_next_trigger_at(trigger_config, status)
    }
  end

  defp assignment_policy_patch(assignment, attrs) do
    defaults = assignment_policy_attrs(attrs)

    %{}
    |> maybe_put_assignment_patch(
      :allowed_tools,
      attrs,
      ["allowedTools", "allowed_tools", :allowedTools, :allowed_tools],
      defaults.allowed_tools
    )
    |> maybe_put_assignment_patch(
      :allowed_output_modes,
      attrs,
      ["allowedOutputModes", "allowed_output_modes", :allowedOutputModes, :allowed_output_modes],
      defaults.allowed_output_modes
    )
    |> maybe_put_assignment_patch(
      :trigger_config,
      attrs,
      ["triggerConfig", "trigger_config", :triggerConfig, :trigger_config],
      defaults.trigger_config
    )
    |> maybe_put_assignment_patch(
      :permissions,
      attrs,
      ["permissions", :permissions],
      defaults.permissions
    )
    |> maybe_put_assignment_patch(
      :status,
      attrs,
      ["status", :status],
      defaults.status
    )
    |> put_assignment_trigger_schedule(assignment)
  end

  defp maybe_put_assignment_patch(patch, key, attrs, keys, value) do
    if Enum.any?(keys, &Map.has_key?(attrs, &1)), do: Map.put(patch, key, value), else: patch
  end

  defp assignment_allowlist(attrs, keys, fallback) do
    if Enum.any?(keys, &Map.has_key?(attrs, &1)) do
      keys
      |> Enum.find_value(fn key -> Map.get(attrs, key) end)
      |> normalize_string_list()
    else
      normalize_string_list(fallback)
    end
  end

  defp put_assignment_trigger_schedule(patch, assignment) do
    trigger_config = Map.get(patch, :trigger_config, assignment.trigger_config || %{})
    status = Map.get(patch, :status, assignment.status)

    if Map.has_key?(patch, :trigger_config) or Map.has_key?(patch, :status) do
      Map.put(patch, :next_trigger_at, assignment_next_trigger_at(trigger_config, status))
    else
      patch
    end
  end

  defp assignment_next_trigger_at(trigger_config, "active") do
    interval_next_trigger_at(
      trigger_config,
      DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end

  defp assignment_next_trigger_at(_trigger_config, _status), do: nil

  defp interval_next_trigger_at(trigger_config, from) do
    trigger_config = normalize_map(trigger_config)

    if trigger_config["type"] == "interval" do
      minutes = normalize_positive_integer(trigger_config["everyMinutes"]) || 60
      DateTime.add(from, min(minutes, 10_080) * 60, :second)
    end
  end

  defp truncate_string(nil, _limit), do: nil
  defp truncate_string(value, limit), do: value |> to_string() |> String.slice(0, limit)

  defp channel_agent_payload(assignment) do
    agent = assignment.agent

    %{
      id: assignment.id,
      chatId: assignment.chat_id,
      agentId: assignment.agent_id,
      agentUserId: agent.agent_user_id,
      displayName: agent.display_name,
      avatarUrl: agent.avatar_url,
      role: "agent_admin",
      roleLabel: "Agent admin",
      status: assignment.status,
      allowedTools: assignment.allowed_tools || [],
      allowedOutputModes: assignment.allowed_output_modes || [],
      triggerConfig: assignment.trigger_config || %{},
      permissions: assignment.permissions || %{},
      nextTriggerAt: assignment.next_trigger_at,
      lastTriggeredAt: assignment.last_triggered_at,
      lastTriggerStatus: assignment.last_trigger_status,
      lastTriggerError: assignment.last_trigger_error,
      effectiveTools: intersect_policy(agent.enabled_tools, assignment.allowed_tools),
      effectiveOutputModes: intersect_policy(agent.output_modes, assignment.allowed_output_modes)
    }
  end

  defp intersect_policy(base, nil), do: normalize_string_list(base)

  defp intersect_policy(base, allowed) do
    allowed_set = MapSet.new(normalize_string_list(allowed))
    base |> normalize_string_list() |> Enum.filter(&MapSet.member?(allowed_set, &1))
  end

  defp human_admin?(chat_id, user_id), do: get_user_role(chat_id, user_id) in ["owner", "admin"]

  defp link_room_summary(room) do
    canonical_room_summary(room)
    |> Map.drop([:members])
  end

  defp normalize_public_slug(nil), do: nil

  defp normalize_public_slug(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s_]+/u, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> present_string()
  end

  defp valid_public_slug?(slug) when is_binary(slug),
    do: String.match?(slug, ~r/^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$/)

  defp valid_public_slug?(_), do: false

  defp token_digest(token), do: :crypto.hash(:sha256, to_string(token))

  defp channel_attr(attrs, key) do
    attrs[key] || attrs[String.to_atom(key)]
  end

  defp normalize_id_list(value), do: normalize_string_list(value)

  defp normalize_string_list(value) do
    value
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_map(value) when is_map(value), do: stringify_keys(value)
  defp normalize_map(_), do: %{}

  defp normalize_positive_integer(nil), do: nil
  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_positive_integer(_), do: nil

  defp normalize_expiry(%DateTime{} = value), do: DateTime.truncate(value, :second)

  defp normalize_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp normalize_expiry(_), do: nil

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp boolean_or_existing(attrs, keys, existing) do
    case Enum.find(keys, &Map.has_key?(attrs, &1)) do
      nil -> existing || false
      key -> truthy?(attrs[key])
    end
  end

  defp put_present_change(changes, _key, nil), do: changes

  defp put_present_change(changes, key, value) do
    case present_string(value) do
      nil -> changes
      normalized -> Map.put(changes, key, normalized)
    end
  end

  defp put_nullable_change(changes, key, attrs, keys) do
    case Enum.find(keys, &Map.has_key?(attrs, &1)) do
      nil -> changes
      source_key -> Map.put(changes, key, present_string(attrs[source_key]))
    end
  end

  defp legacy_channel_settings_patch(room, attrs) do
    settings_input = normalize_map(channel_attr(attrs, "settings"))
    allowed = ~w[discussionsEnabled reactionsEnabled allowDirectMessages autoTranslateEnabled]

    flat =
      Enum.reduce(allowed, %{}, fn key, acc ->
        snake = Macro.underscore(key)

        cond do
          Map.has_key?(attrs, key) -> Map.put(acc, key, attrs[key])
          Map.has_key?(attrs, snake) -> Map.put(acc, key, attrs[snake])
          true -> acc
        end
      end)

    safe_settings = Map.take(settings_input, allowed)
    room.channel_settings |> normalize_map() |> Map.merge(safe_settings) |> Map.merge(flat)
  end

  defp room_created_at_ms(%Room{inserted_at: inserted_at}), do: naive_datetime_ms(inserted_at)

  defp room_last_activity_ms(%Room{} = room) do
    Repo.one(
      from(message in Message, where: message.chat_id == ^room.id, select: max(message.timestamp))
    ) ||
      room_created_at_ms(room)
  end

  defp naive_datetime_ms(%NaiveDateTime{} = value) do
    value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
  end

  defp naive_datetime_ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)
  defp naive_datetime_ms(_), do: 0

  defp channel_member_payloads(channel_id) do
    from(p in Participant,
      where: p.chat_id == ^channel_id and (is_nil(p.deleted) or p.deleted == false),
      preload: [:user],
      order_by: [asc: p.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(fn member ->
      %{
        userId: member.user_id,
        name:
          present_string(member.user && member.user.name) ||
            present_string(member.user && member.user.username),
        username: present_string(member.user && member.user.username),
        avatarUrl: present_string(member.user && member.user.profile_image),
        role: member.role || "member"
      }
    end)
  end

  defp list_channel_recent_actions(channel_id, limit) when is_integer(limit) and limit > 0 do
    from(m in Message,
      where: m.chat_id == ^channel_id,
      order_by: [desc: m.timestamp],
      limit: ^limit,
      preload: [:from]
    )
    |> Repo.all()
    |> Enum.map(fn m ->
      body =
        present_string(m.encrypted_content) ||
          present_string(m.type) ||
          "message"

      %{
        id: m.id,
        type: m.type || "text",
        text: String.slice(body, 0, 240),
        fromId: m.from_id,
        fromName:
          present_string(m.from && m.from.name) ||
            present_string(m.from && m.from.username),
        timestampMs: m.timestamp,
        isSystem: m.type == "system"
      }
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      key =
        cond do
          is_binary(k) -> k
          is_atom(k) -> Atom.to_string(k)
          true -> to_string(k)
        end

      Map.put(acc, key, v)
    end)
  end

  defp stringify_keys(_), do: %{}

  def get_channel_analytics(channel_id, user_id \\ nil) do
    RepoRLS.with_user(user_id, fn ->
      subscriber_count =
        Repo.aggregate(
          from(p in Participant, where: p.chat_id == ^channel_id),
          :count
        )

      message_count =
        Repo.aggregate(
          from(m in Message, where: m.chat_id == ^channel_id),
          :count
        )

      week_ago = DateTime.utc_now() |> DateTime.add(-7, :day)

      recent_joins =
        Repo.aggregate(
          from(p in Participant,
            where: p.chat_id == ^channel_id and p.inserted_at >= ^week_ago
          ),
          :count
        )

      %{
        subscriber_count: subscriber_count,
        message_count: message_count,
        recent_joins_7d: recent_joins
      }
    end)
  end


  def can_send?(chat_id, user_id) do
    case Repo.get(Room, chat_id) do
      %Room{type: "channel"} ->
        Repo.exists?(
          from(p in Participant,
            left_join: assignment in ChannelAgentAssignment,
            on: assignment.chat_id == p.chat_id and assignment.status == "active",
            left_join: agent in Agent,
            on: agent.id == assignment.agent_id and agent.agent_user_id == p.user_id,
            where:
              p.chat_id == ^chat_id and p.user_id == ^user_id and
                (is_nil(p.deleted) or p.deleted == false) and
                (p.role in ["owner", "admin"] or
                   (p.role == "agent_admin" and not is_nil(agent.id)))
          )
        )

      %Room{type: type} when type in ["dm", "group"] ->
        is_participant?(chat_id, user_id)

      nil ->
        false
    end
  end

  def get_user_role(chat_id, user_id) do
    Repo.one(
      from(p in Participant,
        where:
          p.chat_id == ^chat_id and p.user_id == ^user_id and
            (is_nil(p.deleted) or p.deleted == false),
        select: p.role
      )
    )
  end

  @doc """
  Role and room type for a channel join, in one round trip instead of two.
  `nil` when the user is not a live participant; type is nil-able, caller defaults it.
  """
  def join_context(chat_id, user_id) do
    Repo.one(
      from(p in Participant,
        left_join: r in Room,
        on: r.id == p.chat_id,
        where:
          p.chat_id == ^chat_id and p.user_id == ^user_id and
            (is_nil(p.deleted) or p.deleted == false),
        select: {p.role, r.type}
      )
    )
  end

  @doc """
  The agent-shadow participant on the other side of a DM, or nil.
  One query where the caller previously listed participants then looked up each.
  """
  def dm_standalone_agent(chat_id, user_id) do
    query =
      from(p in Participant,
        join: a in Agent,
        on: a.agent_user_id == p.user_id,
        where: p.chat_id == ^chat_id and p.user_id != ^user_id,
        select: a,
        limit: 1
      )

    case Repo.one(query) do
      %Agent{} = agent -> Repo.preload(agent, :agent_user)
      _ -> nil
    end
  end

  def get_room_type(chat_id) do
    Repo.one(from(r in Room, where: r.id == ^chat_id, select: r.type))
  end

  def get_user_channels(user_id) do
    Repo.all(
      from(p in Participant,
        join: r in Room,
        on: r.id == p.chat_id,
        where: p.user_id == ^user_id and r.type == "channel" and p.role == "owner",
        select: %{id: r.id, name: r.name}
      )
    )
  end


  def create_scheduled_post(attrs) do
    %ScheduledPost{}
    |> ScheduledPost.changeset(attrs)
    |> Repo.insert()
  end

  def list_scheduled_posts(channel_id) do
    Repo.all(
      from(sp in ScheduledPost,
        where: sp.channel_id == ^channel_id and sp.status == "pending",
        order_by: [asc: sp.scheduled_at]
      )
    )
  end

  def get_scheduled_post(id) do
    Repo.get(ScheduledPost, id)
  end

  @doc "Atomic pending→posted claim; only the winning node delivers (multi-node safe)."
  def claim_scheduled_post(post_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(sp in ScheduledPost, where: sp.id == ^post_id and sp.status == "pending", select: sp)
    |> Repo.update_all(set: [status: "posted", posted_at: now])
    |> case do
      {1, [post]} -> {:ok, post}
      _ -> :already_claimed
    end
  end

  @doc "Reverts a claim whose delivery failed so a later boot retries it."
  def reopen_scheduled_post(post_id) do
    from(sp in ScheduledPost, where: sp.id == ^post_id)
    |> Repo.update_all(set: [status: "pending", posted_at: nil])
  end

  def cancel_scheduled_post(post_id, user_id) do
    case Repo.get(ScheduledPost, post_id) do
      %ScheduledPost{user_id: ^user_id, status: "pending"} = post ->
        post
        |> ScheduledPost.changeset(%{status: "cancelled"})
        |> Repo.update()

      %ScheduledPost{} ->
        {:error, "Unauthorized or already posted"}

      nil ->
        {:error, "Not found"}
    end
  end

  defp extract_from_id(attrs) when is_map(attrs) do
    attrs[:from_id] || attrs["from_id"] || attrs[:fromId] || attrs["fromId"]
  end

  defp extract_from_id(_), do: nil

  defp normalize_actor_id(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_actor_id(_), do: nil

  @doc false
  def client_message_payload(message), do: to_client_message(message)

  defp to_client_message(nil), do: nil

  defp to_client_message(%Message{} = message) do
    message = persist_expired_timed_media(message)

    case agent_message_meta(message) do
      nil ->
        base_message_map(message)

      meta ->
        plain_text = AgentMessageCrypto.decrypt_from_storage(message.encrypted_content || "")
        base = base_message_map(message)

        Map.merge(base, %{
          encrypted_content: "",
          plaintext: plain_text,
          plain_content: plain_text,
          is_agent_message: true,
          agent_name: meta.agent_name,
          agent_id: meta.agent_id,
          agent_user_id: meta.agent_user_id,
          agent_username: meta.agent_username,
          agent_handle: meta.agent_handle
        })
    end
  end

  defp to_client_message(other), do: other

  defp to_client_saved_message(%SavedMessage{} = message) do
    %{
      id: message.id,
      user_id: message.user_id,
      original_message_id: message.original_message_id,
      chat_id: message.chat_id,
      from_id: message.from_id,
      encrypted_content: message.encrypted_content,
      content: message.content,
      type: message.type,
      media_url: rewrite_media_url(message.media_url),
      timestamp: message.timestamp,
      extra: message.extra,
      reactions: saved_message_reactions(message.reaction_emoji),
      inserted_at: message.inserted_at
    }
  end

  defp agent_message_meta(%Message{} = message) do
    metadata = message.metadata || %{}

    cond do
      legacy_group_agent_id?(message.from_id) ->
        %{
          agent_name: "Vibe AI",
          agent_id: nil,
          agent_user_id: message.from_id,
          agent_username: "vibe_ai_agent_0001",
          agent_handle: "@vibe_ai_agent_0001"
        }

      metadata["isAgentMessage"] == true or metadata["is_agent_message"] == true ->
        %{
          agent_name: metadata["agentName"] || metadata["agent_name"] || "Vibe Agent",
          agent_id: metadata["agentId"] || metadata["agent_id"],
          agent_user_id: metadata["agentUserId"] || metadata["agent_user_id"] || message.from_id,
          agent_username: metadata["agentUsername"] || metadata["agent_username"],
          agent_handle: metadata["agentHandle"] || metadata["agent_handle"]
        }

      true ->
        nil
    end
  end

  defp legacy_group_agent_id?(from_id) do
    case {Ecto.UUID.cast(from_id), Ecto.UUID.cast(@agent_user_id)} do
      {{:ok, a}, {:ok, b}} -> a == b
      _ -> false
    end
  end

  defp friend_agent_event_inbox(friend_agent) when is_map(friend_agent) do
    get_in(friend_agent, [:approval_rules, "event_inbox"]) ||
      get_in(friend_agent, [:approval_rules, :event_inbox]) || %{}
  end

  defp friend_agent_event_inbox(_), do: %{}

  defp friend_agent_event_inbox_mode(friend_agent) do
    inbox = friend_agent_event_inbox(friend_agent)

    resolved =
      case inbox["mode"] do
        mode when mode in ["batched_summary", "batched", "batch", "summary"] -> "batched_summary"
        _ -> "per_event"
      end

    Logger.info(
      "[InboxBanner] chat payload agent_id=#{inspect(Map.get(friend_agent, :agent_id))} " <>
        "raw_event_inbox=#{inspect(inbox)} resolved_mode=#{resolved}"
    )

    resolved
  end

  defp friend_agent_event_inbox_window_hours(friend_agent) do
    case friend_agent_event_inbox(friend_agent)["summary_window_hours"] do
      hours when is_integer(hours) and hours > 0 -> hours
      _ -> 24
    end
  end

  defp friend_agent_accepts_incoming_chat(nil), do: true

  defp friend_agent_accepts_incoming_chat(friend_agent) when is_map(friend_agent) do
    chat_rules =
      get_in(friend_agent, [:approval_rules, "chat_input"]) ||
        get_in(friend_agent, [:approval_rules, :chat_input]) ||
        %{}

    case chat_rules["enabled"] || chat_rules[:enabled] do
      false -> false
      "false" -> false
      "0" -> false
      0 -> false
      _ -> true
    end
  end

  defp base_message_map(%Message{} = message) do
    meta = message.metadata || %{}
    expired = meta["mediaExpired"] == true or meta["media_expired"] == true

    %{
      id: message.id,
      chat_id: message.chat_id,
      from_id: message.from_id,
      timestamp: message.timestamp,
      type: message.type,
      encrypted_content: message.encrypted_content,
      status: message.status,
      media_url: if(expired, do: nil, else: rewrite_media_url(message.media_url)),
      metadata: meta,
      reply_to_id: message.reply_to_id,
      editedAt: message.edited_at
    }
  end

  defp decorate_engagement([], _chat_id, _user_id), do: []

  defp decorate_engagement(client_messages, chat_id, user_id) do
    ids = for %{id: id} <- client_messages, is_binary(id), do: id

    if ids == [] do
      client_messages
    else
      decorated =
        apply_reaction_summaries(client_messages, batched_reaction_summaries(ids, user_id))

      if get_room_type(chat_id) in ["group", "channel"] do
        counts =
          ids
          |> Enum.chunk_every(@engagement_batch_limit)
          |> Enum.map(&message_view_counts/1)
          |> merge_maps()

        Enum.map(decorated, fn
          %{id: id} = message when is_binary(id) ->
            Map.put(message, :viewCount, Map.get(counts, id, 0))

          other ->
            other
        end)
      else
        decorated
      end
    end
  end

  defp batched_reaction_summaries([], _user_id), do: %{}

  defp batched_reaction_summaries(message_ids, user_id) do
    message_ids
    |> Enum.chunk_every(@engagement_batch_limit)
    |> Enum.map(&message_reaction_summaries(&1, user_id))
    |> merge_maps()
  end

  defp apply_reaction_summaries(client_messages, reactions) do
    Enum.map(client_messages, fn
      %{id: id} = message when is_binary(id) ->
        Map.put(message, :reactions, Map.get(reactions, id, []))

      other ->
        other
    end)
  end

  defp merge_maps(maps), do: Enum.reduce(maps, %{}, &Map.merge(&2, &1))

  defp rewrite_media_url(url), do: Storage.rewrite_public_url(url)

  defp invalidate_chat_home_cache(chat_id) when is_binary(chat_id) do
    participant_ids =
      Repo.all(
        from(p in Participant,
          where: p.chat_id == ^chat_id,
          select: p.user_id
        )
      )

    ChatHomeCache.invalidate_users(participant_ids)
    :ok
  end

  defp invalidate_chat_home_cache(_chat_id), do: :ok

  defp invalidate_home_cache_for_message(message_id) when is_binary(message_id) do
    case Repo.one(from(m in Message, where: m.id == ^message_id, select: m.chat_id)) do
      chat_id when is_binary(chat_id) -> invalidate_chat_home_cache(chat_id)
      _ -> :ok
    end
  end

  defp invalidate_home_cache_for_message(_message_id), do: :ok

  defp normalize_history_limit(limit) when is_integer(limit),
    do: limit |> max(1) |> min(@history_max_limit)

  defp normalize_history_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, _rest} -> normalize_history_limit(parsed)
      :error -> @history_default_limit
    end
  end

  defp normalize_history_limit(_limit), do: @history_default_limit

  defp encode_history_cursor(%Message{} = message) do
    Jason.encode!(%{timestamp: message.timestamp || 0, id: message.id})
    |> Base.url_encode64(padding: false)
  end

  defp encode_history_cursor(_message), do: nil

  defp decode_history_cursor(nil), do: nil
  defp decode_history_cursor(""), do: nil

  defp decode_history_cursor(cursor) when is_binary(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"timestamp" => timestamp, "id" => id}} <- Jason.decode(raw),
         ts when is_integer(ts) <- normalize_cursor_timestamp(timestamp),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      %{timestamp: ts, id: uuid}
    else
      _ -> nil
    end
  end

  defp decode_history_cursor(_cursor), do: nil

  defp normalize_cursor_timestamp(value) when is_integer(value), do: value

  defp normalize_cursor_timestamp(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp normalize_cursor_timestamp(_value), do: nil
end
