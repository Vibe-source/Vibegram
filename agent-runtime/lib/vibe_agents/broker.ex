defmodule VibeAgents.Broker do
  @moduledoc """
  Deterministic capability broker (spec §3.9). Runs before every tool call and decides
  `:run | {:approval, request} | {:ask, questions} | {:deny, reason}`. Never reads a prompt
  for policy — only `run.agent_profile` (autonomyMode, approvalRules, enabledTools).
  """

  @external_effect_command ~r/\b(mail|sendmail|curl\s+.*-X\s?(POST|PUT|DELETE)|git\s+push|npm\s+publish|rm\s+-rf)\b/i
  @external_effect_action ~r/pay|buy|purchase|checkout|send|submit|delete|publish|confirm\s*order/i
  @credential_hint ~r/password|passwd|2fa|otp|one[\s-]?time\s*code|captcha|verification\s*code|security\s*code/i

  # No approval round-trip is worth offering for these:
  @never_run ~r{rm\s+(-[a-zA-Z]+\s+)*(/|/\*|~|~/\*)(\s|$)|mkfs[. ]|dd\s+[^|]*of=/dev/|>\s*/dev/(sd|nvme|hd)|(shutdown|reboot|poweroff)\s|:\(\)\s*\{\s*:}i

  @doc """
  run: %VibeAgents.Schemas.AgentRun{} or a map with agent_profile/agentProfile. `ask_user`
  is NOT special-cased here — it is always `:run`; the tool itself owns the decision row and
  the terminal "waiting_for_user" result (`VibeAgents.Tools.AskUser`), exactly like the core.
  """
  def authorize(run, tool_name, input) when is_binary(tool_name) do
    input = input || %{}

    cond do
      never_run?(tool_name, input) ->
        {:deny, "this would destroy the machine you are working on"}

      tool_name == "request_approval" ->
        approval_for_claimed_risk(run, input)

      rule_matches?(run, "deny", tool_name, input) ->
        {:deny, "a rule on this agent forbids that"}

      rule_matches?(run, "always_ask", tool_name, input) ->
        {:approval, generic_request(tool_name, input, "external_effect")}

      true ->
        authorize_by_risk(run, tool_name, input)
    end
  end

  def authorize(_run, _tool_name, _input), do: {:deny, "unknown tool"}

  @computer_tools VibeAgents.Tools.Catalog.computer_tools()
  @browser_tools VibeAgents.Tools.Catalog.browser_tools()

  @doc """
  Capability a tool needs the run's sandbox for, or nil. Not part of `authorize/3`'s frozen
  return shape — used by `VibeAgents.Tools.Executor` to gate first use with a `run.permission
  .requested` decision (kind "permission") instead of an approval, since §3.9's table has no
  row for it.
  """
  def required_capability(tool_name) when tool_name in @computer_tools, do: "computer"
  def required_capability(tool_name) when tool_name in @browser_tools, do: "browser"
  def required_capability(_tool_name), do: nil

  @doc "Full_auto/safe_auto auto-grant capability use; other modes gate the first call."
  def auto_grant_capability?(run), do: autonomy_mode(run) in ["full_auto", "safe_auto"]

  def permission_request(capability, reason) do
    %{"capability" => capability, "scope" => "run", "reason" => reason}
  end

  defp approval_for_claimed_risk(run, input) do
    claimed = to_string(input["risk"] || input[:risk] || "external_effect")

    if claimed in ["write_local", "read"] and autonomy_mode(run) in ["full_auto", "safe_auto"],
      do: :run,
      else: {:approval, approval_request_from_input(input)}
  end

  defp authorize_by_risk(run, tool_name, input) do
    risk = risk_class(tool_name, input)
    mode = autonomy_mode(run)

    case {risk, mode} do
      {:read, _mode} ->
        :run

      {:credential, _mode} ->
        {:ask, [%{"question" => "This step needs a credential I must not handle myself. What should I do?", "header" => "Credential", "multiSelect" => false, "options" => [%{"label" => "Skip this step"}, %{"label" => "Tell me what to do"}]}]}

      {:write_local, mode} when mode in ["full_auto", "safe_auto"] ->
        :run

      {:write_local, "approval_required"} ->
        {:approval, generic_request(tool_name, input, "write_local")}

      {:write_local, _manual_or_draft} ->
        {:approval, generic_request(tool_name, input, "write_local")}

      {:external_effect, "full_auto"} ->
        if tool_name in allowlisted_tools(run),
          do: :run,
          else: {:approval, generic_request(tool_name, input, "external_effect")}

      {:external_effect, _mode} ->
        {:approval, generic_request(tool_name, input, "external_effect")}
    end
  end

  @doc "Tool → risk class, including the browser_act / computer_run content heuristics."
  def risk_class(tool_name, input \\ %{})

  def risk_class(tool_name, _input)
      when tool_name in [
             "search_google",
             "read_url",
             "computer_read_file",
             "computer_list_files",
             "browser_screenshot",
             "browser_read_page",
             "recall",
             "ask_user"
           ],
      do: :read

  def risk_class("computer_write_file", _input), do: :write_local
  def risk_class("computer_edit_file", _input), do: :write_local
  def risk_class("browser_open", _input), do: :write_local
  def risk_class("handoff_to_agent", _input), do: :write_local
  def risk_class("remember", _input), do: :write_local

  def risk_class("computer_run", input) do
    if Regex.match?(@external_effect_command, to_string(command_of(input))),
      do: :external_effect,
      else: :write_local
  end

  def risk_class("browser_act", input) do
    text = to_string(input["text"] || input[:text] || "")
    selector = to_string(input["selector"] || input[:selector] || "")

    cond do
      Regex.match?(@credential_hint, text) or Regex.match?(@credential_hint, selector) -> :credential
      Regex.match?(@external_effect_action, text) or Regex.match?(@external_effect_action, selector) -> :external_effect
      true -> :write_local
    end
  end

  def risk_class(_tool_name, _input), do: :write_local

  defp autonomy_mode(run) do
    profile(run)["autonomyMode"] || profile(run)[:autonomyMode] || "approval_required"
  end

  defp allowlisted_tools(run), do: rule_list(run, "allow")

  defp rule_list(run, key) do
    rules = profile(run)["approvalRules"] || profile(run)[:approvalRules] || %{}
    (rules[key] || rules[String.to_atom(key)] || []) |> List.wrap() |> Enum.map(&to_string/1)
  end

  defp rule_matches?(run, key, tool_name, input) do
    haystack = String.downcase(tool_name <> " " <> input_preview(input))

    Enum.any?(rule_list(run, key), fn rule ->
      rule == tool_name or (byte_size(rule) > 2 and String.contains?(haystack, String.downcase(rule)))
    end)
  end

  defp never_run?(tool_name, input) when tool_name in ["computer_run"] do
    Regex.match?(@never_run, to_string(command_of(input)))
  end

  defp never_run?(_tool_name, _input), do: false

  defp command_of(input) do
    input["command"] || input[:command] || input["cmd"] || input[:cmd] || input["code"] || input[:code] || ""
  end

  defp profile(%{agent_profile: profile}) when is_map(profile), do: profile
  defp profile(%{"agent_profile" => profile}) when is_map(profile), do: profile
  defp profile(%{agentProfile: profile}) when is_map(profile), do: profile
  defp profile(_run), do: %{}

  defp generic_request(tool_name, input, risk) do
    %{
      "title" => request_title(tool_name, input),
      "detail" => request_detail(tool_name, input),
      "risk" => risk,
      "tool" => tool_name,
      "actions" => [
        %{"id" => "approve", "label" => "Allow once", "style" => "primary", "confirm" => nil},
        %{"id" => "approve_always", "label" => "Always allow", "style" => "secondary", "confirm" => nil},
        %{"id" => "reject", "label" => "Deny", "style" => "destructive", "confirm" => nil}
      ],
      "actionMode" => "single"
    }
  end

  defp request_title("computer_run", _input), do: "Run a command on the computer?"
  defp request_title("browser_open", input), do: "Open #{host_of(input["url"] || input[:url])}?"
  defp request_title("browser_act", input), do: "#{input["action"] || input[:action] || "Act"} in the browser?"
  defp request_title("computer_write_file", input), do: "Write #{path_of(input)}?"
  defp request_title("computer_edit_file", input), do: "Edit #{path_of(input)}?"
  defp request_title("handoff_to_agent", input), do: "Hand off to @#{input["username"] || input[:username] || "another agent"}?"
  defp request_title(tool_name, _input), do: "Allow #{tool_name}?"

  defp request_detail("computer_run", input), do: input |> command_of() |> to_string() |> String.slice(0, 600)
  defp request_detail("browser_open", input), do: to_string(input["url"] || input[:url] || "")
  defp request_detail(_tool_name, input), do: input_preview(input)

  defp path_of(input), do: to_string(input["path"] || input[:path] || "a file")

  defp host_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> url
    end
  end

  defp host_of(_url), do: "a page"

  defp approval_request_from_input(input) do
    %{
      "title" => input["title"] || input[:title] || "Approve this action?",
      "detail" => input["detail"] || input[:detail] || "",
      "risk" => input["risk"] || input[:risk] || "external_effect",
      "actions" => [
        %{"id" => "approve", "label" => "Allow once", "style" => "primary", "confirm" => nil},
        %{"id" => "approve_always", "label" => "Always allow", "style" => "secondary", "confirm" => nil},
        %{"id" => "reject", "label" => "Deny", "style" => "destructive", "confirm" => nil}
      ],
      "actionMode" => "single"
    }
  end

  defp input_preview(input) do
    input |> Jason.encode!() |> String.slice(0, 300)
  rescue
    _ -> ""
  end
end
