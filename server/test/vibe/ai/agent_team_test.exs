defmodule Vibe.AI.AgentTeamTest do
  use ExUnit.Case, async: false

  alias Vibe.AI.LocalAgentWorker, as: W

  @allowlist "VIBE_AGENT_WORKER_ALLOWED_USERS"

  setup do
    previous = System.get_env(@allowlist)
    on_exit(fn -> if previous, do: System.put_env(@allowlist, previous), else: System.delete_env(@allowlist) end)
    System.delete_env(@allowlist)
    :ok
  end

  test "every role worker has its own identity, model and server runtime" do
    workers = W.list_role_workers()

    assert Enum.map(workers, & &1.handle) ==
             ["boss", "monitor", "coder", "researcher", "marketing", "social", "media"]

    ids = Enum.map(workers, & &1.agent_user_id)
    assert length(Enum.uniq(ids)) == length(ids)

    for worker <- workers do
      assert W.server_runtime?(worker)
      assert W.executor_for(worker) in ["claude", "codex"]
      assert worker.tier == "gold"
    end
  end

  test "every role carries its own thinking level, and the boss thinks at max" do
    for worker <- W.list_role_workers() do
      assert worker.effort in ["low", "medium", "high", "xhigh", "max"],
             "#{worker.handle} has no thinking level"
    end

    boss = W.resolve_handle("boss")

    assert boss.model == "fable"
    assert boss.fallback_model == "opus"
    assert boss.effort == "max"
  end

  test "a mention can pin the thinking level, and a bare mention does not" do
    [coder] = W.extract_reserved_mentions("@coder [max] ship it")
    assert coder.handle == "coder"
    assert coder.effort_directive == "max"

    [social] = W.extract_reserved_mentions("@social (low) post it")
    assert social.effort_directive == "low"

    bare = W.extract_reserved_mention("@coder ship it")
    assert bare.handle == "coder"
    refute Map.has_key?(bare, :effort_directive)

    # Prose in brackets is not a level, so the mention still resolves on its own.
    [monitor] = W.extract_reserved_mentions("@monitor (DevOps) check the logs")
    assert monitor.handle == "monitor"
    refute Map.has_key?(monitor, :effort_directive)
  end

  test "role workers fail closed: an empty allowlist means nobody" do
    monitor = W.resolve_handle("monitor")

    refute W.dispatch_allowed?(monitor, "anyone")
    refute W.dispatch_allowed?(monitor, nil)

    # A bridge worker keeps the old open-by-default gate, so this is not a regression.
    assert W.dispatch_allowed?(W.resolve_handle("claude"), "anyone")
  end

  test "an allowlisted owner reaches the team and a stranger does not" do
    System.put_env(@allowlist, "owner-1")

    monitor = W.resolve_handle("monitor")

    assert W.dispatch_allowed?(monitor, "owner-1")
    refute W.dispatch_allowed?(monitor, "owner-2")
  end

  test "role handles are addressable as mentions" do
    handles =
      "@monitor take a look, then hand to @coder"
      |> W.extract_reserved_mentions()
      |> Enum.map(& &1.handle)

    assert "monitor" in handles
    assert "coder" in handles
  end

  test "one CLI can stand in for the whole team without changing who anyone is" do
    System.put_env("VIBE_TEAM_EXECUTOR", "grok")
    on_exit(fn -> System.delete_env("VIBE_TEAM_EXECUTOR") end)

    monitor = W.resolve_handle("monitor")

    assert W.executor_for(monitor) == "grok"
    assert monitor.agent_user_id == W.resolve_handle("monitor").agent_user_id
    assert W.executor_for(W.resolve_handle("claude")) == "claude"
  end
end
