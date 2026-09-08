Code.require_file("support/test_infra.ex", __DIR__)
Code.require_file("support/fake_provider.ex", __DIR__)

defmodule VibeAgents.Voice.SessionTest do
  use ExUnit.Case, async: false

  alias VibeAgents.Voice.{FakeProvider, Session}

  setup_all do
    VibeAgents.Voice.TestInfra.ensure_started!()
    :ok
  end

  setup do
    previous = Application.get_env(:vibe_agents, :voice_provider)
    previous_max = Application.get_env(:vibe_agents, :voice_max_seconds)
    Application.put_env(:vibe_agents, :voice_provider, FakeProvider)
    Application.put_env(:vibe_agents, :voice_max_seconds, 1800)

    on_exit(fn ->
      restore(:voice_provider, previous)
      restore(:voice_max_seconds, previous_max)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:vibe_agents, key)
  defp restore(key, value), do: Application.put_env(:vibe_agents, key, value)

  defp record(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: Ecto.UUID.generate(),
        agent_id: "agent-1",
        user_id: "user-1",
        chat_id: "chat-1",
        agent_profile: %{"displayName" => "Vee", "autonomyMode" => "approval_required"}
      },
      overrides
    )
  end

  defp join!(record) do
    {:ok, pid} = Session.join(record.session_id, record, self())
    provider_pid = :sys.get_state(pid).provider_pid
    {pid, provider_pid}
  end

  test "join starts the provider; session.ready is pushed once it's ready" do
    join!(record())
    assert_receive {:voice_frame, "session.ready", %{sessionId: _sid, sampleRate: 24_000}}, 1_000
  end

  test "a 16k audio.chunk is resampled up before being forwarded to the provider" do
    {pid, provider_pid} = join!(record())
    assert_receive {:voice_frame, "session.ready", _payload}, 1_000

    raw = for(s <- [0, 1_000, 2_000], into: <<>>, do: <<s::16-signed-little>>)

    GenServer.cast(
      pid,
      {:frame, "audio.chunk", %{"seq" => 1, "sampleRate" => 16_000, "dataBase64" => Base.encode64(raw)}}
    )

    :sys.get_state(pid)
    assert [{:send_audio, [pcm16]}] = FakeProvider.get_calls(provider_pid)
    assert byte_size(pcm16) > byte_size(raw)
  end

  test "a 24k audio.chunk is forwarded unresampled" do
    {pid, provider_pid} = join!(record())
    assert_receive {:voice_frame, "session.ready", _payload}, 1_000

    raw = for(s <- [0, 1_000, 2_000], into: <<>>, do: <<s::16-signed-little>>)

    GenServer.cast(
      pid,
      {:frame, "audio.chunk", %{"seq" => 1, "sampleRate" => 24_000, "dataBase64" => Base.encode64(raw)}}
    )

    :sys.get_state(pid)
    assert [{:send_audio, [^raw]}] = FakeProvider.get_calls(provider_pid)
  end

  test "interrupt is forwarded to the provider" do
    {pid, provider_pid} = join!(record())
    assert_receive {:voice_frame, "session.ready", _payload}, 1_000

    GenServer.cast(pid, {:frame, "interrupt", %{}})
    :sys.get_state(pid)

    assert [{:interrupt, []}] = FakeProvider.get_calls(provider_pid)
  end

  test "a read-class tool call runs immediately (no approval frame) and reports a result" do
    {pid, provider_pid} = join!(record())
    assert_receive {:voice_frame, "session.ready", _payload}, 1_000

    FakeProvider.emit(provider_pid, {:tool_call, "call-1", "search_google", %{"q" => "elixir"}})

    assert_receive {:voice_frame, "tool.progress", %{status: "running", tool: "search_google"}}, 1_000
    refute_receive {:voice_frame, "approval.requested", _payload}, 100
    assert_receive {:voice_frame, "tool.progress", %{status: status}}, 1_000
    assert status in ["done", "error"]

    :sys.get_state(pid)
    assert [{:tool_result, ["call-1", _result]}] = FakeProvider.get_calls(provider_pid)
  end

  test "a write_local call under approval_required asks first, then runs once approved" do
    {pid, provider_pid} = join!(record())
    assert_receive {:voice_frame, "session.ready", _payload}, 1_000

    FakeProvider.emit(provider_pid, {:tool_call, "call-2", "computer_run", %{"cmd" => "ls"}})

    assert_receive {:voice_frame, "tool.progress", %{status: "running", tool: "computer_run"}}, 1_000
    assert_receive {:voice_frame, "approval.requested", %{decisionId: decision_id} = request}, 1_000
    assert request.title =~ "command" and request.tool == "computer_run"

    GenServer.cast(pid, {:frame, "decision", %{"decisionId" => decision_id, "outcome" => "approve"}})

    assert_receive {:voice_frame, "tool.progress", %{status: "running", tool: "computer_run"}}, 1_000
    assert_receive {:voice_frame, "tool.progress", %{status: _status}}, 1_000

    :sys.get_state(pid)
    assert [{:tool_result, ["call-2", _result]}] = FakeProvider.get_calls(provider_pid)
  end

  test "rejecting a decision denies the tool without executing it" do
    {pid, provider_pid} = join!(record())
    assert_receive {:voice_frame, "session.ready", _payload}, 1_000

    FakeProvider.emit(provider_pid, {:tool_call, "call-3", "computer_write_file", %{"path" => "x"}})
    assert_receive {:voice_frame, "approval.requested", %{decisionId: decision_id}}, 1_000

    GenServer.cast(pid, {:frame, "decision", %{"decisionId" => decision_id, "outcome" => "reject"}})

    assert_receive {:voice_frame, "tool.progress", %{status: "error"}}, 1_000
    :sys.get_state(pid)

    assert [{:tool_result, ["call-3", %{"error" => "denied_by_user"}]}] = FakeProvider.get_calls(provider_pid)
  end

  test "a decision with an unknown decisionId reports an error, not a crash" do
    {pid, _provider_pid} = join!(record())
    assert_receive {:voice_frame, "session.ready", _payload}, 1_000

    GenServer.cast(pid, {:frame, "decision", %{"decisionId" => "ghost", "outcome" => "approve"}})

    assert_receive {:voice_frame, "error", %{code: "unknown_decision"}}, 1_000
    assert Process.alive?(pid)
  end

  test "hangup stops the provider and ends the session" do
    {pid, provider_pid} = join!(record())
    assert_receive {:voice_frame, "session.ready", _payload}, 1_000

    ref = Process.monitor(pid)
    GenServer.cast(pid, {:frame, "hangup", %{}})

    assert_receive {:voice_frame, "session.ended", %{reason: "hangup"}}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert [{:stop, []}] = FakeProvider.get_calls(provider_pid)
  end

  test "the session ends itself when VIBE_VOICE_MAX_SECONDS elapses" do
    Application.put_env(:vibe_agents, :voice_max_seconds, 0)
    {pid, _provider_pid} = join!(record())

    ref = Process.monitor(pid)
    assert_receive {:voice_frame, "session.ended", %{reason: "max_duration"}}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end
end
