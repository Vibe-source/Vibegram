defmodule VibeAgents.LLM.FakeLoop do
  @moduledoc """
  Scripted stand-in for `VibeAgents.LLM.Loop` (config `:llm_module`). The script is a list of
  steps read from `Application.get_env(:vibe_agents, :fake_llm_script)`:
  `{:text, "reply"}` ends the turn; `{:tool_use, [tool_call]}` runs the executor first.
  Steps are consumed per run id, so a resumed run continues where it stopped.
  """

  def run(messages, config) do
    script = Application.get_env(:vibe_agents, :fake_llm_script, [{:text, "ok"}])
    run_id = Map.get(config.state, :run_id) || "global"
    consumed = Map.get(cursor(), run_id, 0)
    step(Enum.drop(script, consumed), messages, config.state, config, run_id, consumed)
  end

  defp step([], _messages, state, _config, _run_id, _consumed), do: {:ok, "", state}

  defp step([{:text, text} | _rest], _messages, state, _config, run_id, consumed) do
    advance(run_id, consumed + 1)
    {:ok, text, state}
  end

  defp step([{:error, reason} | _rest], _messages, _state, _config, run_id, consumed) do
    advance(run_id, consumed + 1)
    {:error, reason}
  end

  defp step([{:tool_use, tool_calls} | rest], messages, state, config, run_id, consumed) do
    advance(run_id, consumed + 1)
    callback = config.callback || fn _event -> :ok end
    snapshot = Map.put(state, :current_messages, messages)
    {results, next_state} = config.execute_tools.(tool_calls, snapshot, callback)

    if Map.get(next_state, :terminal_status) == "waiting_for_user" do
      {:ok, "", next_state}
    else
      step(rest, messages ++ [%{role: "user", content: results}], next_state, config, run_id, consumed + 1)
    end
  end

  defp cursor, do: Application.get_env(:vibe_agents, :fake_llm_cursor, %{})
  defp advance(run_id, n), do: Application.put_env(:vibe_agents, :fake_llm_cursor, Map.put(cursor(), run_id, n))
end
