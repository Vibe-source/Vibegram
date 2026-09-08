defmodule Vibe.AgentComputerRelayTest do
  @moduledoc "run.computer.state / run.computer.control → the `agent-computer` frame on chat:<id>."

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vibe.AgentRelay

  setup do
    chat_id = "chat-computer-#{System.unique_integer([:positive])}"
    VibeWeb.Endpoint.subscribe("chat:#{chat_id}")
    on_exit(fn -> VibeWeb.Endpoint.unsubscribe("chat:#{chat_id}") end)
    %{chat_id: chat_id}
  end

  defp event(chat_id, kind, payload) do
    %{
      "contract" => "vibe.agentic.v1",
      "kind" => kind,
      "runId" => "run-#{System.unique_integer([:positive])}",
      "chatId" => chat_id,
      "agentId" => "agent-#{System.unique_integer([:positive])}",
      "agentUserId" => "agent-user-1",
      "seq" => 1,
      "ts" => 1_700_000_000_000,
      "payload" => payload
    }
  end

  test "run.computer.state broadcasts agent-computer with url/title/live", %{chat_id: chat_id} do
    ev = event(chat_id, "run.computer.state", %{"url" => "https://instagram.com", "title" => "Instagram", "live" => true})
    run_id = ev["runId"]

    log = capture_log(fn -> assert :ok = AgentRelay.handle(ev) end)
    refute log =~ "unhandled RunEvent"

    assert_receive %Phoenix.Socket.Broadcast{event: "agent-computer", payload: payload}
    assert payload["chatId"] == chat_id
    assert payload["runId"] == run_id
    assert payload["agentUserId"] == "agent-user-1"
    assert payload["url"] == "https://instagram.com"
    assert payload["title"] == "Instagram"
    assert payload["live"] == true
    assert payload["ts"] == 1_700_000_000_000
    assert Map.has_key?(payload, "holder")
    assert payload["holder"] == nil
  end

  test "run.computer.control broadcasts the holder on the same event", %{chat_id: chat_id} do
    ev = event(chat_id, "run.computer.control", %{"holder" => "user", "reason" => "login", "expiresAt" => "2026-09-01T00:00:00Z"})
    run_id = ev["runId"]

    log = capture_log(fn -> assert :ok = AgentRelay.handle(ev) end)
    refute log =~ "unhandled RunEvent"

    assert_receive %Phoenix.Socket.Broadcast{event: "agent-computer", payload: payload}
    assert payload["chatId"] == chat_id
    assert payload["runId"] == run_id
    assert payload["holder"] == "user"
    assert payload["url"] == nil
    assert payload["title"] == nil
    assert payload["live"] == nil
  end

  test "neither kind leaks onto agent-stream", %{chat_id: chat_id} do
    assert :ok = AgentRelay.handle(event(chat_id, "run.computer.state", %{"url" => "https://x.test", "live" => false}))
    assert_receive %Phoenix.Socket.Broadcast{event: "agent-computer"}
    refute_receive %Phoenix.Socket.Broadcast{event: "agent-stream"}, 100
  end

  test "a terminal event without relay state does not erase rendered content", %{chat_id: chat_id} do
    terminal = event(chat_id, "run.completed", %{})
    run_id = terminal["runId"]

    assert :ok = AgentRelay.handle(terminal)
    assert_receive %Phoenix.Socket.Broadcast{event: "agent-stream", payload: stream}
    assert stream["runId"] == run_id
    assert stream["status"] == "done"
    refute Map.has_key?(stream, "text")
    refute Map.has_key?(stream, "progressNodes")
    refute Map.has_key?(stream, "toolEvents")
    assert_receive %Phoenix.Socket.Broadcast{event: "agent-run-state", payload: %{"runId" => ^run_id}}
  end
end
