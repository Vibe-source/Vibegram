defmodule VibeAgents.Runs do
  @moduledoc "Public context for starting, cancelling, deciding, and reading agent runs."
  import Ecto.Query
  alias VibeAgents.Repo
  alias VibeAgents.Schemas.{AgentRun, AgentRunEvent}
  alias VibeAgents.Runs.Server

  @doc "Starts a run from a RunRequest map (string keys, wire shape). Idempotent on idempotencyKey."
  def start(run_request) when is_map(run_request) do
    if kill_switch?() do
      {:error, :kill_switch}
    else
      case find_existing(run_request) do
        %AgentRun{} = run ->
          {:ok, run}

        nil ->
          create_and_start(run_request)
      end
    end
  end

  defp find_existing(%{"idempotencyKey" => key}) when is_binary(key) and key != "" do
    Repo.get_by(AgentRun, idempotency_key: key)
  end

  defp find_existing(_run_request), do: nil

  defp create_and_start(run_request) do
    attrs = %{
      id: run_request["runId"],
      agent_id: run_request["agentId"],
      agent_user_id: run_request["agentUserId"],
      owner_user_id: run_request["ownerUserId"],
      requester_user_id: run_request["requesterUserId"],
      chat_id: run_request["chatId"],
      chat_kind: run_request["chatKind"],
      source: run_request["source"],
      parent_run_id: run_request["parentRunId"],
      idempotency_key: run_request["idempotencyKey"],
      input: Map.put(run_request["input"] || %{}, "replyToId", run_request["replyToId"]),
      agent_profile: run_request["agentProfile"] || %{},
      context: run_request["context"] || %{},
      capabilities: run_request["capabilities"] || %{}
    }

    with {:ok, run} <- %AgentRun{} |> AgentRun.create_changeset(attrs) |> Repo.insert() do
      _ = VibeAgents.Runs.Dispatcher.start_or_queue(run.id)
      {:ok, run}
    end
  end

  def get(run_id) do
    case Ecto.UUID.cast(run_id) do
      {:ok, id} -> Repo.get(AgentRun, id)
      :error -> nil
    end
  end

  def events_tail(run_id, limit \\ 200) do
    from(e in AgentRunEvent, where: e.run_id == ^run_id, order_by: [desc: :seq], limit: ^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  def active_for_agent?(agent_id) do
    from(r in AgentRun,
      where: r.agent_id == ^agent_id and r.status not in ["completed", "failed", "cancelled"]
    )
    |> Repo.exists?()
  end

  @doc "Cancel a run. attrs: %{reason:, requested_by_user_id:}."
  def cancel(run_id, attrs \\ %{}) do
    case whereis(run_id) do
      pid when is_pid(pid) -> Server.cancel(pid, attrs)
      nil -> {:error, :not_found}
    end
  end

  @doc "decision_map: wire shape (decisionId/outcome/answer/actorUserId). Resumes the run."
  def decide(run_id, decision_map) do
    case whereis(run_id) do
      pid when is_pid(pid) -> Server.decide(pid, decision_map)
      nil -> {:error, :not_found}
    end
  end

  defp whereis(run_id) do
    case Elixir.Registry.lookup(VibeAgents.Runs.Registry, to_string(run_id)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def kill_switch? do
    Application.get_env(:vibe_agents, :kill_switch, false)
  end
end
