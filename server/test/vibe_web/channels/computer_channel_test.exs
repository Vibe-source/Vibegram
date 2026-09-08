defmodule VibeWeb.ComputerChannelTest.Serializer do
  @moduledoc false
  def encode!(msg), do: msg
  def fastlane!(msg), do: msg
end

defmodule VibeWeb.ComputerChannelTest do
  @moduledoc "Owner-only join, the per-channel frame poller, and the 20/s input drop."

  use ExUnit.Case, async: false

  alias Vibe.Accounts.User
  alias Vibe.Agent
  alias Vibe.Repo
  alias VibeWeb.ComputerChannel

  @key String.duplicate("c", 40)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    System.put_env("VIBE_AGENT_RUNTIME_URL", "http://runtime.test")
    System.put_env("VIBE_INTERNAL_HMAC_KEY", @key)
    stub(fn _method, _url, _headers, _body -> {:ok, %{status: 200, body: "{}"}} end)

    on_exit(fn ->
      System.delete_env("VIBE_AGENT_RUNTIME_URL")
      System.delete_env("VIBE_INTERNAL_HMAC_KEY")
      Application.delete_env(:vibe, :agent_gateway_http)
    end)

    owner = insert_user("cc_owner")
    stranger = insert_user("cc_stranger")
    agent = insert_agent(owner)
    %{owner: owner, stranger: stranger, agent: agent}
  end

  test "a non-owner is rejected from computer:<agentId>", %{agent: agent, stranger: stranger} do
    assert {:error, %{reason: "unauthorized"}} =
             ComputerChannel.join("computer:#{agent.id}", %{"sessionId" => "s-1"}, socket_for(stranger.id))
  end

  test "join is rejected without a sessionId and without a user", %{agent: agent, owner: owner} do
    assert {:error, %{reason: "unauthorized"}} =
             ComputerChannel.join("computer:#{agent.id}", %{}, socket_for(owner.id))

    assert {:error, %{reason: "unauthorized"}} =
             ComputerChannel.join("computer:#{agent.id}", %{"sessionId" => "s-1"}, socket_for(nil))
  end

  test "the owner joins and gets the topic and fps back", %{agent: agent, owner: owner} do
    assert {:ok, reply, socket} =
             ComputerChannel.join("computer:#{agent.id}", %{"sessionId" => "s-1"}, socket_for(owner.id))

    assert reply["topic"] == "computer:#{agent.id}"
    assert reply["fps"] > 0
    assert socket.assigns.session_id == "s-1"
    assert socket.assigns.seq == 0
  end

  test "a 204 poll pushes nothing and keeps polling", %{agent: agent, owner: owner} do
    test_pid = self()
    stub(fn _m, url, _h, _b -> send(test_pid, {:frame, url}) && {:ok, %{status: 204, body: ""}} end)

    {:ok, _reply, socket} = join_as(agent, owner)
    assert {:noreply, socket} = ComputerChannel.handle_info(:poll, socket)

    assert_receive {:frame, url}
    assert url =~ "/computer/frame?since=0"
    assert socket.assigns.seq == 0
    refute_receive %Phoenix.Socket.Message{}, 50
  end

  test "a new frame is pushed once and advances the seq", %{agent: agent, owner: owner} do
    frame = %{"seq" => 9, "imageBase64" => "AAA", "mime" => "image/jpeg", "width" => 720, "height" => 540, "url" => "https://x.test", "title" => "X", "loading" => false, "control" => "agent"}
    stub(fn _m, _url, _h, _b -> {:ok, %{status: 200, body: Jason.encode!(frame)}} end)

    {:ok, _reply, socket} = join_as(agent, owner)
    assert {:noreply, socket} = ComputerChannel.handle_info(:poll, socket)

    assert_receive %Phoenix.Socket.Message{event: "frame", payload: payload}
    assert payload["seq"] == 9
    assert payload["imageBase64"] == "AAA"
    assert payload["url"] == "https://x.test"
    assert payload["control"] == "agent"
    assert socket.assigns.seq == 9
  end

  test "a gone session ends the channel", %{agent: agent, owner: owner} do
    stub(fn _m, _url, _h, _b -> {:ok, %{status: 404, body: Jason.encode!(%{"reason" => "idle"})}} end)

    {:ok, _reply, socket} = join_as(agent, owner)
    assert {:stop, :normal, _socket} = ComputerChannel.handle_info(:poll, socket)
    assert_receive %Phoenix.Socket.Message{event: "session_ended", payload: %{"reason" => "idle"}}
  end

  test "repeated errors end the channel rather than polling forever", %{agent: agent, owner: owner} do
    stub(fn _m, _url, _h, _b -> {:error, :unreachable} end)

    {:ok, _reply, socket} = join_as(agent, owner)
    assert {:noreply, socket} = ComputerChannel.handle_info(:poll, socket)
    assert {:noreply, socket} = ComputerChannel.handle_info(:poll, socket)
    assert {:stop, :normal, _socket} = ComputerChannel.handle_info(:poll, socket)
    assert_receive %Phoenix.Socket.Message{event: "session_ended", payload: %{"reason" => "error"}}
  end

  test "input is capped at 20/s and the excess is dropped, never queued", %{agent: agent, owner: owner} do
    test_pid = self()
    stub(fn _m, url, _h, body -> send(test_pid, {:call, url, body}) && {:ok, %{status: 200, body: "{}"}} end)

    {:ok, _reply, socket} = join_as(agent, owner)

    Enum.reduce(1..30, socket, fn _i, acc ->
      assert {:noreply, acc} = ComputerChannel.handle_in("input", %{"kind" => "click", "x" => 1, "y" => 2}, acc)
      acc
    end)

    assert drain_input_calls() == 20
    refute_receive {:call, _, _}, 100
  end

  test "control maps take → grant, carries the sessionId, and pushes state", %{agent: agent, owner: owner} do
    test_pid = self()

    stub(fn _m, url, _h, body ->
      send(test_pid, {:call, url, body})
      {:ok, %{status: 200, body: Jason.encode!(%{"control" => "user", "holder" => "s-1", "expiresAt" => "2026-09-01T00:00:00Z"})}}
    end)

    {:ok, _reply, socket} = join_as(agent, owner)
    assert {:noreply, _socket} = ComputerChannel.handle_in("control", %{"action" => "take", "ttlSeconds" => 300}, socket)

    assert_receive {:call, url, body}
    assert url =~ "/computer/control"
    decoded = Jason.decode!(body)
    assert decoded["action"] == "grant"
    assert decoded["sessionId"] == "s-1"
    assert decoded["ttlSeconds"] == 300

    assert_receive %Phoenix.Socket.Message{event: "state", payload: payload}
    assert payload["control"] == "user"
    assert payload["holder"] == "s-1"
  end

  test "terminate closes the gateway session", %{agent: agent, owner: owner} do
    test_pid = self()
    stub(fn method, url, _h, _b -> send(test_pid, {:call, method, url}) && {:ok, %{status: 200, body: "{}"}} end)

    {:ok, _reply, socket} = join_as(agent, owner)
    assert :ok = ComputerChannel.terminate(:normal, socket)
    assert_receive {:call, :delete, url}
    assert url =~ "/computer/session/s-1"
  end

  defp join_as(agent, owner) do
    ComputerChannel.join("computer:#{agent.id}", %{"sessionId" => "s-1"}, socket_for(owner.id))
  end

  defp stub(fun), do: Application.put_env(:vibe, :agent_gateway_http, fun)

  defp drain_input_calls(count \\ 0) do
    receive do
      {:call, url, _body} -> if String.contains?(url, "/computer/input"), do: drain_input_calls(count + 1), else: drain_input_calls(count)
    after
      0 -> count
    end
  end

  defp socket_for(user_id) do
    %Phoenix.Socket{
      assigns: %{user_id: user_id},
      topic: "computer:test",
      transport_pid: self(),
      serializer: VibeWeb.ComputerChannelTest.Serializer,
      joined: true
    }
  end

  defp insert_user(prefix) do
    suffix = System.unique_integer([:positive])

    Repo.insert!(%User{
      id: Ecto.UUID.generate(),
      username: "#{prefix}_#{suffix}",
      password_hash: "hash",
      public_key: "key",
      device_id: "device-#{suffix}",
      name: "CC"
    })
  end

  defp insert_agent(owner) do
    shadow =
      Repo.insert!(%User{
        id: Ecto.UUID.generate(),
        username: "ccagent_#{System.unique_integer([:positive])}",
        password_hash: "hash",
        public_key: "key",
        device_id: "d",
        is_agent: true,
        name: "Bot"
      })

    Repo.insert!(%Agent{
      owner_user_id: owner.id,
      agent_user_id: shadow.id,
      status: "published",
      display_name: "Computer Bot",
      enabled_tools: ["browser_open"],
      output_modes: ["text"],
      webhook_secret_hash: "hash",
      secret_hint: "hint"
    })
  end
end
