defmodule Vibe.MessageEngagementTest do
  @moduledoc "Reaction, view, history engagement, and durable edit tests."

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Chat
  alias Vibe.Chat.{Message, MessageReaction, MessageView, Participant, Room}
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    %{
      alice: insert_user("engage_alice"),
      bob: insert_user("engage_bob"),
      carol: insert_user("engage_carol")
    }
  end

  describe "toggle_reaction/4" do
    test "adds, toggles off, and replaces the caller's single reaction", %{
      alice: alice,
      bob: bob
    } do
      {chat_id, message} = dm_with_message(alice, bob)

      assert {:ok, %{action: :added, reactions: [%{emoji: "👍", count: 1, isSelected: true}]}} =
               Chat.toggle_reaction(chat_id, message.id, bob.id, "👍")

      assert {:ok, %{action: :removed, reactions: []}} =
               Chat.toggle_reaction(chat_id, message.id, bob.id, "👍")

      assert {:ok, %{action: :added}} = Chat.toggle_reaction(chat_id, message.id, bob.id, "👍")

      assert {:ok, %{action: :replaced, reactions: [%{emoji: "❤️", count: 1}]}} =
               Chat.toggle_reaction(chat_id, message.id, bob.id, "❤️")

      assert Repo.aggregate(MessageReaction, :count) == 1

      family = "👩🏽‍❤️‍💋‍👨🏽"

      assert {:ok, %{action: :replaced, reactions: [%{emoji: ^family, count: 1}]}} =
               Chat.toggle_reaction(chat_id, message.id, bob.id, family)
    end

    test "aggregates per emoji and flags only the caller's bucket", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      {:ok, room} = Chat.create_group(alice.id, "Engagement", [bob.id, carol.id])
      message = insert_message(room.id, alice.id)

      assert {:ok, _} = Chat.toggle_reaction(room.id, message.id, alice.id, "👍")
      assert {:ok, _} = Chat.toggle_reaction(room.id, message.id, bob.id, "👍")
      assert {:ok, _} = Chat.toggle_reaction(room.id, message.id, carol.id, "🔥")

      assert [
               %{emoji: "👍", count: 2, isSelected: true},
               %{emoji: "🔥", count: 1, isSelected: false}
             ] = Chat.message_reactions(message.id, bob.id)

      assert [%{isSelected: false}, %{isSelected: false}] =
               Chat.message_reactions(message.id, nil)
    end

    test "rejects a non-participant, a foreign message, and an empty emoji", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      {chat_id, message} = dm_with_message(alice, bob)
      {other_chat_id, other_message} = dm_with_message(alice, carol)

      assert {:error, :forbidden} = Chat.toggle_reaction(chat_id, message.id, carol.id, "👍")
      assert {:error, :not_found} = Chat.toggle_reaction(chat_id, other_message.id, bob.id, "👍")
      assert {:error, :invalid_emoji} = Chat.toggle_reaction(chat_id, message.id, bob.id, "  ")

      assert {:error, :invalid_emoji} =
               Chat.toggle_reaction(chat_id, message.id, bob.id, String.duplicate("👍", 20))

      assert {:error, :invalid_id} = Chat.toggle_reaction(chat_id, "not-a-uuid", bob.id, "👍")
      assert Repo.aggregate(MessageReaction, :count) == 0

      assert Chat.message_reactions(other_message.id, alice.id) == []
      assert other_chat_id != chat_id
    end

    test "a room with reactions disabled refuses the reaction", %{alice: alice, bob: bob} do
      chat_id = insert_channel([alice, bob], %{"reactionsEnabled" => false})
      message = insert_message(chat_id, alice.id)

      assert {:error, :reactions_disabled} =
               Chat.toggle_reaction(chat_id, message.id, bob.id, "👍")

      enabled_chat_id = insert_channel([alice, bob], %{"reactionsEnabled" => true})
      enabled_message = insert_message(enabled_chat_id, alice.id)

      assert {:ok, %{action: :added}} =
               Chat.toggle_reaction(enabled_chat_id, enabled_message.id, bob.id, "👍")

      {:ok, group} = Chat.create_group(alice.id, "Disabled reactions", [bob.id])

      group
      |> Ecto.Changeset.change(channel_settings: %{"reactionsEnabled" => false})
      |> Repo.update!()

      group_message = insert_message(group.id, alice.id)

      assert {:error, :reactions_disabled} =
               Chat.toggle_reaction(group.id, group_message.id, bob.id, "👍")
    end
  end

  describe "mark_messages_viewed/3" do
    test "is idempotent per user and never counts the author", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      {:ok, room} = Chat.create_group(alice.id, "Views", [bob.id, carol.id])
      message = insert_message(room.id, alice.id)

      assert {:ok, [%{messageId: id, viewCount: 1}]} =
               Chat.mark_messages_viewed(room.id, bob.id, [message.id])

      assert id == message.id

      assert {:ok, [%{viewCount: 1}]} =
               Chat.mark_messages_viewed(room.id, bob.id, [message.id, message.id])

      assert {:ok, [%{viewCount: 2}]} =
               Chat.mark_messages_viewed(room.id, carol.id, [message.id])

      assert {:ok, []} = Chat.mark_messages_viewed(room.id, alice.id, [message.id])
      assert Repo.aggregate(MessageView, :count) == 2
    end

    test "ignores ids that belong to another chat", %{alice: alice, bob: bob, carol: carol} do
      {:ok, room} = Chat.create_group(alice.id, "Views scope", [bob.id])
      {:ok, other} = Chat.create_group(alice.id, "Other room", [carol.id])
      foreign = insert_message(other.id, alice.id)

      assert {:ok, []} = Chat.mark_messages_viewed(room.id, bob.id, [foreign.id])
      assert Repo.aggregate(MessageView, :count) == 0
    end

    test "refuses non-participants and direct chats", %{alice: alice, bob: bob, carol: carol} do
      {:ok, room} = Chat.create_group(alice.id, "Views guard", [bob.id])
      message = insert_message(room.id, alice.id)
      {dm_id, dm_message} = dm_with_message(alice, bob)

      assert {:error, :forbidden} = Chat.mark_messages_viewed(room.id, carol.id, [message.id])

      assert {:error, :unsupported_chat} =
               Chat.mark_messages_viewed(dm_id, bob.id, [dm_message.id])

      assert {:error, :invalid_id} = Chat.mark_messages_viewed(room.id, bob.id, ["nope"])
    end
  end

  describe "history payload" do
    test "carries reactions, viewCount, and editedAt for a group", %{
      alice: alice,
      bob: bob
    } do
      {:ok, room} = Chat.create_group(alice.id, "Payload", [bob.id])
      message = insert_message(room.id, alice.id)

      assert {:ok, _} = Chat.toggle_reaction(room.id, message.id, bob.id, "👍")
      assert {:ok, _} = Chat.mark_messages_viewed(room.id, bob.id, [message.id])

      page = Chat.get_messages_for_user_page(room.id, bob.id, limit: 30)
      assert [payload] = page.messages

      assert payload.reactions == [%{emoji: "👍", count: 1, isSelected: true}]
      assert payload.viewCount == 1
      assert payload.editedAt == nil

      author_page = Chat.get_messages_for_user_page(room.id, alice.id, limit: 30)
      assert [%{reactions: [%{isSelected: false}]}] = author_page.messages
    end

    test "omits viewCount for direct chats", %{alice: alice, bob: bob} do
      {chat_id, _message} = dm_with_message(alice, bob)

      page = Chat.get_messages_for_user_page(chat_id, bob.id, limit: 30)
      assert [payload] = page.messages
      refute Map.has_key?(payload, :viewCount)
      assert payload.reactions == []
    end
  end

  describe "home seed payload" do
    test "seeds the same reactions summary as paged history", %{alice: alice, bob: bob} do
      {:ok, room} = Chat.create_group(alice.id, "Seed", [bob.id])
      message = insert_message(room.id, alice.id)

      assert [%{reactions: []}] = seeded_messages(bob.id, room.id)
      assert {:ok, _} = Chat.toggle_reaction(room.id, message.id, bob.id, "👍")

      assert seeds = seeded_messages(bob.id, room.id)
      assert [%{id: seeded_id, reactions: reactions}] = seeds
      assert seeded_id == message.id
      assert reactions == [%{emoji: "👍", count: 1, isSelected: true}]

      page = Chat.get_messages_for_user_page(room.id, bob.id, limit: 30)
      assert [%{reactions: ^reactions}] = page.messages

      assert [%{reactions: [%{emoji: "👍", count: 1, isSelected: false}]}] =
               seeded_messages(alice.id, room.id)
    end

    test "seeds an empty reactions list when nobody reacted", %{alice: alice, bob: bob} do
      {chat_id, message} = dm_with_message(alice, bob)

      assert [%{id: seeded_id, reactions: []}] = seeded_messages(bob.id, chat_id)
      assert seeded_id == message.id
    end
  end

  describe "message_reaction_detail/3" do
    test "groups actors per emoji with identity, avatar, and timestamp", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      {:ok, room} = Chat.create_group(alice.id, "Detail", [bob.id, carol.id])
      message = insert_message(room.id, alice.id)

      assert {:ok, _} = Chat.toggle_reaction(room.id, message.id, alice.id, "👍")
      assert {:ok, _} = Chat.toggle_reaction(room.id, message.id, bob.id, "👍")
      assert {:ok, _} = Chat.toggle_reaction(room.id, message.id, carol.id, "🔥")

      assert {:ok, [top, second]} = Chat.message_reaction_detail(room.id, message.id, bob.id)

      assert %{emoji: "👍", count: 2, isSelected: true, users: users} = top
      assert %{emoji: "🔥", count: 1, isSelected: false, users: [carol_actor]} = second

      assert Enum.sort(Enum.map(users, & &1.userId)) == Enum.sort([alice.id, bob.id])
      assert carol_actor.userId == carol.id
      assert carol_actor.name == carol.name
      assert carol_actor.username == carol.username
      assert carol_actor.avatarUrl == carol.profile_image
      assert is_integer(carol_actor.reactedAt)

      dave = insert_user("engage_dave")
      Repo.insert!(%Participant{chat_id: room.id, user_id: dave.id, role: "member"})

      assert {:ok, [%{isSelected: false}, %{isSelected: false}]} =
               Chat.message_reaction_detail(room.id, message.id, dave.id)
    end

    test "falls back to the username when a reactor has no display name", %{
      alice: alice,
      bob: bob
    } do
      {chat_id, message} = dm_with_message(alice, bob)
      Repo.update!(Ecto.Changeset.change(bob, name: nil, profile_image: ""))

      assert {:ok, _} = Chat.toggle_reaction(chat_id, message.id, bob.id, "👍")

      assert {:ok, [%{users: [actor]}]} =
               Chat.message_reaction_detail(chat_id, message.id, alice.id)

      assert actor.name == bob.username
      assert actor.avatarUrl == nil
    end

    test "returns an empty list for a message nobody reacted to", %{alice: alice, bob: bob} do
      {chat_id, message} = dm_with_message(alice, bob)
      assert {:ok, []} = Chat.message_reaction_detail(chat_id, message.id, bob.id)
    end

    test "refuses non-members, foreign messages, and malformed ids", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      {chat_id, message} = dm_with_message(alice, bob)
      {_other_chat_id, other_message} = dm_with_message(alice, carol)

      assert {:error, :forbidden} = Chat.message_reaction_detail(chat_id, message.id, carol.id)

      assert {:error, :not_found} =
               Chat.message_reaction_detail(chat_id, other_message.id, bob.id)

      assert {:error, :invalid_id} = Chat.message_reaction_detail(chat_id, "not-a-uuid", bob.id)

      assert {:error, :forbidden} =
               Chat.message_reaction_detail(chat_id, message.id, Ecto.UUID.generate())
    end
  end

  describe "edit_message/5" do
    test "preserves the original timestamp and persists editedAt", %{alice: alice, bob: bob} do
      {chat_id, message} = dm_with_message(alice, bob)
      edited_at = message.timestamp + 60_000

      assert {:ok, updated} =
               Chat.edit_message(chat_id, message.id, alice.id, "sealed-v2", edited_at)

      assert updated.timestamp == message.timestamp
      assert updated.edited_at == edited_at

      reloaded = Repo.get!(Message, message.id)
      assert reloaded.timestamp == message.timestamp
      assert reloaded.edited_at == edited_at

      page = Chat.get_messages_for_user_page(chat_id, bob.id, limit: 30)
      assert [%{timestamp: original, editedAt: ^edited_at}] = page.messages
      assert original == message.timestamp
    end

    test "stamps a server editedAt when the client sends none", %{alice: alice, bob: bob} do
      {chat_id, message} = dm_with_message(alice, bob)

      assert {:ok, updated} = Chat.edit_message(chat_id, message.id, alice.id, "sealed-v2")
      assert is_integer(updated.edited_at)
      assert updated.edited_at >= message.timestamp
      assert updated.timestamp == message.timestamp
    end
  end

  defp dm_with_message(author, peer) do
    chat_id = "engage-dm-#{System.unique_integer([:positive])}"
    {:ok, _room} = Chat.create_chat(chat_id, [author.id, peer.id])
    {chat_id, insert_message(chat_id, author.id)}
  end

  defp insert_channel(users, settings) do
    chat_id = "engage-channel-#{System.unique_integer([:positive])}"

    Repo.insert!(%Room{
      id: chat_id,
      type: "channel",
      is_group: true,
      name: "Engagement channel",
      channel_settings: settings
    })

    Enum.each(users, fn user ->
      Repo.insert!(%Participant{chat_id: chat_id, user_id: user.id, role: "member"})
    end)

    chat_id
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
      name: "Engage #{suffix}",
      profile_image: "https://cdn.example/#{prefix}_#{suffix}.png",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      is_agent: false
    })
  end

  defp seeded_messages(user_id, chat_id) do
    chat = Enum.find(Chat.list_chats(user_id), &(&1.chatId == chat_id))
    assert chat, "chat #{chat_id} missing from the home list"
    chat.messages
  end
end
