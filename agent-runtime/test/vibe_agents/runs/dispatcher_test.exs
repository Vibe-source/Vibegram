defmodule VibeAgents.Runs.DispatcherTest do
  @moduledoc "Admission control: over the cap a run queues instead of starting."

  use ExUnit.Case, async: false

  alias VibeAgents.Runs.Dispatcher

  setup do
    previous = Application.fetch_env(:vibe_agents, :max_concurrent_runs)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:vibe_agents, :max_concurrent_runs, value)
        :error -> Application.delete_env(:vibe_agents, :max_concurrent_runs)
      end
    end)

    :ok
  end

  test "start_or_queue queues instead of starting once the cap is reached" do
    Application.put_env(:vibe_agents, :max_concurrent_runs, 0)

    assert Dispatcher.start_or_queue(Ecto.UUID.generate()) == :queued
  end

  test "max_concurrent reads config and defaults when unset" do
    Application.put_env(:vibe_agents, :max_concurrent_runs, 3)
    assert Dispatcher.max_concurrent() == 3

    Application.delete_env(:vibe_agents, :max_concurrent_runs)
    assert Dispatcher.max_concurrent() == 8
  end

  test "active_count reports live run servers" do
    assert Dispatcher.active_count() == Registry.count(VibeAgents.Runs.Registry)
  end
end
