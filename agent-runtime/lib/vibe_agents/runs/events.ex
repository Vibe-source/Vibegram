defmodule VibeAgents.Runs.Events do
  @moduledoc "Appends one RunEvent for a run: next seq, agent_run_events row, outbox row."
  alias VibeAgents.Repo
  alias VibeAgents.Schemas.{AgentRunEvent, OutboxEvent}
  import Ecto.Query

  @doc "run: %VibeAgents.Schemas.AgentRun{} (or anything with :id/:agent_id/:agent_user_id/:chat_id)."
  def emit(run, kind, payload) when is_binary(kind) and is_map(payload) do
    result =
      Repo.transaction(fn ->
        seq = next_seq(run.id)
        ts = System.system_time(:millisecond)

        {:ok, event} =
          %AgentRunEvent{}
          |> AgentRunEvent.changeset(%{run_id: run.id, seq: seq, kind: kind, payload: payload, ts: ts})
          |> Repo.insert()

        run_event = build_run_event(run, event)

        {:ok, _outbox} =
          %OutboxEvent{}
          |> OutboxEvent.changeset(%{run_id: run.id, seq: seq, body: run_event, next_attempt_at: DateTime.utc_now()})
          |> Repo.insert()

        run_event
      end)

    with {:ok, run_event} <- result do
      VibeAgents.Outbox.notify()
      Phoenix.PubSub.broadcast(VibeAgents.PubSub, "run:" <> run.id, {:run_event, run_event})
    end

    result
  end

  defp next_seq(run_id) do
    case Repo.one(from e in AgentRunEvent, where: e.run_id == ^run_id, select: max(e.seq)) do
      nil -> 1
      max -> max + 1
    end
  end

  defp build_run_event(run, %AgentRunEvent{} = event) do
    {:ok, run_event} =
      VibeContracts.RunEvent.new(%{
        runId: run.id,
        agentId: run.agent_id,
        agentUserId: run.agent_user_id,
        chatId: run.chat_id,
        seq: event.seq,
        ts: event.ts,
        kind: event.kind,
        payload: event.payload
      })

    run_event
  end
end
