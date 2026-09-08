defmodule VibeAgents.Voice.ToolRisk do
  @moduledoc """
  Fallback risk/autonomy table used only when VibeAgents.Voice.Session can't reach
  VibeAgents.Broker.authorize/3 (module not loaded yet). Matches Broker.risk_class/2's
  by-name defaults; Broker also does content heuristics on computer_run/browser_act
  this static table can't — see docs/agent-voice-v1.md §7.
  """

  @type risk :: :read | :write_local | :external_effect | :credential
  @type outcome :: :run | :approval | :ask_user | :plan_only

  @read ~w(search_google read_url computer_read_file computer_list_files browser_screenshot browser_read_page recall)
  @write_local ~w(computer_run computer_write_file computer_edit_file browser_open browser_act handoff_to_agent remember)

  # No frozen tool name is external_effect/credential by name alone (Broker.
  @spec classify(String.t()) :: risk()
  def classify(tool_name) when tool_name in @read, do: :read
  def classify(tool_name) when tool_name in @write_local, do: :write_local
  def classify(_tool_name), do: :write_local

  @spec decision(risk(), String.t(), String.t(), map()) :: outcome()
  def decision(:read, _tool_name, _autonomy_mode, _approval_rules), do: :run
  def decision(:credential, _tool_name, _autonomy_mode, _approval_rules), do: :ask_user

  def decision(:write_local, _tool_name, mode, _rules) when mode in ["full_auto", "safe_auto"],
    do: :run

  def decision(:write_local, _tool_name, mode, _rules) when mode in ["manual", "draft_first"],
    do: :plan_only

  def decision(:write_local, _tool_name, _mode, _rules), do: :approval

  def decision(:external_effect, _tool_name, mode, _rules) when mode in ["manual", "draft_first"],
    do: :plan_only

  def decision(:external_effect, tool_name, "full_auto", rules) do
    if allowlisted?(rules, tool_name), do: :run, else: :approval
  end

  def decision(:external_effect, _tool_name, _mode, _rules), do: :approval

  defp allowlisted?(%{"allow" => allow}, tool_name) when is_list(allow),
    do: tool_name in allow

  defp allowlisted?(_rules, _tool_name), do: false
end
