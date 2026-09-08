defmodule Vibe.AgentRoutineScheduler do
  @moduledoc """
  Claims and runs due agent routines (proactive scheduled prompts).
  Mirrors `Vibe.ChannelAgentScheduler`'s claim-then-run shape.
  """

  use GenServer
  require Logger

  alias Vibe.AgentGateway
  alias Vibe.AgentRoutines
  alias Vibe.AgentUsage
  alias Vibe.AI.StandaloneAgent
  alias Vibe.Chat

  @poll_interval_ms 30_000
  @claim_limit 10

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    Process.send_after(self(), :poll, 5_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case AgentRoutines.claim_due(@claim_limit) do
      {:ok, routines} -> Enum.each(routines, &run_async/1)
      {:error, reason} -> Logger.error("[AgentRoutineScheduler] claim failed: #{inspect(reason)}")
    end

    Process.send_after(self(), :poll, @poll_interval_ms)
    {:noreply, state}
  end

  defp run_async(routine) do
    Task.start(fn -> run(routine) end)
  end

  defp run(routine) do
    agent = routine.agent

    cond do
      is_nil(agent) or agent.status != "published" or
          not Chat.is_participant?(routine.chat_id, agent.agent_user_id) ->
        AgentRoutines.complete(routine.id, "failed", "agent_unavailable")

      match?({:error, _}, AgentUsage.check_entitlement(routine.owner_user_id)) ->
        AgentRoutines.complete(routine.id, "skipped_credits", "monthly agent credits exhausted")

      true ->
        dispatch(routine, agent)
    end
  rescue
    error ->
      _ = AgentRoutines.complete(routine.id, "failed", Exception.message(error))

      Logger.error(
        "[AgentRoutineScheduler] run crashed routine=#{routine.id} error=#{Exception.message(error)}"
      )
  end

  defp dispatch(routine, agent) do
    result =
      if AgentGateway.execution_mode_for(agent) == "isolated" and AgentGateway.enabled?() do
        AgentGateway.start_run(%{
          agent: agent,
          chat_id: routine.chat_id,
          requester_user_id: routine.owner_user_id,
          text: routine.prompt,
          attachments: [],
          source: "schedule"
        })
      else
        StandaloneAgent.invoke(agent, %{
          "message" => routine.prompt,
          "responseMode" => "send",
          "vibeChatId" => routine.chat_id,
          "requesterUserId" => routine.owner_user_id
        })
      end

    case result do
      {:ok, _payload} -> AgentRoutines.complete(routine.id, "completed")
      {:error, reason} -> AgentRoutines.complete(routine.id, "failed", inspect(reason))
    end
  end
end
