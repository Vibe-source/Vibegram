defmodule Vibe.AgentTurnContractTest do
  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.AI.Agent, as: ChatAgent
  alias Vibe.AI.AgenticEventShape
  alias Vibe.AI.StandaloneAgent
  alias Vibe.AI.ToolRegistry
  alias Vibe.AI.Tools.Channel
  alias Vibe.Chat
  alias Vibe.Repo

  setup context do
    if context[:db] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

      owner = insert_user("turn_owner")
      subscriber = insert_user("turn_subscriber")
      agent = insert_agent(owner)

      %{owner: owner, subscriber: subscriber, agent: agent}
    else
      :ok
    end
  end

  @tag :db
  test "tool registry exposes effective and bounded testability state", %{
    owner: owner,
    subscriber: subscriber,
    agent: agent
  } do
    assert ToolRegistry.get("search_music").testability == "live_readonly"
    assert ToolRegistry.get("create_chat_space").testability == "dry_run"
    assert ToolRegistry.get("post_to_channel").category == "chat_management"
    assert ToolRegistry.get("schedule_channel_post").testability == "dry_run"

    effective = ChatAgent.effective_tool_names(["search_music"])
    assert "search_music" in effective
    assert "ask_user" in effective
    assert "inspect_current_agent_tools" in effective
    refute "create_chat_space" in effective

    inspected = ChatAgent.inspect_current_agent_tools(%{}, agent.id, owner.id)
    assert inspected["ok"]
    assert inspected["output_modes"]["supported"] == ["text", "media", "voice"]
    assert Enum.find(inspected["tools"], &(&1["id"] == "ask_user"))["effective"]

    denied = ChatAgent.inspect_current_agent_tools(%{}, agent.id, subscriber.id)
    refute denied["ok"]

    dry_run =
      ChatAgent.test_current_agent_tool(
        %{"tool_id" => "update_current_agent_config"},
        agent.id,
        owner.id
      )

    assert dry_run["ok"]
    refute dry_run["executed"]
    refute dry_run["capability"]["mutation_performed"]
  end

  @tag :db
  test "current agent config tool normalizes lists and rejects a subscriber", %{
    owner: owner,
    subscriber: subscriber,
    agent: agent
  } do
    updated =
      ChatAgent.update_current_agent_config(
        %{
          "enabled_tools" => ["search_music", "create_chat_space", "search_music"],
          "output_modes" => ["text", "media"]
        },
        agent.id,
        owner.id
      )

    assert updated["ok"]
    assert updated["agent"]["enabled_tools"] == ["search_music", "create_chat_space"]
    assert updated["agent"]["output_modes"] == ["text", "media"]

    denied =
      ChatAgent.update_current_agent_config(
        %{"enabled_tools" => ["search_google"]},
        agent.id,
        subscriber.id
      )

    refute denied["ok"]
    assert Repo.get!(Agent, agent.id).enabled_tools == ["search_music", "create_chat_space"]
  end

  @tag :db
  test "the agent can read and set its own destination chat", %{owner: owner, agent: agent} do
    {:ok, dm_id, _status} = Vibe.Chat.ensure_dm_chat(owner.id, agent.agent_user_id)

    assert Repo.get!(Agent, agent.id).default_destination_chat_id == nil

    read = ChatAgent.get_current_agent_config(%{}, agent.id, owner.id)
    assert read["ok"]
    assert read["agent"]["effective_destination_chat_id"] == dm_id

    set =
      ChatAgent.update_current_agent_config(
        %{"default_destination_chat_id" => "here"},
        agent.id,
        owner.id,
        dm_id
      )

    assert set["ok"], inspect(set)
    assert Repo.get!(Agent, agent.id).default_destination_chat_id == dm_id

    stranger_chat = Ecto.UUID.generate()

    rejected =
      ChatAgent.update_current_agent_config(
        %{"default_destination_chat_id" => stranger_chat},
        agent.id,
        owner.id,
        nil
      )

    refute rejected["ok"]
    assert Repo.get!(Agent, agent.id).default_destination_chat_id == dm_id
  end

  @tag :db
  test "room tools attach only for the agent owner", %{
    owner: owner,
    subscriber: subscriber,
    agent: agent
  } do
    created =
      Channel.create_chat_space(
        %{
          "room_type" => "group",
          "name" => "Agent room",
          "member_ids" => [subscriber.id]
        },
        agent.id,
        owner.id
      )

    assert created["ok"]
    assert created["attached_current_agent"]
    chat_id = created["room"]["chat_id"]
    assert created["room"]["chat_link"] == "vibe://chat?chatId=#{chat_id}"
    assert Chat.get_user_role(chat_id, owner.id) == "owner"
    assert Chat.get_user_role(chat_id, agent.agent_user_id) == "member"

    channel =
      Channel.create_chat_space(
        %{
          "room_type" => "channel",
          "name" => "Public updates",
          "member_ids" => [subscriber.id],
          "access_type" => "public",
          "public_slug" => "agent-updates",
          "attach_current_agent" => false
        },
        agent.id,
        owner.id
      )

    assert channel["ok"]
    refute channel["attached_current_agent"]
    channel_id = channel["room"]["chat_id"]
    assert Chat.get_user_role(channel_id, subscriber.id) == "subscriber"
    assert Chat.get_user_role(channel_id, agent.agent_user_id) == nil

    denied =
      Channel.attach_current_agent_to_chat(
        %{"chat_id" => channel_id},
        agent.id,
        subscriber.id
      )

    refute denied["ok"]

    attached =
      Channel.attach_current_agent_to_chat(%{"chat_id" => channel_id}, agent.id, owner.id)

    assert attached["ok"]
    assert attached["attachment"].role == "agent_admin"
    assert Chat.get_user_role(channel_id, agent.agent_user_id) == "agent_admin"

    posted =
      Channel.post_to_channel(
        %{"channel_id" => channel_id, "content" => "Agent-authored update"},
        agent.id,
        owner.id
      )

    assert posted["ok"]
    assert posted["from_id"] == agent.agent_user_id

    stored_message = Chat.get_message(channel_id, posted["message_id"], owner.id)
    assert stored_message.from_id == agent.agent_user_id
    assert stored_message.metadata["agentId"] == agent.id

    denied_post =
      Channel.post_to_channel(
        %{"channel_id" => channel_id, "content" => "Not allowed"},
        agent.id,
        subscriber.id
      )

    refute denied_post["ok"]
  end

  test "music outputs preserve track order and receive stable batch indices" do
    result = %{
      source: "youtube",
      tracks: [
        %{
          video_id: "first",
          title: "First",
          artist: "Artist One",
          album: "Album One",
          duration: "3:05",
          preview_url: "https://cdn.example/first.mp3",
          cover: "https://cdn.example/first.jpg",
          links: %{youtube: "https://youtube.example/first"}
        },
        %{
          video_id: "second",
          title: "Second",
          artist: "Artist Two",
          album: nil,
          duration: 242,
          preview_url: nil,
          cover: "https://cdn.example/second.jpg",
          links: %{}
        }
      ]
    }

    outputs = StandaloneAgent.tool_outputs_from_result("search_music", result)
    assert Enum.map(outputs, & &1.metadata["videoId"]) == ["first", "second"]
    assert String.ends_with?(hd(outputs).mediaUrl, "/api/music/stream/first")
    assert String.ends_with?(Enum.at(outputs, 1).mediaUrl, "/api/music/stream/second")
    assert hd(outputs).metadata["durationSeconds"] == 185

    batch =
      StandaloneAgent.finalize_batch([%{type: "text", text: "Enjoy"} | outputs],
        agent_turn_id: "turn-1",
        agent_batch_id: "batch-1",
        base_timestamp: 10_000
      )

    assert Enum.map(batch, & &1.type) == ["text", "music", "music"]
    assert Enum.map(batch, & &1.metadata["agentPartIndex"]) == [0, 1, 2]
    assert Enum.map(batch, & &1.timestamp) == [10_000, 10_001, 10_002]
    assert Enum.all?(batch, &(&1.metadata["agentPartCount"] == 3))
    assert Enum.all?(batch, & &1.metadata["agentFinalized"])
  end

  test "ask_user is normalized, terminal, and emitted as a question output" do
    result =
      ChatAgent.ask_user(%{
        "questions" => [
          %{
            "question" => " Which destination should I use? ",
            "header" => "Destination room",
            "multiSelect" => false,
            "options" => [
              %{"label" => "General", "description" => "The main room"},
              %{"label" => "General", "description" => "Duplicate"},
              %{"label" => "Alerts", "description" => "Only alerts"}
            ]
          }
        ]
      })

    assert result["ok"]
    assert result["status"] == "waiting_for_user"
    assert is_binary(result["requestId"])

    assert result["questions"] == [
             %{
               "question" => "Which destination should I use?",
               "header" => "Destination ",
               "multiSelect" => false,
               "options" => [
                 %{"label" => "General", "description" => "The main room"},
                 %{"label" => "Alerts", "description" => "Only alerts"}
               ]
             }
           ]

    [output] = StandaloneAgent.tool_outputs_from_result("ask_user", result)
    assert output.type == "question"
    assert output.status == "waiting_for_user"
    assert output.text == "Which destination should I use?"
    assert output.metadata["requestId"] == result["requestId"]

    assert StandaloneAgent.final_text_with_tool_fallback(nil, [
             %{tool: "ask_user", result: result}
           ]) == "Which destination should I use?"

    [text_part, question_part] =
      StandaloneAgent.finalize_batch(
        [
          %{type: "text", text: output.text},
          output
        ],
        agent_turn_id: "turn-question",
        agent_batch_id: "batch-question"
      )

    assert text_part.metadata["agentPartIndex"] == 0
    assert question_part.metadata["agentPartIndex"] == 1
    assert question_part.metadata["status"] == "waiting_for_user"
  end

  test "agentic events expose canonical short activity states" do
    for {event, expected_state} <- [
          {"chunk", "typing"},
          {"progress", "working"},
          {"done", "ready"},
          {"error", "ready"}
        ] do
      enriched = AgenticEventShape.enrich(event, %{})

      assert enriched.activityState == expected_state
      assert enriched.activity_state == expected_state
    end
  end

  # The 32-grapheme cap was the PRIMARY shortener and clipped almost every.
  test "agentic progress labels are single-line and capped at 40 graphemes" do
    long_label = "  Inspecting\n" <> String.duplicate("é", 40) <> "\twith details  "
    detailed_result = %{"content" => String.duplicate("full result ", 20)}

    enriched =
      AgenticEventShape.enrich("progress", %{
        label: long_label,
        progressNodes: [
          %{label: long_label, result: detailed_result},
          %{"title" => long_label, "detail" => "keep\nthis detail intact"}
        ],
        activity: [%{title: long_label, detail: "keep activity detail"}]
      })

    assert String.length(enriched.label) == 40
    assert String.ends_with?(enriched.label, "…")
    refute String.contains?(enriched.label, "\n")

    [first_node, second_node] = enriched.progressNodes
    assert String.length(first_node.label) == 40
    assert String.ends_with?(first_node.label, "…")
    assert first_node.result == detailed_result
    assert String.length(second_node["title"]) == 40
    assert String.ends_with?(second_node["title"], "…")
    assert second_node["detail"] == "keep\nthis detail intact"

    [activity] = enriched.activity
    assert String.length(activity.title) == 40
    assert String.ends_with?(activity.title, "…")
    assert activity.detail == "keep activity detail"
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

  defp insert_agent(owner) do
    shadow = insert_user("turn_agent_shadow")

    shadow
    |> Ecto.Changeset.change(is_agent: true)
    |> Repo.update!()

    %Agent{
      owner_user_id: owner.id,
      agent_user_id: shadow.id,
      status: "published",
      display_name: "Turn Agent",
      system_prompt: "Help the user.",
      enabled_tools: ["search_music"],
      output_modes: ["text"],
      webhook_secret_hash: "hash",
      secret_hint: "hint"
    }
    |> Repo.insert!()
    |> Repo.preload(:agent_user)
  end
end
