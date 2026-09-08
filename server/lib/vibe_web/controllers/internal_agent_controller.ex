defmodule VibeWeb.InternalAgentController do
  @moduledoc """
  Runtime → core internal API (docs/agent-platform-v1.md §3.3). Mounted behind
  `VibeWeb.Plugs.InternalServiceAuth` — never exposed publicly through Caddy.
  """

  use VibeWeb, :controller
  require Logger

  alias Vibe.Agent
  alias Vibe.AgentGateway
  alias Vibe.AgentRelay
  alias Vibe.Agents
  alias Vibe.AgentUsage
  alias Vibe.AI.AgentDecisions
  alias Vibe.AI.StandaloneAgent
  alias Vibe.Chat
  alias Vibe.Repo

  def agent_events(conn, %{"events" => events}) when is_list(events) do
    accepted =
      events
      |> Enum.flat_map(&authorised_event/1)
      |> Enum.group_by(& &1["runId"])
      |> Enum.map(fn {run_id, group} -> accept_run_events(run_id, group) end)
      |> Enum.sum()

    json(conn, %{accepted: accepted})
  end

  def agent_events(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "invalid_events"})
  end

  # The runtime is trusted for identity, not for authority:
  defp agent_in_chat?(agent_user_id, chat_id) when is_binary(agent_user_id) and is_binary(chat_id) do
    Chat.is_participant?(chat_id, agent_user_id)
  end

  defp agent_in_chat?(_agent_user_id, _chat_id), do: false

  defp maybe_record_usage(%{"kind" => "run.completed"} = event) do
    case Agents.get_agent(event["agentId"]) do
      nil -> :ok
      agent -> AgentUsage.record_run_completed(agent, event)
    end
  rescue
    error ->
      Logger.warning("[InternalAgentController] usage capture failed error=#{Exception.message(error)}")
  end

  defp maybe_record_usage(_event), do: :ok

  @doc "Public A2A card for the runtime's `/v1/agents/:identifier/card` proxy."
  def card(conn, %{"identifier" => identifier}) do
    case Agents.get_invoke_target(identifier) do
      %Agent{status: "published"} = agent ->
        json(conn, Vibe.AgentCard.build(agent, VibeWeb.Endpoint.url()))

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def deliveries(conn, %{"agentId" => agent_id, "chatId" => chat_id} = params) do
    outputs = params["outputs"] || []
    reply_to_id = params["replyToId"]

    case Repo.get(Agent, agent_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "agent_not_found"})

      %Agent{agent_user_id: agent_user_id} = agent ->
        if agent_in_chat?(agent_user_id, chat_id) do
          agent = Repo.preload(agent, :agent_user)

          case StandaloneAgent.deliver_outputs(agent, chat_id, outputs, reply_to_id) do
            {:ok, delivered} -> json(conn, %{deliveries: delivered})
            {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
          end
        else
          conn |> put_status(:forbidden) |> json(%{error: "agent_not_in_chat"})
        end
    end
  end

  def approvals(conn, %{"agentId" => agent_id, "chatId" => chat_id} = params) do
    case Repo.get(Agent, agent_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "agent_not_found"})

      %Agent{agent_user_id: agent_user_id} = agent ->
        if agent_in_chat?(agent_user_id, chat_id) do
          agent = Repo.preload(agent, :agent_user)

          case AgentDecisions.create_runtime_decision(agent, chat_id, params) do
            {:ok, %{taskId: task_id, messageId: message_id}} ->
              json(conn, %{taskId: task_id, messageId: message_id})

            {:error, reason} ->
              conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
          end
        else
          conn |> put_status(:forbidden) |> json(%{error: "agent_not_in_chat"})
        end
    end
  end

  def provider_auth(conn, %{"identifier" => identifier, "secret" => secret})
      when is_binary(identifier) and is_binary(secret) do
    with %Agent{status: "published"} = agent <- Agents.get_invoke_target(identifier),
         true <- Agents.verify_secret(agent, secret) do
      agent = Repo.preload(agent, :agent_user)

      json(conn, %{
        agentProfile: AgentGateway.agent_profile(agent),
        agentId: agent.id,
        agentUserId: agent.agent_user_id,
        ownerUserId: agent.owner_user_id,
        defaultChatId: agent.default_destination_chat_id
      })
    else
      _ -> unauthorized(conn)
    end
  end

  def provider_auth(conn, _params), do: unauthorized(conn)

  def handoffs(
        conn,
        %{
          "runId" => run_id,
          "agentId" => agent_id,
          "chatId" => chat_id,
          "toAgentUsername" => target_username
        } = params
      ) do
    note = params["note"] || ""

    with %Agent{} = source_agent <- Repo.get(Agent, agent_id),
         true <- Chat.is_participant?(chat_id, source_agent.agent_user_id),
         %Agent{status: "published"} = target_agent <- Agents.get_agent_by_username(target_username),
         true <- Chat.is_participant?(chat_id, target_agent.agent_user_id) do
      source_agent = Repo.preload(source_agent, :agent_user)
      handoff_text = String.trim("@#{target_username} #{note}")

      outputs = [
        %{"type" => "text", "text" => handoff_text, "metadata" => %{"handoffFromRunId" => run_id}}
      ]

      case StandaloneAgent.deliver_outputs(source_agent, chat_id, outputs, nil) do
        {:ok, [delivery | _]} ->
          _ =
            VibeWeb.ChatChannel.dispatch_agent_mention(chat_id, target_agent,
              text: note,
              parent_run_id: run_id
            )

          json(conn, %{messageId: delivery.messageId, dispatched: true})

        {:ok, []} ->
          json(conn, %{messageId: nil, dispatched: false})

        {:error, _reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "delivery_failed"})
      end
    else
      _ -> conn |> put_status(:forbidden) |> json(%{error: "handoff_not_allowed"})
    end
  end

  def handoffs(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "invalid_handoff"})
  end

  def healthz(conn, _params), do: json(conn, %{ok: true})

  defp unauthorized(conn), do: conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})

  defp authorised_event(event) do
    case VibeContracts.RunEvent.validate(event) do
      {:ok, validated} ->
        if agent_in_chat?(validated["agentUserId"], validated["chatId"]) do
          [validated]
        else
          Logger.warning("[InternalAgentController] RunEvent for a chat the agent is not in — dropped")
          []
        end

      {:error, reason} ->
        Logger.warning("[InternalAgentController] invalid RunEvent reason=#{inspect(reason)}")
        []
    end
  end

  # Durable per-run high-water mark: a redelivered batch counts as accepted but replays
  # no side effects. Relay broadcasts run after the transaction commits.
  defp accept_run_events(run_id, group) do
    sorted = Enum.sort_by(group, & &1["seq"])

    result =
      Repo.transaction(fn ->
        last_seq = lock_receipt(run_id)
        fresh = sorted |> Enum.filter(&(&1["seq"] > last_seq)) |> Enum.uniq_by(& &1["seq"])
        Enum.each(fresh, &maybe_record_usage/1)

        case fresh do
          [] -> :ok
          _ -> advance_receipt(run_id, fresh |> Enum.map(& &1["seq"]) |> Enum.max())
        end

        fresh
      end)

    case result do
      {:ok, fresh} ->
        Enum.each(fresh, &AgentRelay.handle/1)
        length(sorted)

      {:error, reason} ->
        Logger.warning("[InternalAgentController] run receipt failed run=#{run_id} reason=#{inspect(reason)}")
        0
    end
  end

  # Upsert-and-return takes the row lock even when the receipt does not exist yet,
  # which a bare SELECT ... FOR UPDATE cannot do.
  defp lock_receipt(run_id) do
    %{rows: [[last_seq]]} =
      Repo.query!(
        """
        INSERT INTO agent_run_receipts (run_id, last_seq, updated_at)
        VALUES ($1, 0, now())
        ON CONFLICT (run_id) DO UPDATE SET updated_at = EXCLUDED.updated_at
        RETURNING last_seq
        """,
        [run_id]
      )

    last_seq
  end

  defp advance_receipt(run_id, max_seq) do
    Repo.query!(
      """
      UPDATE agent_run_receipts
      SET last_seq = GREATEST(last_seq, $2), updated_at = now()
      WHERE run_id = $1
      """,
      [run_id, max_seq]
    )
  end
end
