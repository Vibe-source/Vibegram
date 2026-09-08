defmodule VibeAgents.Runs.ResumerTest do
  use ExUnit.Case, async: false

  import VibeAgents.Test.Fixtures

  alias VibeAgents.Repo
  alias VibeAgents.Runs.Resumer
  alias VibeAgents.Schemas.AgentRun
  alias VibeAgents.Test.FakeCoreHTTP

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(VibeAgents.Runs.Supervisor), is_pid(pid) do
      DynamicSupervisor.terminate_child(VibeAgents.Runs.Supervisor, pid)
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    FakeCoreHTTP.reset()
    :ok
  end

  test "a queued run stranded at boot is re-armed" do
    run = insert_run!()
    assert run.status == "queued"

    Resumer.run()

    eventually(fn -> Repo.get(AgentRun, run.id).status == "completed" end)
  end
end
