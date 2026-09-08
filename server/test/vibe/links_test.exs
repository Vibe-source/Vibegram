defmodule Vibe.LinksTest do
  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.Chat
  alias Vibe.Links
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    original = System.get_env("VIBE_SHARE_BASE_URL")
    System.put_env("VIBE_SHARE_BASE_URL", "https://vibegram.io")

    on_exit(fn ->
      if original, do: System.put_env("VIBE_SHARE_BASE_URL", original),
        else: System.delete_env("VIBE_SHARE_BASE_URL")
    end)

    %{owner: insert_user("link_owner")}
  end

  describe "link shapes" do
    test "handles, rooms and display forms" do
      assert Links.handle_url("newsroom") == "https://vibegram.io/newsroom"
      assert Links.handle_url("@Newsroom") == "https://vibegram.io/newsroom"
      assert Links.handle_url("  ") == nil
      assert Links.handle_url(nil) == nil

      assert Links.room_url("/r/daily-news") == "https://vibegram.io/r/daily-news"
      assert Links.room_url("/j/tok3n") == "https://vibegram.io/j/tok3n"
      assert Links.room_url("daily-news") == "https://vibegram.io/r/daily-news"
      assert Links.room_url("https://short.link/r/x") == "https://short.link/r/x"
      assert Links.room_url(nil) == nil

      assert Links.display("https://vibegram.io/newsroom") == "vibegram.io/newsroom"
      assert Links.display(nil) == nil
    end

    test "base url is a single configurable knob" do
      System.put_env("VIBE_SHARE_BASE_URL", "vibe.me")
      assert Links.share_base_url() == "https://vibe.me"
      assert Links.handle_url("newsroom") == "https://vibe.me/newsroom"

      System.delete_env("VIBE_SHARE_BASE_URL")
      assert Links.share_base_url() == "https://api.vibegram.io"
    end

    test "normalizes handles out of pasted links" do
      assert Links.normalize_handle("https://vibegram.io/newsroom") == "newsroom"
      assert Links.normalize_handle("@NewsRoom") == "newsroom"
      assert Links.normalize_handle(%{"username" => "Bot_One"}) == "bot_one"
      assert Links.normalize_handle(123) == nil
    end

    test "web app paths are never treated as handles" do
      for reserved <- ~w[app docs settings api assets favicon.ico] do
        assert Links.reserved_handle?(reserved)
        assert {:error, :reserved} = Links.resolve_handle(reserved)
      end

      refute Links.reserved_handle?("newsroom")
    end
  end

  describe "resolve_handle/2" do
    test "resolves a person to a DM target", %{owner: owner} do
      assert {:ok, target} = Links.resolve_handle(owner.username)
      assert target.kind == :user
      assert target.user_id == owner.id
      assert target.url == "https://vibegram.io/#{owner.username}"
      assert target.deep_link =~ "vibe://u?"
      assert target.deep_link =~ owner.id
    end

    test "hides a person's avatar when their privacy setting does" do
      shy = insert_user("link_shy", %{profile_image: "https://img/x.png", privacy_profile_photos: "nobody"})
      open = insert_user("link_open", %{profile_image: "https://img/y.png"})

      assert {:ok, %{avatar_url: nil}} = Links.resolve_handle(shy.username)
      assert {:ok, %{avatar_url: "https://img/y.png"}} = Links.resolve_handle(open.username)
    end

    test "resolves a published agent, and a draft only for its owner", %{owner: owner} do
      published = insert_agent(owner, display_name: "News Bot")
      draft = insert_agent(owner, status: "draft", display_name: "Draft Bot")

      assert {:ok, target} = Links.resolve_handle(published.agent_user.username)
      assert target.kind == :agent
      assert target.title == "News Bot"
      assert target.agent_id == published.id
      assert target.url == "https://vibegram.io/#{published.agent_user.username}"

      assert {:error, :not_found} = Links.resolve_handle(draft.agent_user.username)

      assert {:ok, %{kind: :agent, title: "Draft Bot"}} =
               Links.resolve_handle(draft.agent_user.username, viewer_user_id: owner.id)
    end

    test "resolves a public channel slug", %{owner: owner} do
      assert {:ok, channel} =
               Chat.create_channel(owner.id, %{
                 "name" => "Daily News",
                 "accessType" => "public",
                 "publicSlug" => "daily-news"
               })

      assert {:ok, target} = Links.resolve_handle("daily-news")
      assert target.kind == :channel
      assert target.chat_id == channel.chatId
      assert target.url == "https://vibegram.io/r/daily-news"
      assert target.deep_link == "vibe://room-link?slug=daily-news"
    end

    test "unknown handles do not resolve" do
      assert {:error, :not_found} = Links.resolve_handle("nobody_here_at_all")
      assert {:error, :not_found} = Links.resolve_handle("")
      assert {:error, :not_found} = Links.resolve_handle(nil)
    end
  end

  describe "room payloads carry an absolute link" do
    test "a public channel always has a shareUrl", %{owner: owner} do
      assert {:ok, channel} =
               Chat.create_channel(owner.id, %{
                 "name" => "Launch",
                 "accessType" => "public",
                 "publicSlug" => "launch-room"
               })

      assert channel.shareLink == "/r/launch-room"
      assert channel.shareUrl == "https://vibegram.io/r/launch-room"

      reread = Chat.canonical_room_summary(Chat.get_chat(channel.chatId), role: "owner")
      assert reread.shareUrl == "https://vibegram.io/r/launch-room"
    end

    test "a private channel's shareUrl is its invite token", %{owner: owner} do
      assert {:ok, channel} =
               Chat.create_channel(owner.id, %{"name" => "Inner", "accessType" => "private"})

      assert "/j/" <> token = channel.shareLink
      assert channel.shareUrl == "https://vibegram.io/j/#{token}"
    end

    test "slug helpers propose and check availability", %{owner: owner} do
      assert Chat.slugify_public_slug("Daily News!") == "daily-news"
      assert Chat.slugify_public_slug("x") == nil
      assert Chat.public_slug_available?("daily-news")

      assert {:ok, _} =
               Chat.create_channel(owner.id, %{
                 "name" => "Daily News",
                 "accessType" => "public",
                 "publicSlug" => "daily-news"
               })

      refute Chat.public_slug_available?("daily-news")
    end
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

  defp insert_agent(owner, attrs) do
    shadow = insert_user("agentlink", %{is_agent: true})

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
end
