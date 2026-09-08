defmodule VibeWeb.AgentBridgeChannelTest do
  use ExUnit.Case, async: true

  alias VibeWeb.AgentBridgeChannel

  test "parses valid running, done, and failed team status lines" do
    assert {:ok, %{"worker" => "codex", "state" => "running", "label" => "Implementing"}} =
             AgentBridgeChannel.parse_team_status_line(
               ~s(VIBE_TEAM_STATUS {"worker":"codex","state":"running","label":"Implementing"})
             )

    assert {:ok, %{"worker" => "claude", "state" => "done", "label" => "Complete"}} =
             AgentBridgeChannel.parse_team_status_line(
               ~s(VIBE_TEAM_STATUS {"worker":"claude","state":"done","label":"Complete"})
             )

    assert {:ok, %{"worker" => "grok", "state" => "failed", "label" => "Build failed"}} =
             AgentBridgeChannel.parse_team_status_line(
               ~s(VIBE_TEAM_STATUS {"worker":"grok","state":"failed","label":"Build failed"})
             )
  end

  test "parses the spawn / starting beat that stamps the worker start" do
    assert {:ok, %{"worker" => "grok", "state" => "spawn", "label" => "call grok — UI"}} =
             AgentBridgeChannel.parse_team_status_line(
               ~s(VIBE_TEAM_STATUS {"worker":"grok","state":"spawn","label":"call grok — UI"})
             )

    assert {:ok, %{"worker" => "codex", "state" => "starting", "label" => nil}} =
             AgentBridgeChannel.parse_team_status_line(
               ~s(VIBE_TEAM_STATUS {"worker":"codex","state":"starting"})
             )
  end

  test "parses an optional label as nil" do
    assert {:ok, %{"worker" => "agy", "state" => "running", "label" => nil}} =
             AgentBridgeChannel.parse_team_status_line(
               ~s(VIBE_TEAM_STATUS {"worker":"agy","state":"running"})
             )
  end

  test "ignores malformed, incomplete, and non-marker lines" do
    assert :ignore = AgentBridgeChannel.parse_team_status_line("VIBE_TEAM_STATUS {bad json}")

    assert :ignore =
             AgentBridgeChannel.parse_team_status_line(~s(VIBE_TEAM_STATUS {"state":"running"}))

    assert :ignore =
             AgentBridgeChannel.parse_team_status_line(
               ~s(VIBE_TEAM_STATUS {"worker":"codex","state":"waiting"})
             )

    assert :ignore = AgentBridgeChannel.parse_team_status_line("ordinary stdout")
  end
end
