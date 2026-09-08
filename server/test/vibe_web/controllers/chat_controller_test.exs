defmodule VibeWeb.ChatControllerTest do
  @moduledoc "Reaction-detail endpoint: route, authorization, and payload shape."

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Chat
  alias Vibe.Chat.Message
  alias Vibe.Repo
  alias VibeWeb.ChatController

  @detail_path "/api/chat/:chat_id/messages/:message_id/reactions"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    author = insert_user("detail_author")
    reader = insert_user("detail_reader")
    outsider = insert_user("detail_outsider")
    {:ok, room} = Chat.create_group(author.id, "Reaction detail", [reader.id])
    message = insert_message(room.id, author.id)

    %{
      author: author,
      reader: reader,
      outsider: outsider,
      chat_id: room.id,
      message: message
    }
  end

  describe "route" do
    test "GET reactions is registered and authenticated" do
      route =
        Enum.find(
          VibeWeb.Router.__routes__(),
          &(&1.verb == :get and &1.path == @detail_path)
        )

      assert %{plug: ChatController, plug_opts: :message_reactions} = route

      conn =
        Plug.Test.conn(:get, "/api/chat/any/messages/#{Ecto.UUID.generate()}/reactions")
        |> VibeWeb.Router.call(VibeWeb.Router.init([]))

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "message_reactions/2" do
    test "returns emoji-grouped actors for a member", context do
      %{author: author, reader: reader, chat_id: chat_id, message: message} = context

      assert {:ok, _} = Chat.toggle_reaction(chat_id, message.id, author.id, "👍")
      assert {:ok, _} = Chat.toggle_reaction(chat_id, message.id, reader.id, "👍")

      conn = call_detail(reader, chat_id, message.id)
      assert conn.status == 200

      assert %{
               "chatId" => ^chat_id,
               "messageId" => message_id,
               "total" => 2,
               "reactions" => [
                 %{"emoji" => "👍", "count" => 2, "isSelected" => true, "users" => users}
               ]
             } = Jason.decode!(conn.resp_body)

      assert message_id == message.id
      assert length(users) == 2

      actor = Enum.find(users, &(&1["userId"] == author.id))
      assert actor["name"] == author.name
      assert actor["username"] == author.username
      assert actor["avatarUrl"] == author.profile_image
      assert is_integer(actor["reactedAt"])
    end

    test "returns an empty payload when nobody reacted", context do
      %{reader: reader, chat_id: chat_id, message: message} = context

      conn = call_detail(reader, chat_id, message.id)

      assert conn.status == 200
      assert %{"total" => 0, "reactions" => []} = Jason.decode!(conn.resp_body)
    end

    test "rejects a non-member with 403", context do
      %{author: author, outsider: outsider, chat_id: chat_id, message: message} = context

      assert {:ok, _} = Chat.toggle_reaction(chat_id, message.id, author.id, "👍")

      conn = call_detail(outsider, chat_id, message.id)

      assert conn.status == 403
      assert %{"error" => "Not a participant"} = Jason.decode!(conn.resp_body)
    end

    test "maps a foreign message to 404 and a malformed id to 400", context do
      %{reader: reader, chat_id: chat_id} = context

      foreign = call_detail(reader, chat_id, Ecto.UUID.generate())
      assert foreign.status == 404

      malformed = call_detail(reader, chat_id, "not-a-uuid")
      assert malformed.status == 400
    end
  end

  defp call_detail(user, chat_id, message_id) do
    params = %{"chat_id" => chat_id, "message_id" => message_id}

    Plug.Test.conn(:get, "/api/chat/#{chat_id}/messages/#{message_id}/reactions")
    |> Plug.Conn.assign(:current_user, user)
    |> ChatController.message_reactions(params)
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
      name: "Detail #{suffix}",
      profile_image: "https://cdn.example/#{prefix}_#{suffix}.png",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      is_agent: false
    })
  end
end
