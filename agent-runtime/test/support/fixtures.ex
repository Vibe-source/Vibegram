defmodule VibeAgents.Test.Fixtures do
  @moduledoc "Minimal RunRequest / run-row builders for runtime tests."

  alias VibeAgents.Repo
  alias VibeAgents.Schemas.AgentRun

  def uuid, do: Ecto.UUID.generate()

  def agent_profile(overrides \\ %{}) do
    Map.merge(
      %{
        "displayName" => "Test Agent",
        "username" => "testagent",
        "systemPrompt" => "You are a test agent.",
        "modelProvider" => "anthropic",
        "modelId" => "claude-sonnet-5",
        "thinkingLevel" => "medium",
        "enabledTools" => ["search_google", "read_url"],
        "outputModes" => ["text"],
        "autonomyMode" => "safe_auto",
        "approvalRules" => %{},
        "budgets" => %{"dailyCents" => nil, "monthlyCents" => nil},
        "adminMode" => false
      },
      overrides
    )
  end

  def run_request(overrides \\ %{}) do
    Map.merge(
      %{
        "source" => "chat",
        "agentId" => uuid(),
        "agentUserId" => uuid(),
        "ownerUserId" => uuid(),
        "requesterUserId" => uuid(),
        "chatId" => "chat-" <> uuid(),
        "chatKind" => "dm",
        "replyToId" => nil,
        "input" => %{"text" => "hello", "attachments" => []},
        "agentProfile" => agent_profile(),
        "context" => %{"history" => [], "participants" => []},
        "capabilities" => %{"computer" => false, "browser" => false, "network" => "none"}
      },
      overrides
    )
  end

  @doc "Inserts a run row directly (no server process) for unit tests of contexts/tools."
  def insert_run!(overrides \\ %{}) do
    req = run_request(overrides)

    %AgentRun{}
    |> AgentRun.create_changeset(%{
      agent_id: req["agentId"],
      agent_user_id: req["agentUserId"],
      owner_user_id: req["ownerUserId"],
      requester_user_id: req["requesterUserId"],
      chat_id: req["chatId"],
      chat_kind: req["chatKind"],
      source: req["source"],
      input: req["input"],
      agent_profile: req["agentProfile"],
      context: req["context"],
      capabilities: req["capabilities"]
    })
    |> Repo.insert!()
  end

  @doc "Waits up to `timeout_ms` for `fun.()` to return a truthy value."
  def eventually(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk_eventually()
        else
          Process.sleep(25)
          do_eventually(fun, deadline)
        end

      value ->
        value
    end
  end

  defp flunk_eventually, do: raise(ExUnit.AssertionError, message: "condition not met in time")
end
