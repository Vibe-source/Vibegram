defmodule VibeAgents.RetentionTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import VibeAgents.Test.Fixtures, only: [uuid: 0]

  alias VibeAgents.Repo
  alias VibeAgents.Retention
  alias VibeAgents.Schemas.AgentRun
  alias VibeAgents.Schemas.AgentRunEvent
  alias VibeAgents.Schemas.OutboxEvent

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "run_once removes only expired delivered outbox events" do
    now = now()
    insert_outbox!(DateTime.add(now, -10, :day))
    insert_outbox!(DateTime.add(now, -1, :day))
    insert_outbox!(nil, DateTime.add(now, -10, :day))

    assert %{outbox_events: 1} = Retention.run_once()
    assert Repo.aggregate(OutboxEvent, :count) == 2
    assert Repo.aggregate(from(o in OutboxEvent, where: is_nil(o.delivered_at)), :count) == 1
  end

  test "run_once removes events only for expired finished runs" do
    now = now()
    expired = insert_run!("completed", DateTime.add(now, -31, :day))
    recent = insert_run!("completed", DateTime.add(now, -1, :day))
    running = insert_run!("running", nil)

    insert_run_event!(expired, 1)
    insert_run_event!(recent, 1)
    insert_run_event!(running, 1)

    assert %{agent_run_events: 1} = Retention.run_once()
    assert Repo.aggregate(AgentRunEvent, :count) == 2
    assert Repo.aggregate(AgentRun, :count) == 3
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp insert_outbox!(delivered_at, next_attempt_at \\ nil) do
    run_id = uuid()

    %OutboxEvent{}
    |> OutboxEvent.changeset(%{
      run_id: run_id,
      seq: 1,
      body: %{"runId" => run_id, "seq" => 1, "kind" => "run.text.delta"},
      delivered_at: delivered_at,
      next_attempt_at: next_attempt_at
    })
    |> Repo.insert!()
  end

  defp insert_run!(status, finished_at) do
    id = uuid()

    %AgentRun{}
    |> AgentRun.create_changeset(%{
      id: id,
      agent_id: uuid(),
      agent_user_id: uuid(),
      owner_user_id: uuid(),
      chat_id: "retention-#{id}",
      source: "chat"
    })
    |> Repo.insert!()
    |> AgentRun.update_changeset(%{status: status, finished_at: finished_at})
    |> Repo.update!()
  end

  defp insert_run_event!(run, seq) do
    %AgentRunEvent{}
    |> AgentRunEvent.changeset(%{
      run_id: run.id,
      seq: seq,
      kind: "run.text.delta",
      payload: %{"text" => "x"},
      ts: System.system_time(:millisecond)
    })
    |> Repo.insert!()
  end
end
