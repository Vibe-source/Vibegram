defmodule VibeWeb.BridgeStatusPushTest do
  @moduledoc """
  The phone stopped polling `/api/agent-bridge/status`.
  """
  use ExUnit.Case, async: true

  alias Vibe.AgentBridge
  alias VibeWeb.Presence

  defp unique_user_id, do: "push-test-#{System.unique_integer([:positive])}"

  defp track(topic, key, meta) do
    owner = self()

    pid =
      spawn(fn ->
        {:ok, _ref} = Presence.track(self(), topic, key, meta)
        send(owner, :tracked)
        receive do: (:stop -> :ok)
      end)

    assert_receive :tracked, 2_000
    pid
  end

  test "a computer coming online emits a diff on the bridge topic" do
    user_id = unique_user_id()
    topic = AgentBridge.topic(user_id)
    :ok = Phoenix.PubSub.subscribe(Vibe.PubSub, topic)

    pid = track(topic, "computer-1", %{"deviceLabel" => "Mac", "repositories" => []})

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "presence_diff"}, 2_000

    send(pid, :stop)
  end

  test "a metadata update emits a diff too — this is how a task start reaches the phone" do
    user_id = unique_user_id()
    topic = AgentBridge.topic(user_id)

    owner = self()

    pid =
      spawn(fn ->
        {:ok, _} = Presence.track(self(), topic, "computer-1", %{"deviceLabel" => "Mac"})
        send(owner, :tracked)

        receive do
          :update ->
            {:ok, _} =
              Presence.update(self(), topic, "computer-1", %{
                "deviceLabel" => "Mac",
                "runningTasks" => [%{"taskId" => "t-1", "provider" => "claude"}]
              })

            send(owner, :updated)
            receive do: (:stop -> :ok)
        end
      end)

    assert_receive :tracked, 2_000

    :ok = Phoenix.PubSub.subscribe(Vibe.PubSub, topic)
    send(pid, :update)
    assert_receive :updated, 2_000

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "presence_diff"}, 2_000

    send(pid, :stop)
  end

  test "status_for_push reports the connected computer and its running tasks" do
    user_id = unique_user_id()
    topic = AgentBridge.topic(user_id)

    pid =
      track(topic, "computer-1", %{
        "deviceLabel" => "Mac",
        "computerId" => "computer-1",
        "repositories" => [%{"name" => "Vibe", "path" => "/Users/x/Vibe"}],
        "runningTasks" => [%{"taskId" => "t-1", "provider" => "claude"}]
      })

    status = AgentBridge.status_for_push(user_id)

    assert status.connected
    assert status.paired
    assert [%{"taskId" => "t-1"}] = status.runningTasks
    assert length(status.repositories) == 1

    send(pid, :stop)
  end

  test "an unknown user with no computer reports disconnected and unpaired" do
    status = AgentBridge.status_for_push(Ecto.UUID.generate())

    refute status.connected
    refute status.paired
    assert status.runningTasks == []
    assert status.repositories == []
  end

  test "a malformed user id degrades to disconnected instead of crashing the channel" do
    status = AgentBridge.status_for_push("not-a-uuid")

    refute status.connected
    refute status.paired
  end
end
