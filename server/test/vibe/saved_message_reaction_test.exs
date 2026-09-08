defmodule Vibe.SavedMessageReactionTest do
  @moduledoc "Private Saved Messages reactions: context, encoder, controller, route."

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Vibe.Accounts.User
  alias Vibe.Chat
  alias Vibe.Chat.SavedMessage
  alias Vibe.Repo
  alias VibeWeb.SavedMessageController

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    %{alice: insert_user("saved_alice"), bob: insert_user("saved_bob")}
  end

  describe "toggle_saved_message_reaction/3" do
    test "adds, replaces, and toggles the single emoji off", %{alice: alice} do
      id = save_item(alice)

      assert {:ok,
              %{
                original_message_id: ^id,
                action: :added,
                reactions: [%{emoji: "👍", count: 1, isSelected: true}]
              }} = Chat.toggle_saved_message_reaction(alice.id, id, "👍")

      assert {:ok, %{action: :replaced, reactions: [%{emoji: "❤️", count: 1, isSelected: true}]}} =
               Chat.toggle_saved_message_reaction(alice.id, id, "❤️")

      assert {:ok, %{action: :removed, reactions: []}} =
               Chat.toggle_saved_message_reaction(alice.id, id, "❤️")

      assert reaction_of(alice, id) == nil

      family = "👩🏽‍❤️‍💋‍👨🏽"

      assert {:ok, %{action: :added, reactions: [%{emoji: ^family}]}} =
               Chat.toggle_saved_message_reaction(alice.id, id, " #{family} ")

      assert reaction_of(alice, id) == family
    end

    test "keeps one user's reaction out of another user's saved copy", %{
      alice: alice,
      bob: bob
    } do
      id = "shared-original-#{System.unique_integer([:positive])}"
      ^id = save_item(alice, id)
      ^id = save_item(bob, id)

      assert {:ok, %{action: :added}} = Chat.toggle_saved_message_reaction(alice.id, id, "🔥")

      assert reaction_of(alice, id) == "🔥"
      assert reaction_of(bob, id) == nil

      assert [%{reactions: [%{emoji: "🔥", count: 1, isSelected: true}]}] =
               Chat.list_saved_messages(alice.id)

      assert [%{reactions: []}] = Chat.list_saved_messages(bob.id)
    end

    test "rejects an invalid emoji and an id the caller has not saved", %{
      alice: alice,
      bob: bob
    } do
      id = save_item(alice)

      assert {:error, :invalid_emoji} = Chat.toggle_saved_message_reaction(alice.id, id, "  ")
      assert {:error, :invalid_emoji} = Chat.toggle_saved_message_reaction(alice.id, id, nil)

      assert {:error, :invalid_emoji} =
               Chat.toggle_saved_message_reaction(alice.id, id, String.duplicate("👍", 20))

      assert {:error, :invalid_id} = Chat.toggle_saved_message_reaction(alice.id, "  ", "👍")
      assert {:error, :not_found} = Chat.toggle_saved_message_reaction(bob.id, id, "👍")
      assert {:error, :not_found} = Chat.toggle_saved_message_reaction(alice.id, "nope", "👍")

      assert reaction_of(alice, id) == nil
    end
  end

  describe "list_saved_messages/1" do
    test "carries the persisted bucket across a reload", %{alice: alice} do
      id = save_item(alice)

      assert [%{original_message_id: ^id, reactions: []}] = Chat.list_saved_messages(alice.id)
      assert {:ok, _} = Chat.toggle_saved_message_reaction(alice.id, id, "👍")

      assert [%{original_message_id: ^id, reactions: [%{emoji: "👍", count: 1, isSelected: true}]}] =
               Chat.list_saved_messages(alice.id)
    end
  end

  describe "reaction controller action" do
    test "returns the canonical id, action, and reactions", %{alice: alice} do
      id = save_item(alice)
      conn = call_reaction(alice, %{"original_message_id" => id, "emoji" => "👍"})

      assert conn.status == 200

      assert %{
               "data" => %{
                 "original_message_id" => ^id,
                 "action" => "added",
                 "reactions" => [%{"emoji" => "👍", "count" => 1, "isSelected" => true}]
               }
             } = Jason.decode!(conn.resp_body)
    end

    test "ignores a body user id and acts as the session user", %{alice: alice, bob: bob} do
      id = save_item(alice)

      conn =
        call_reaction(alice, %{
          "original_message_id" => id,
          "emoji" => "🔥",
          "user_id" => bob.id
        })

      assert conn.status == 200
      assert reaction_of(alice, id) == "🔥"
      assert reaction_of(bob, id) == nil
    end

    test "maps an invalid emoji to 400 and a missing item to 404", %{alice: alice} do
      id = save_item(alice)

      invalid = call_reaction(alice, %{"original_message_id" => id, "emoji" => " "})
      assert invalid.status == 400

      missing = call_reaction(alice, %{"original_message_id" => "gone", "emoji" => "👍"})
      assert missing.status == 404
    end
  end

  describe "route" do
    test "PUT reaction is registered and authenticated" do
      route =
        Enum.find(
          VibeWeb.Router.__routes__(),
          &(&1.verb == :put and &1.path == "/api/saved_messages/:original_message_id/reaction")
        )

      assert %{plug: SavedMessageController, plug_opts: :reaction} = route

      conn =
        Plug.Test.conn(:put, "/api/saved_messages/anything/reaction", %{"emoji" => "👍"})
        |> VibeWeb.Router.call(VibeWeb.Router.init([]))

      assert conn.status == 401
      assert conn.halted
    end
  end

  defp call_reaction(user, params) do
    Plug.Test.conn(:put, "/api/saved_messages/#{params["original_message_id"]}/reaction", params)
    |> Plug.Conn.assign(:current_user, user)
    |> SavedMessageController.reaction(params)
  end

  defp save_item(user, original_message_id \\ nil) do
    id = original_message_id || "saved-original-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Chat.save_message(%{
        "user_id" => user.id,
        "original_message_id" => id,
        "chat_id" => "saved-chat-#{System.unique_integer([:positive])}",
        "from_id" => user.id,
        "type" => "text",
        "encrypted_content" => "sealed",
        "timestamp" => System.system_time(:millisecond)
      })

    id
  end

  defp reaction_of(user, original_message_id) do
    Repo.one(
      from(sm in SavedMessage,
        where: sm.user_id == ^user.id and sm.original_message_id == ^original_message_id,
        select: sm.reaction_emoji
      )
    )
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
