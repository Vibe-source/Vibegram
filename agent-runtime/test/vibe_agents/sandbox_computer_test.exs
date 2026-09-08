defmodule VibeAgents.SandboxComputerTest do
  @moduledoc "agent-id-facing computer wrappers: sandbox lookup, last_used_at, passthrough."
  use ExUnit.Case, async: false

  alias VibeAgents.Repo
  alias VibeAgents.Sandbox
  alias VibeAgents.Schemas.AgentComputer
  alias VibeAgents.Test.FakeSandboxHTTP

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    FakeSandboxHTTP.reset()
    Application.put_env(:vibe_agents, :sandbox_gateway_url, "http://gateway.test")
    Application.put_env(:vibe_agents, :sandbox_gateway_token, String.duplicate("t", 40))

    on_exit(fn ->
      FakeSandboxHTTP.reset()
      Application.delete_env(:vibe_agents, :sandbox_gateway_url)
      Application.delete_env(:vibe_agents, :sandbox_gateway_token)
    end)

    %{agent_id: Ecto.UUID.generate()}
  end

  defp with_computer(agent_id, last_used_at) do
    %AgentComputer{}
    |> AgentComputer.changeset(%{agent_id: agent_id, sandbox_id: "sb-9", status: "running", last_used_at: last_used_at})
    |> Repo.insert!()
  end

  test "every call but session is :not_available while the agent has no sandbox row", %{agent_id: agent_id} do
    assert Sandbox.close_computer_session(agent_id, "s-1") == {:error, :not_available}
    assert Sandbox.computer_frame(agent_id, 3) == {:error, :not_available}
    assert Sandbox.computer_state(agent_id) == {:error, :not_available}
    assert Sandbox.computer_control(agent_id, %{"action" => "grant"}) == {:error, :not_available}
    assert Sandbox.computer_input(agent_id, %{"kind" => "click"}) == {:error, :not_available}
    assert FakeSandboxHTTP.calls() == []
  end

  # Opening the sheet is how a cold agent gets a computer.
  test "opening a session creates the sandbox when the agent has never browsed", %{agent_id: agent_id} do
    assert {:ok, _} = Sandbox.computer_session(agent_id, %{"viewerId" => "u1"})

    assert %AgentComputer{sandbox_id: sandbox_id} = Repo.get_by(AgentComputer, agent_id: agent_id)
    assert is_binary(sandbox_id)

    assert Enum.any?(FakeSandboxHTTP.calls(), &String.ends_with?(&1.url, "/v1/sandboxes"))
  end

  test "opening a session touches last_used_at so the idle reaper leaves a watched sandbox alone", %{agent_id: agent_id} do
    stale = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    with_computer(agent_id, stale)

    assert {:ok, _} = Sandbox.computer_session(agent_id, %{"viewerId" => "u1"})

    computer = Repo.get_by!(AgentComputer, agent_id: agent_id)
    assert DateTime.compare(computer.last_used_at, stale) == :gt
  end

  test "frame carries since and session to the gateway and hands back :no_change untouched", %{agent_id: agent_id} do
    with_computer(agent_id, DateTime.utc_now() |> DateTime.truncate(:second))
    FakeSandboxHTTP.stub(fn :get, _url, _body -> {:ok, :no_change} end)

    assert Sandbox.computer_frame(agent_id, 7, "sess-1") == {:ok, :no_change}

    assert [%{url: url}] = FakeSandboxHTTP.calls()
    assert url == "http://gateway.test/v1/sandboxes/sb-9/computer/frame?since=7&session=sess-1"
  end

  test "an input rejection keeps the gateway's 409", %{agent_id: agent_id} do
    with_computer(agent_id, DateTime.utc_now() |> DateTime.truncate(:second))
    FakeSandboxHTTP.stub(fn :post, _url, _body -> {:error, {:http_error, 409, ~s({"error":"control_not_held"})}} end)

    assert {:error, {:http_error, 409, _}} = Sandbox.computer_input(agent_id, %{"kind" => "click", "sessionId" => "s-1"})
  end
end
