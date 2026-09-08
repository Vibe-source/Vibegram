defmodule VibeAgents.OutboxTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import VibeAgents.Test.Fixtures, only: [uuid: 0]

  alias VibeAgents.Outbox
  alias VibeAgents.Repo
  alias VibeAgents.Schemas.OutboxEvent
  alias VibeAgents.Test.FakeCoreHTTP

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    FakeCoreHTTP.reset()
    :ok
  end

  test "a run holding a deferred row does not ship its later rows first" do
    stalled = uuid()
    healthy = uuid()
    now = now()

    insert!(stalled, 1, DateTime.add(now, 60, :second))
    insert!(stalled, 2, now)
    insert!(healthy, 1, now)

    Outbox.flush_now()

    refute delivered?(stalled, 1)
    refute delivered?(stalled, 2)
    assert delivered?(healthy, 1)
  end

  test "the stalled run drains in seq order once its backoff expires" do
    run = uuid()
    now = now()

    insert!(run, 1, DateTime.add(now, 60, :second))
    insert!(run, 2, now)

    Outbox.flush_now()
    refute delivered?(run, 1)

    ready(run, 1, DateTime.add(now, -1, :second))
    Outbox.flush_now()

    assert delivered?(run, 1)
    assert delivered?(run, 2)
    assert [%{body: %{"events" => [%{"seq" => 1}, %{"seq" => 2}]}}] = FakeCoreHTTP.calls_to("/agent-events")
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp insert!(run_id, seq, next_attempt_at) do
    %OutboxEvent{}
    |> OutboxEvent.changeset(%{
      run_id: run_id,
      seq: seq,
      body: %{"runId" => run_id, "seq" => seq, "kind" => "run.text.delta"},
      next_attempt_at: next_attempt_at
    })
    |> Repo.insert!()
  end

  defp ready(run_id, seq, at) do
    OutboxEvent
    |> where([o], o.run_id == ^run_id and o.seq == ^seq)
    |> Repo.update_all(set: [next_attempt_at: at])
  end

  defp delivered?(run_id, seq) do
    OutboxEvent
    |> where([o], o.run_id == ^run_id and o.seq == ^seq)
    |> select([o], not is_nil(o.delivered_at))
    |> Repo.one!()
  end
end
