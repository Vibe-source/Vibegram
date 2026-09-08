defmodule VibeAgents.Runs.Decisions do
  @moduledoc "CRUD for agent_run_decisions: create a pending gate, resolve it once, or expire it."
  import Ecto.Query
  alias VibeAgents.Repo
  alias VibeAgents.Schemas.AgentRunDecision

  @default_ttl_seconds 86_400

  def create(attrs) do
    expires_at = attrs[:expires_at] || DateTime.add(DateTime.utc_now(), @default_ttl_seconds, :second)

    %AgentRunDecision{}
    |> AgentRunDecision.create_changeset(Map.put(attrs, :expires_at, expires_at))
    |> Repo.insert()
  end

  def get(decision_id) do
    case Ecto.UUID.cast(decision_id) do
      {:ok, id} -> Repo.get(AgentRunDecision, id)
      :error -> nil
    end
  end

  @doc """
  Resolve a pending decision. `decision_map` uses the wire shape (string keys):
  `decisionId, outcome, answer, actorUserId`. Returns `{:ok, decision} | {:error, reason}`.
  """
  def resolve(run_id, decision_map) do
    decision_id = decision_map["decisionId"] || decision_map[:decisionId] || decision_map["decision_id"]

    with %AgentRunDecision{} = decision <- get(decision_id) || {:error, :not_found},
         true <- decision.run_id == run_id || {:error, :not_found},
         :ok <- check_status(decision) do
      decision
      |> AgentRunDecision.resolve_changeset(%{
        status: "resolved",
        outcome: decision_map["outcome"] || decision_map[:outcome],
        answer: decision_map["answer"] || decision_map[:answer],
        actor_user_id: decision_map["actorUserId"] || decision_map[:actorUserId],
        resolved_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update()
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_status(%AgentRunDecision{status: "pending"} = decision) do
    if expired?(decision), do: expire(decision), else: :ok
  end

  defp check_status(%AgentRunDecision{status: "expired"}), do: {:error, :expired}
  defp check_status(%AgentRunDecision{}), do: {:error, :already_decided}

  defp expired?(%AgentRunDecision{expires_at: nil}), do: false
  defp expired?(%AgentRunDecision{expires_at: expires_at}), do: DateTime.compare(DateTime.utc_now(), expires_at) == :gt

  defp expire(decision) do
    decision |> AgentRunDecision.resolve_changeset(%{status: "expired"}) |> Repo.update()
    {:error, :expired}
  end

  @doc "Latest pending decision for a run, used to re-arm a waiting_* run after a restart."
  def latest_pending(run_id) do
    AgentRunDecision
    |> where([d], d.run_id == ^run_id and d.status == "pending")
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end
end
