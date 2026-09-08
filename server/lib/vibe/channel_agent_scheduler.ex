defmodule Vibe.ChannelAgentScheduler do
  @moduledoc """
  Claims and runs durable interval-based channel-agent assignments.
  """

  use GenServer
  require Logger

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
    case Chat.claim_due_channel_agent_assignments(@claim_limit) do
      {:ok, assignments} -> Enum.each(assignments, &run_async/1)
      {:error, reason} -> Logger.error("[ChannelAgentScheduler] claim failed: #{inspect(reason)}")
    end

    Process.send_after(self(), :poll, @poll_interval_ms)
    {:noreply, state}
  end

  defp run_async(assignment) do
    Task.start(fn -> run(assignment) end)
  end

  defp run(assignment) do
    prompt =
      "Create and publish the next scheduled channel update now. Follow the " <>
        "channel-specific instructions, use only the permitted tools and output modes, " <>
        "and do not describe this scheduling request in the post."

    result =
      StandaloneAgent.invoke(assignment.agent, %{
        "message" => prompt,
        "responseMode" => "send",
        "vibeChatId" => assignment.chat_id,
        "requesterUserId" => assignment.created_by
      })

    case result do
      {:ok, _payload} ->
        _ = Chat.complete_channel_agent_trigger(assignment.id, "completed")

      {:error, reason} ->
        _ =
          Chat.complete_channel_agent_trigger(
            assignment.id,
            "failed",
            inspect(reason)
          )

        Logger.warning(
          "[ChannelAgentScheduler] run failed assignment=#{assignment.id} reason=#{inspect(reason)}"
        )
    end
  rescue
    error ->
      _ =
        Chat.complete_channel_agent_trigger(
          assignment.id,
          "failed",
          Exception.message(error)
        )

      Logger.error(
        "[ChannelAgentScheduler] run crashed assignment=#{assignment.id} error=#{Exception.message(error)}"
      )
  end
end
