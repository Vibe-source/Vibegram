defmodule Vibe.AgentRoomToolsTest do
  @moduledoc """
  The built-in assistant DM has no attached agent, so every room/agent tool used to fail there
  by construction.
  """

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.Agents
  alias Vibe.AI.Tools.Channel, as: ChannelTools
  alias Vibe.Chat
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    original = System.get_env("VIBE_SHARE_BASE_URL")
    System.put_env("VIBE_SHARE_BASE_URL", "https://vibegram.io")

    on_exit(fn ->
      if original, do: System.put_env("VIBE_SHARE_BASE_URL", original),
        else: System.delete_env("VIBE_SHARE_BASE_URL")
    end)

    %{owner: insert_user("room_owner")}
  end

  describe "create_chat_space with no current agent (assistant DM)" do
    test "creates a group owned by the requester", %{owner: owner} do
      result =
        ChannelTools.create_chat_space(
          %{"room_type" => "group", "name" => "Research", "topic" => "Papers we like"},
          nil,
          owner.id
        )

      assert result["ok"]
      assert result["room"]["room_type"] == "group"
      assert result["room"]["name"] == "Research"
      assert result["room"]["description"] == "Papers we like"
      assert result["attached_agent"] == nil
      refute result["attached_current_agent"]
      assert Chat.get_user_role(result["room"]["chat_id"], owner.id) == "owner"
    end

    test "a public channel gets a link even when no slug was given", %{owner: owner} do
      result =
        ChannelTools.create_chat_space(
          %{"room_type" => "channel", "name" => "Daily News!", "access_type" => "public"},
          nil,
          owner.id
        )

      assert result["ok"]
      assert result["room"]["public_slug"] == "daily-news"
      assert result["share_url"] == "https://vibegram.io/r/daily-news"
      assert result["share_link_display"] == "vibegram.io/r/daily-news"
    end

    test "a taken slug falls back to a readable variant, never a random number", %{owner: owner} do
      other = insert_user("slug_squatter")

      assert {:ok, _} =
               Chat.create_channel(other.id, %{
                 "name" => "Daily News",
                 "accessType" => "public",
                 "publicSlug" => "daily-news"
               })

      result =
        ChannelTools.create_chat_space(
          %{"room_type" => "channel", "name" => "Daily News", "access_type" => "public"},
          nil,
          owner.id
        )

      assert result["ok"]
      assert result["room"]["public_slug"] == "daily-news-channel"
      refute result["room"]["public_slug"] =~ ~r/[0-9a-f]{6}/
    end

    test "a private channel comes back with its invite link", %{owner: owner} do
      result =
        ChannelTools.create_chat_space(
          %{"room_type" => "channel", "name" => "Inner circle"},
          nil,
          owner.id
        )

      assert result["ok"]
      assert result["room"]["access_type"] == "private"
      assert result["share_url"] =~ "https://vibegram.io/j/"
    end

    test "attaches an agent named by @username, with per-room media policy", %{owner: owner} do
      agent = insert_agent(owner, display_name: "News Bot")

      result =
        ChannelTools.create_chat_space(
          %{
            "room_type" => "channel",
            "name" => "Media Room",
            "access_type" => "public",
            "attach_agent" => "@#{agent.agent_user.username}",
            "agent_output_modes" => ["text", "media"]
          },
          nil,
          owner.id
        )

      assert result["ok"]
      assert result["attached_agent"]["agent_id"] == agent.id
      assert result["attached_agent"]["public_link"] ==
               "https://vibegram.io/#{agent.agent_user.username}"

      chat_id = result["room"]["chat_id"]
      assert Chat.get_user_role(chat_id, agent.agent_user_id) == "agent_admin"

      assert {:ok, [assignment]} = Chat.list_channel_agents(chat_id, owner.id)
      assert Enum.sort(assignment.allowedOutputModes) == ["media", "text"]
    end

    test "an agent the requester does not own is refused", %{owner: owner} do
      stranger = insert_user("stranger")
      foreign = insert_agent(stranger, display_name: "Not Yours")

      result =
        ChannelTools.create_chat_space(
          %{
            "room_type" => "group",
            "name" => "Nope",
            "attach_agent" => foreign.agent_user.username
          },
          nil,
          owner.id
        )

      refute result["ok"]
      assert result["error"] =~ "don't own an agent"
    end

    test "requires an owner", %{} do
      result = ChannelTools.create_chat_space(%{"room_type" => "group", "name" => "X"}, nil, nil)
      refute result["ok"]
      assert result["error"] =~ "Owner identity"
    end
  end

  describe "attach_agent_to_chat" do
    test "attaches a named agent to an existing owned group", %{owner: owner} do
      agent = insert_agent(owner, display_name: "Helper")
      assert {:ok, room} = Chat.create_group(owner.id, "Team", [], nil, nil)

      result =
        ChannelTools.attach_agent_to_chat(
          %{"chat_id" => room.id, "agent" => agent.id},
          nil,
          owner.id
        )

      assert result["ok"]
      assert result["agent"]["agent_id"] == agent.id
      assert Chat.get_user_role(room.id, agent.agent_user_id) == "member"
    end

    test "says which agent it needs when none is named and none is attached", %{owner: owner} do
      assert {:ok, room} = Chat.create_group(owner.id, "Team", [], nil, nil)

      result = ChannelTools.attach_agent_to_chat(%{"chat_id" => room.id}, nil, owner.id)

      refute result["ok"]
      assert result["error"] =~ "Name the agent"
    end
  end

  describe "usernames are public identity" do
    test "a clean handle is derived from the display name", %{owner: owner} do
      assert {:ok, agent, _secret} =
               Agents.create_agent(owner.id, %{"display_name" => "News Room"})

      assert agent.agent_user.username == "news_room"
      assert Agents.agent_payload(agent).publicLink == "https://vibegram.io/news_room"
    end

    test "a taken handle is refused instead of suffixed with random characters", %{owner: owner} do
      other = insert_user("twin_owner")
      assert {:ok, _agent, _secret} = Agents.create_agent(owner.id, %{"display_name" => "Twin"})

      assert {:error, :username_taken} =
               Agents.create_agent(other.id, %{"display_name" => "Twin"})
    end

    test "suggestions are readable and actually free", %{owner: owner} do
      assert {:ok, _agent, _secret} = Agents.create_agent(owner.id, %{"display_name" => "Radar"})

      suggestions = Agents.suggest_usernames("Radar")

      refute "radar" in suggestions
      assert length(suggestions) > 0

      for name <- suggestions do
        refute name =~ ~r/[0-9]/
        assert {:ok, ^name} = Agents.username_availability(name, nil)
      end
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
    shadow = insert_user("roomagent", %{is_agent: true})

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
