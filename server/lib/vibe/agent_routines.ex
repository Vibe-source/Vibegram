defmodule Vibe.AgentRoutines do
  @moduledoc """
  Scheduled proactive agent runs: create/list/update/delete plus the
  claim/complete pair the poller uses (mirrors `Chat.claim_due_channel_agent_assignments`).
  """

  import Ecto.Query

  alias Vibe.Agent
  alias Vibe.AgentRoutine
  alias Vibe.Chat
  alias Vibe.Repo

  @max_per_owner_default 20
  @max_failures_default 5

  def list_for_agent(agent_id, owner_user_id) do
    Repo.all(
      from r in AgentRoutine,
        where: r.agent_id == ^agent_id and r.owner_user_id == ^owner_user_id,
        order_by: [desc: r.inserted_at]
    )
  end

  def get(id, owner_user_id) when is_binary(id) and is_binary(owner_user_id) do
    with {:ok, routine_id} <- Ecto.UUID.cast(id),
         {:ok, owner_id} <- Ecto.UUID.cast(owner_user_id) do
      Repo.one(from r in AgentRoutine, where: r.id == ^routine_id and r.owner_user_id == ^owner_id)
    else
      :error -> nil
    end
  end

  def get(_id, _owner_user_id), do: nil

  def create(owner_user_id, %Agent{} = agent, attrs) do
    attrs = normalize_attrs(attrs)
    max_per_owner = Application.get_env(:vibe, :agent_routines_max_per_owner, @max_per_owner_default)

    cond do
      agent.owner_user_id != owner_user_id ->
        {:error, :not_found}

      agent.status != "published" ->
        {:error, :agent_not_published}

      not valid_chat?(attrs["chat_id"], agent.agent_user_id, owner_user_id) ->
        {:error, :not_in_chat}

      active_or_paused_count(owner_user_id) >= max_per_owner ->
        {:error, :routine_limit}

      true ->
        insert_routine(owner_user_id, agent, attrs)
    end
  end

  def update(%AgentRoutine{} = routine, attrs) do
    attrs = normalize_attrs(attrs)
    requested_status = attrs["status"]

    cond do
      is_binary(requested_status) and requested_status not in ["active", "paused"] ->
        {:error,
         routine |> Ecto.Changeset.change() |> Ecto.Changeset.add_error(:status, "must be active or paused")}

      Map.has_key?(attrs, "chat_id") and
          not valid_chat?(attrs["chat_id"], routine_agent_user_id(routine), routine.owner_user_id) ->
        {:error, :not_in_chat}

      true ->
        apply_update(routine, attrs)
    end
  end

  def delete(%AgentRoutine{} = routine), do: Repo.delete(routine)

  @doc "Atomically claims due active routines and advances their next run."
  def claim_due(limit \\ 10) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    limit = limit |> max(1) |> min(50)

    case Repo.transaction(fn ->
           routines =
             Repo.all(
               from(r in AgentRoutine,
                 where:
                   r.status == "active" and not is_nil(r.next_trigger_at) and
                     r.next_trigger_at <= ^now,
                 order_by: [asc: r.next_trigger_at],
                 limit: ^limit,
                 lock: "FOR UPDATE SKIP LOCKED"
               )
             )

           Enum.map(routines, fn routine ->
             next = DateTime.add(now, min(routine.every_minutes, 10080) * 60, :second)

             routine
             |> AgentRoutine.changeset(%{
               "next_trigger_at" => next,
               "last_run_at" => now,
               "last_status" => "running",
               "last_error" => nil
             })
             |> Repo.update!()
             |> Map.fetch!(:id)
           end)
         end) do
      {:ok, []} ->
        {:ok, []}

      {:ok, ids} ->
        claimed = Repo.all(from(r in AgentRoutine, where: r.id in ^ids, preload: [agent: :agent_user]))
        {:ok, claimed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "completed resets the failure counter; failed increments it (disables at the limit); skipped_credits leaves it alone."
  def complete(routine_id, status, error \\ nil) when status in ~w(completed failed skipped_credits) do
    case Repo.get(AgentRoutine, routine_id) do
      nil ->
        {:error, :not_found}

      routine ->
        max_failures = Application.get_env(:vibe, :agent_routine_max_failures, @max_failures_default)
        truncated_error = error && String.slice(error, 0, 1000)

        attrs =
          case status do
            "completed" ->
              %{"last_status" => status, "last_error" => nil, "consecutive_failures" => 0}

            "failed" ->
              failures = routine.consecutive_failures + 1
              base = %{"last_status" => status, "last_error" => truncated_error, "consecutive_failures" => failures}
              if failures >= max_failures, do: Map.put(base, "status", "disabled_failures"), else: base

            "skipped_credits" ->
              %{"last_status" => status, "last_error" => truncated_error}
          end

        routine |> AgentRoutine.changeset(attrs) |> Repo.update()
    end
  end

  def routine_payload(%AgentRoutine{} = routine) do
    %{
      "id" => routine.id,
      "agentId" => routine.agent_id,
      "chatId" => routine.chat_id,
      "prompt" => routine.prompt,
      "everyMinutes" => routine.every_minutes,
      "status" => routine.status,
      "nextTriggerAt" => iso(routine.next_trigger_at),
      "lastRunAt" => iso(routine.last_run_at),
      "lastStatus" => routine.last_status,
      "lastError" => routine.last_error,
      "consecutiveFailures" => routine.consecutive_failures
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp valid_chat?(chat_id, agent_user_id, owner_user_id) do
    is_binary(chat_id) and Chat.is_participant?(chat_id, agent_user_id) and
      Chat.is_participant?(chat_id, owner_user_id)
  end

  defp routine_agent_user_id(routine) do
    Repo.preload(routine, :agent).agent.agent_user_id
  end

  defp active_or_paused_count(owner_user_id) do
    Repo.aggregate(
      from(r in AgentRoutine, where: r.owner_user_id == ^owner_user_id and r.status in ["active", "paused"]),
      :count
    )
  end

  defp insert_routine(owner_user_id, agent, attrs) do
    changeset =
      %AgentRoutine{}
      |> AgentRoutine.changeset(Map.merge(attrs, %{"agent_id" => agent.id, "owner_user_id" => owner_user_id}))
      |> stamp_next_trigger()

    Repo.insert(changeset)
  end

  defp apply_update(routine, attrs) do
    status_activating? = attrs["status"] == "active" and routine.status != "active"
    every_minutes_changing? = Map.has_key?(attrs, "every_minutes")

    changeset = AgentRoutine.changeset(routine, attrs)
    changeset = if status_activating?, do: Ecto.Changeset.put_change(changeset, :consecutive_failures, 0), else: changeset
    changeset = if status_activating? or every_minutes_changing?, do: stamp_next_trigger(changeset), else: changeset

    Repo.update(changeset)
  end

  defp stamp_next_trigger(changeset) do
    case Ecto.Changeset.get_field(changeset, :every_minutes) do
      m when is_integer(m) -> Ecto.Changeset.put_change(changeset, :next_trigger_at, next_trigger_at(m))
      _ -> changeset
    end
  end

  defp next_trigger_at(minutes) do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(minutes * 60, :second)
  end

  defp normalize_attrs(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    %{}
    |> maybe_put("chat_id", attrs["chat_id"] || attrs["chatId"])
    |> maybe_put("prompt", attrs["prompt"])
    |> maybe_put("every_minutes", attrs["every_minutes"] || attrs["everyMinutes"])
    |> maybe_put("status", attrs["status"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
