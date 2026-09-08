defmodule VibeAgents.Tools.Handoff do
  @moduledoc """
  `handoff_to_agent` (spec §3.8): depth <= 4 per root run, one handoff per target per run,
  kill switch honoured. Posts via `VibeAgents.CoreClient.handoff/1` and emits `run.handoff`.
  """
  import Ecto.Query
  alias VibeAgents.{CoreClient, Repo, Runs}
  alias VibeAgents.Runs.Events
  alias VibeAgents.Schemas.{AgentRun, AgentRunEvent}

  @max_depth 4

  def handoff_to_agent(run, input) when is_map(input) do
    username = username(input["username"])
    note = trimmed(input["note"]) || ""

    cond do
      Runs.kill_switch?() ->
        %{"ok" => false, "error" => "Handoffs are paused right now."}

      is_nil(username) ->
        %{"ok" => false, "error" => "username is required"}

      depth(run) >= @max_depth ->
        %{"ok" => false, "error" => "Handoff depth limit (#{@max_depth}) reached for this task."}

      already_handed_off?(run, username) ->
        %{"ok" => false, "error" => "Already handed off to @#{username} in this run."}

      true ->
        dispatch(run, username, note)
    end
  end

  def handoff_to_agent(_run, _input), do: %{"ok" => false, "error" => "username is required"}

  defp dispatch(run, username, note) do
    case CoreClient.handoff(%{
           "runId" => run.id,
           "agentId" => run.agent_id,
           "chatId" => run.chat_id,
           "toAgentUsername" => username,
           "note" => note
         }) do
      {:ok, body} when is_map(body) ->
        dispatched = Map.get(body, "dispatched", true)

        Events.emit(run, "run.handoff", %{"toAgentUsername" => username, "note" => note, "childRunId" => body["messageId"]})

        %{
          "ok" => true,
          "dispatched" => dispatched,
          "handoff_dispatched" => true,
          "next_step" => "Handoff dispatched. Finish your OWN turn now with a one-line summary; do not keep working this task."
        }

      {:error, reason} ->
        %{"ok" => false, "error" => "Handoff failed: #{inspect(reason)}"}
    end
  end

  defp already_handed_off?(run, username) do
    AgentRunEvent
    |> where([e], e.run_id == ^run.id and e.kind == "run.handoff")
    |> Repo.all()
    |> Enum.any?(&(&1.payload["toAgentUsername"] == username))
  end

  defp depth(run, hops \\ 0)
  defp depth(_run, hops) when hops >= @max_depth + 2, do: hops

  defp depth(%AgentRun{parent_run_id: nil}, hops), do: hops

  defp depth(%AgentRun{parent_run_id: parent_id}, hops) do
    case Repo.get(AgentRun, parent_id) do
      nil -> hops
      parent -> depth(parent, hops + 1)
    end
  end

  defp username(value) do
    case trimmed(value) do
      nil -> nil
      handle -> handle |> String.trim_leading("@") |> trimmed()
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_value), do: nil
end
