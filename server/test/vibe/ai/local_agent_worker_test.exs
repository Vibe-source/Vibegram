defmodule Vibe.AI.LocalAgentWorkerTest do
  use ExUnit.Case, async: false

  alias Vibe.AI.LocalAgentWorker

  test "server output streams before exit and always closes its stream" do
    keys = ["VIBE_LOCAL_AGENT_WORKERS", "VIBE_TEAM_EXECUTOR", "VIBE_TEAM_CLAUDE_COMMAND"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    dir = Path.join(System.tmp_dir!(), "vibe-stream-" <> Ecto.UUID.generate())
    File.mkdir_p!(dir)
    command = Path.join(dir, "worker")
    release = Path.join(dir, "release")

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
      File.rm_rf!(dir)
    end)

    File.write!(command, """
    #!/bin/sh
    printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Working"}]}}'
    while [ ! -f '#{release}' ]; do sleep 0.05; done
    printf '%s\\n' '{"type":"result","result":"Finished"}'
    """)
    File.chmod!(command, 0o700)
    System.put_env("VIBE_LOCAL_AGENT_WORKERS", "1")
    System.put_env("VIBE_TEAM_EXECUTOR", "claude")
    System.put_env("VIBE_TEAM_CLAUDE_COMMAND", command)

    unless Process.whereis(Vibe.PubSub), do: start_supervised!({Phoenix.PubSub, name: Vibe.PubSub})
    unless Process.whereis(VibeWeb.Endpoint), do: start_supervised!(VibeWeb.Endpoint)
    chat_id = Ecto.UUID.generate()
    Phoenix.PubSub.subscribe(Vibe.PubSub, "chat:#{chat_id}")
    worker = LocalAgentWorker.workers()["coder"]
    task = Task.async(fn -> LocalAgentWorker.run(worker, "Test", chat_id: chat_id) end)

    assert_receive %Phoenix.Socket.Broadcast{
      event: "agent-stream",
      payload: %{"status" => "running", "streamId" => stream_id, "agentUserId" => agent_id, "text" => "Working"}
    }, 3_000
    assert agent_id == worker.agent_user_id
    assert Task.yield(task, 0) == nil
    File.write!(release, "")
    assert {:ok, %{ok: true}} = Task.await(task, 3_000)
    assert_receive %Phoenix.Socket.Broadcast{
      event: "agent-stream", payload: %{"status" => "done", "streamId" => ^stream_id}
    }, 1_000
  end


  test "pick_supervisor_lead prefers Claude when it is in the team" do
    codex = %{handle: "codex"}
    claude = %{handle: "claude"}

    assert ^claude = LocalAgentWorker.pick_supervisor_lead([codex, claude])
  end

  test "pick_supervisor_lead preserves the existing fallback order without Claude" do
    grok = %{handle: "grok"}
    codex = %{handle: "codex"}

    assert ^codex = LocalAgentWorker.pick_supervisor_lead([grok, codex])
  end
end
