defmodule VibeAgents.Runs.JanitorTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import VibeAgents.Test.Fixtures

  alias VibeAgents.Repo
  alias VibeAgents.Runs.Janitor
  alias VibeAgents.Schemas.{AgentRun, AgentRunEvent}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  defp force(run, set) do
    Repo.update_all(from(r in AgentRun, where: r.id == ^run.id), set: set)
  end

  test "an old waiting_ask run is cancelled as expired" do
    run = insert_run!()
    old = DateTime.utc_now() |> DateTime.add(-8 * 86_400, :second) |> DateTime.truncate(:second)
    force(run, status: "waiting_ask", updated_at: old)

    Janitor.sweep()

    updated = Repo.get(AgentRun, run.id)
    assert updated.status == "cancelled"
    assert updated.error == "expired"
    assert updated.finished_at != nil

    assert Enum.any?(Repo.all(AgentRunEvent), fn e ->
             e.run_id == run.id and e.kind == "run.cancelled" and e.payload["reason"] == "expired"
           end)
  end

  test "an old running run with no live server is failed as stale_run" do
    run = insert_run!()
    old_start = DateTime.utc_now() |> DateTime.add(-3000, :second) |> DateTime.truncate(:second)
    force(run, status: "running", started_at: old_start)

    Janitor.sweep()

    updated = Repo.get(AgentRun, run.id)
    assert updated.status == "failed"
    assert updated.error == "stale_run"
    assert updated.finished_at != nil

    assert Enum.any?(Repo.all(AgentRunEvent), fn e ->
             e.run_id == run.id and e.kind == "run.failed" and e.payload["code"] == "stale_run"
           end)
  end

  test "fresh waiting and running rows are left untouched" do
    waiting = insert_run!()
    force(waiting, status: "waiting_approval")

    running = insert_run!()
    force(running, status: "running", started_at: DateTime.utc_now() |> DateTime.truncate(:second))

    Janitor.sweep()

    assert Repo.get(AgentRun, waiting.id).status == "waiting_approval"
    assert Repo.get(AgentRun, running.id).status == "running"
  end
end
