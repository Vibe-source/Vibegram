defmodule Vibe.AgentGatewayTest do
  @moduledoc "RunRequest building, execution-mode resolution, kill switch, signed headers."

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.AgentGateway
  alias Vibe.Chat
  alias Vibe.Repo

  @key String.duplicate("k", 40)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    System.put_env("VIBE_AGENT_RUNTIME_URL", "http://runtime.test")
    System.put_env("VIBE_INTERNAL_HMAC_KEY", @key)
    test_pid = self()

    Application.put_env(:vibe, :agent_gateway_http, fn method, url, headers, body ->
      send(test_pid, {:gateway_request, method, url, headers, body})
      {:ok, %{status: 202, body: Jason.encode!(%{"runId" => "run-1", "status" => "queued"})}}
    end)

    on_exit(fn ->
      System.delete_env("VIBE_AGENT_RUNTIME_URL")
      System.delete_env("VIBE_INTERNAL_HMAC_KEY")
      System.delete_env("VIBE_AGENT_EXECUTION_MODE")
      System.delete_env("VIBE_AI_KILL_SWITCH")
      Application.delete_env(:vibe, :agent_gateway_http)
    end)

    owner = insert_user("gw_owner")
    agent = insert_agent(owner)
    {:ok, chat_id, _} = Chat.ensure_dm_chat(owner.id, agent.agent_user_id)
    %{owner: owner, agent: agent, chat_id: chat_id}
  end

  test "execution mode: env override beats the column", %{agent: agent} do
    assert AgentGateway.execution_mode_for(agent) == "embedded"
    assert AgentGateway.execution_mode_for(%{agent | execution_mode: "isolated"}) == "isolated"
    System.put_env("VIBE_AGENT_EXECUTION_MODE", "embedded")
    assert AgentGateway.execution_mode_for(%{agent | execution_mode: "isolated"}) == "embedded"
    System.put_env("VIBE_AGENT_EXECUTION_MODE", "isolated")
    assert AgentGateway.execution_mode_for(agent) == "isolated"
  end

  test "start_run sends a signed RunRequest with the frozen shape", %{agent: agent, owner: owner, chat_id: chat_id} do
    assert {:ok, %{"runId" => "run-1"}} =
             AgentGateway.start_run(%{agent: agent, chat_id: chat_id, requester_user_id: owner.id, text: "hi", attachments: []})

    assert_receive {:gateway_request, :post, "http://runtime.test/internal/v1/runs", headers, body}
    decoded = Jason.decode!(body)

    assert decoded["agentId"] == agent.id
    assert decoded["chatId"] == chat_id
    assert decoded["input"]["text"] == "hi"
    assert decoded["agentProfile"]["displayName"] == agent.display_name
    assert decoded["capabilities"]["computer"] == false

    header_map = Map.new(headers)
    assert header_map["x-vibe-service"] == "core"
    assert :ok = VibeContracts.ServiceAuth.verify(@key, "POST", "/internal/v1/runs", body, header_map)
  end

  test "the kill switch refuses every dispatch", %{agent: agent, chat_id: chat_id} do
    System.put_env("VIBE_AI_KILL_SWITCH", "1")
    assert AgentGateway.kill_switch?()
    assert {:error, :kill_switch} = AgentGateway.start_run(%{agent: agent, chat_id: chat_id, text: "hi"})
    refute_receive {:gateway_request, _, _, _, _}
  end

  test "computer_frame: 204 is :no_change, 200 is the frame", %{agent: agent} do
    Application.put_env(:vibe, :agent_gateway_http, fn :get, url, _headers, _body ->
      if String.contains?(url, "since=7"),
        do: {:ok, %{status: 204, body: ""}},
        else: {:ok, %{status: 200, body: Jason.encode!(%{"seq" => 3, "imageBase64" => "AAA"})}}
    end)

    assert {:ok, :no_change} = AgentGateway.computer_frame(agent.id, since: 7)
    assert {:ok, %{"seq" => 3}} = AgentGateway.computer_frame(agent.id, since: 0)
  end

  test "disabled without a runtime URL" do
    System.delete_env("VIBE_AGENT_RUNTIME_URL")
    refute AgentGateway.enabled?()
    assert {:error, :disabled} = AgentGateway.cancel("run-1", "test", nil)
  end

  defp insert_user(prefix) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      name: "GW"
    })
  end

  defp insert_agent(owner) do
    shadow = Repo.insert!(%User{id: Ecto.UUID.generate(), username: "gwagent_#{System.unique_integer([:positive])}", password_hash: "hash", public_key: "key", device_id: "d", is_agent: true, name: "Bot"})

    Repo.insert!(%Agent{
      owner_user_id: owner.id,
      agent_user_id: shadow.id,
      status: "published",
      display_name: "Gateway Bot",
      enabled_tools: ["search_google"],
      output_modes: ["text"],
      webhook_secret_hash: "hash",
      secret_hint: "hint"
    })
    |> Repo.preload(:agent_user)
  end
end
