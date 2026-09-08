defmodule VibeAgents.Voice.ToolRiskTest do
  use ExUnit.Case, async: true

  alias VibeAgents.Voice.ToolRisk

  test "classifies the frozen tool names per docs/agent-platform-v1.md §3.9" do
    assert ToolRisk.classify("search_google") == :read
    assert ToolRisk.classify("read_url") == :read
    assert ToolRisk.classify("computer_read_file") == :read
    assert ToolRisk.classify("browser_screenshot") == :read
    assert ToolRisk.classify("recall") == :read

    assert ToolRisk.classify("computer_run") == :write_local
    assert ToolRisk.classify("computer_write_file") == :write_local
    assert ToolRisk.classify("browser_open") == :write_local
    assert ToolRisk.classify("browser_act") == :write_local
    assert ToolRisk.classify("remember") == :write_local
    assert ToolRisk.classify("handoff_to_agent") == :write_local
  end

  test "unclassified tool names default to write_local (safer than auto-run)" do
    assert ToolRisk.classify("some_future_tool") == :write_local
  end

  test "read always runs" do
    assert ToolRisk.decision(:read, "search_google", "manual", %{}) == :run
  end

  test "credential always asks the user, regardless of autonomy mode" do
    assert ToolRisk.decision(:credential, "anything", "full_auto", %{}) == :ask_user
    assert ToolRisk.decision(:credential, "anything", "manual", %{}) == :ask_user
  end

  test "write_local runs under full/safe auto, is plan-only under manual/draft, else needs approval" do
    assert ToolRisk.decision(:write_local, "computer_run", "full_auto", %{}) == :run
    assert ToolRisk.decision(:write_local, "computer_run", "safe_auto", %{}) == :run
    assert ToolRisk.decision(:write_local, "computer_run", "manual", %{}) == :plan_only
    assert ToolRisk.decision(:write_local, "computer_run", "draft_first", %{}) == :plan_only
    assert ToolRisk.decision(:write_local, "computer_run", "approval_required", %{}) == :approval
  end

  # No frozen tool name reaches :external_effect through classify/1 (matches.
  test "external_effect needs approval unless full_auto and allowlisted; manual is plan-only" do
    assert ToolRisk.decision(:external_effect, "some_tool", "safe_auto", %{}) == :approval
    assert ToolRisk.decision(:external_effect, "some_tool", "approval_required", %{}) == :approval
    assert ToolRisk.decision(:external_effect, "some_tool", "manual", %{}) == :plan_only
    assert ToolRisk.decision(:external_effect, "some_tool", "full_auto", %{}) == :approval

    assert ToolRisk.decision(:external_effect, "some_tool", "full_auto", %{"allow" => ["some_tool"]}) ==
             :run
  end
end
