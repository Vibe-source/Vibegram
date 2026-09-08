defmodule Vibe.AgentStreamTriggerGateTest do
  @moduledoc """
  `message.stream` is an ingest path like any other and must clear the same channel gate.
  """

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.Agents
  alias Vibe.AI.AgentEventRuntime
  alias Vibe.Chat
  alias Vibe.Chat.ChannelAgentAssignment
  alias Vibe.Chat.Room
  alias Vibe.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    owner = insert_user("stream_owner")
    agent = insert_agent(owner)
    {:ok, agent, secret} = Agents.rotate_secret(agent, owner.id)

    %{owner: owner, agent: agent, secret: secret}
  end

  test "a stream into a channel without an event trigger is rejected", ctx do
    channel = attach_agent_to_channel(ctx.owner, ctx.agent)

    assert {:error, :event_trigger_not_enabled} =
             AgentEventRuntime.ingest(ctx.agent, stream_frame(channel.id), secret: ctx.secret)
  end

  test "the same channel accepts a stream once its trigger is event", ctx do
    channel = attach_agent_to_channel(ctx.owner, ctx.agent)
    set_channel_trigger!(channel.id, ctx.agent, "event")

    assert {:ok, _result} =
             AgentEventRuntime.ingest(ctx.agent, stream_frame(channel.id), secret: ctx.secret)
  end

  test "the owner DM fallback is unaffected — no destination needed", ctx do
    frame = Map.delete(stream_frame(nil), "destinationChatId")

    assert {:ok, _result} = AgentEventRuntime.ingest(ctx.agent, frame, secret: ctx.secret)
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp stream_frame(chat_id) do
    %{
      "eventType" => "message.stream",
      "streamId" => "stream-#{System.unique_integer([:positive])}",
      "seq" => 1,
      "text" => "partial…",
      "done" => true,
      "destinationChatId" => chat_id
    }
  end

  # کانال با ایجنت به‌عنوان agent_admin ساخته می‌شود؛ trigger پیش‌فرضش.
  defp attach_agent_to_channel(owner, agent) do
    {:ok, payload} =
      Chat.create_channel(owner.id, %{
        "name" => "Ops #{System.unique_integer([:positive])}",
        "agentAdminIds" => [agent.id]
      })

    Repo.get!(Room, payload.chatId)
  end

  defp set_channel_trigger!(channel_id, agent, type) do
    Repo.get_by!(ChannelAgentAssignment, chat_id: channel_id, agent_id: agent.id)
    |> Ecto.Changeset.change(trigger_config: %{"type" => type})
    |> Repo.update!()
  end

  defp insert_user(prefix, attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(
      struct(%User{
        id: Ecto.UUID.generate(),
        username: "#{prefix}_#{suffix}",
        password_hash: "hash",
        public_key: "key",
        device_id: "device-#{suffix}",
        is_agent: false
      }, attrs)
    )
  end

  defp insert_agent(owner) do
    shadow = insert_user("streamagent", %{is_agent: true})

    Repo.insert!(%Agent{
      owner_user_id: owner.id,
      agent_user_id: shadow.id,
      status: "published",
      display_name: "Streamer",
      enabled_tools: [],
      output_modes: ["text"],
      webhook_secret_hash: "hash",
      secret_hint: "hint"
    })
    |> Repo.preload(:agent_user)
  end
end
