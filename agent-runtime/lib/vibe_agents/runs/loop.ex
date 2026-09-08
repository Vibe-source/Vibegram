defmodule VibeAgents.Runs.Loop do
  @moduledoc """
  Builds messages + config for one run (or one resumption) and drives it through
  `VibeAgents.LLM.Loop` (or the configured fake). Delivers outputs, records usage, and emits
  the terminal `RunEvent`. `ask_user` is the ONE path that ends the turn early (terminal
  "waiting_for_user", exactly like the core) — everything else either runs to completion or
  blocks synchronously inside `VibeAgents.Tools.Executor` and returns here normally.
  """
  require Logger
  alias VibeAgents.{Budget, CoreClient, Policy, Repo, Sandbox}
  alias VibeAgents.Runs.{Decisions, Events}
  alias VibeAgents.Schemas.AgentRun
  alias VibeAgents.Tools.{Catalog, Executor}

  def run(run) do
    Events.emit(run, "run.started", %{"source" => run.source, "model" => model_id(run)})
    execute(run, build_initial_messages(run), MapSet.new())
  end

  @doc "Resumes a run after a terminal ask, or after a restart re-armed a waiting decision."
  def resume(run, decision) do
    note = %{role: "user", content: describe_decision(decision)}
    messages = (run.state["messages"] || []) ++ [note]
    granted = MapSet.new(run.state["grantedCapabilities"] || [])
    execute(run, messages, granted)
  end

  defp execute(run, messages, granted_capabilities) do
    Budget.check!(run)

    state = %{
      run: run,
      run_id: run.id,
      agent_id: run.agent_id,
      chat_id: run.chat_id,
      tool_failures: 0,
      granted_capabilities: granted_capabilities
    }

    config = build_config(run, state)

    case llm_module().run(messages, config) do
      {:ok, text, final_state} -> finish(run, messages, text, final_state)
      {:error, reason} -> fail(run, to_string(reason), "llm_error")
    end
  rescue
    e in Budget.ExceededError -> fail(run, e.message, "budget_exceeded")
  end

  defp build_config(run, state) do
    profile = run.agent_profile
    capabilities = run.capabilities || %{}

    %VibeAgents.LLM.Loop.Config{
      provider: profile["modelProvider"] || "anthropic",
      model: model_id(run),
      thinking_level: profile["thinkingLevel"] || "medium",
      max_depth: Application.get_env(:vibe_agents, :max_steps, 24),
      system_prompt: Policy.system_prompt(profile, capabilities, run.context || %{}),
      tools: Catalog.specs(profile, capabilities),
      execute_tools: &Executor.execute/3,
      state: state,
      callback: fn event -> handle_llm_event(run, event) end,
      request_label: "VibeAgents.Runs.Loop"
    }
  end

  defp model_id(run) do
    profile = run.agent_profile
    profile["modelId"] || default_model(profile["modelProvider"])
  end

  defp default_model("openai"), do: "gpt-5.6-luna"
  defp default_model(_provider), do: "claude-sonnet-5"

  defp llm_module, do: Application.get_env(:vibe_agents, :llm_module, VibeAgents.LLM.Loop)


  defp finish(run, input_messages, text, final_state) do
    if Map.get(final_state, :terminal_status) == "waiting_for_user" do
      finish_waiting_ask(run, final_state)
    else
      finish_completed(run, input_messages, text, final_state)
    end
  end

  defp finish_completed(run, input_messages, text, final_state) do
    input_tokens = Budget.estimate_tokens(inspect(input_messages))
    output_tokens = Budget.estimate_tokens(text)
    sandbox_seconds = sandbox_seconds_for(run)
    cost_cents = Budget.record_usage(run, input_tokens, output_tokens, sandbox_seconds)

    usage = %{
      "inputTokens" => Map.get(run.usage || %{}, "inputTokens", 0) + input_tokens,
      "outputTokens" => Map.get(run.usage || %{}, "outputTokens", 0) + output_tokens
    }

    if String.trim(to_string(text)) != "" do
      outputs = [VibeContracts.Outputs.text_output(text, %{})] |> VibeContracts.Outputs.finalize_batch(agent_turn_id: run.id)
      deliver(run, outputs)
    end

    total_cost = (run.cost_cents || 0) + cost_cents
    summary = if Map.get(final_state, :handoff_dispatched), do: "handed off", else: short_summary(text)

    run =
      update_run(run, %{
        status: "completed",
        result: %{"text" => text},
        usage: usage,
        cost_cents: total_cost,
        finished_at: DateTime.utc_now(),
        steps: (run.steps || 0) + 1
      })

    Events.emit(run, "run.completed", %{
      "summary" => summary,
      "usage" => usage,
      "costCents" => total_cost,
      "sandboxSeconds" => sandbox_seconds
    })
  end

  defp sandbox_seconds_for(run) do
    used_capability = (run.capabilities || %{})["computer"] || (run.capabilities || %{})["browser"]

    if used_capability && run.started_at && Sandbox.used_since?(run.agent_id, run.started_at) do
      max(DateTime.diff(DateTime.utc_now(), run.started_at), 0)
    else
      0
    end
  end

  defp finish_waiting_ask(run, final_state) do
    case Decisions.latest_pending(run.id) do
      %{kind: "ask"} = decision ->
        questions = decision.request["questions"] || []
        fallback = Enum.map_join(questions, "\n", & &1["question"])

        outputs =
          [VibeContracts.Outputs.question_output(decision.id, questions, fallback)]
          |> VibeContracts.Outputs.finalize_batch(agent_turn_id: run.id)

        deliver(run, outputs)

        state_map = %{
          "messages" => final_state[:current_messages] || [],
          "step" => 0,
          "grantedCapabilities" => MapSet.to_list(final_state[:granted_capabilities] || MapSet.new())
        }

        update_run(run, %{status: "waiting_ask", state: state_map})

      _ ->
        fail(run, "ask_user ended the turn without a pending decision.", "ask_missing_decision")
    end
  end

  defp fail(run, message, code) do
    run = update_run(run, %{status: "failed", error: message, finished_at: DateTime.utc_now()})
    Events.emit(run, "run.failed", %{"error" => message, "code" => code})
  end

  defp deliver(run, outputs) do
    CoreClient.deliver(%{
      "runId" => run.id,
      "agentId" => run.agent_id,
      "chatId" => run.chat_id,
      "replyToId" => run.input["replyToId"],
      "outputs" => outputs
    })
  end

  defp update_run(run, attrs) do
    {:ok, updated} = run |> AgentRun.update_changeset(attrs) |> Repo.update()
    updated
  end

  defp short_summary(text) do
    text |> to_string() |> String.slice(0, 140)
  end


  defp build_initial_messages(run) do
    history = (run.context || %{})["history"] || []
    Enum.map(history, &history_message/1) ++ [%{role: "user", content: input_content(run.input || %{})}]
  end

  defp history_message(entry) when is_map(entry) do
    role = if entry["role"] == "assistant", do: "assistant", else: "user"
    author = entry["authorName"]
    text = entry["text"] || ""
    content = if role == "user" and is_binary(author) and author != "", do: "#{author}: #{text}", else: text
    %{role: role, content: content}
  end

  defp input_content(input) do
    text = input["text"] || ""
    attachments = input["attachments"] || []

    if attachments == [] do
      text
    else
      [%{"type" => "text", "text" => text} | Enum.flat_map(attachments, &attachment_block/1)]
    end
  end

  defp attachment_block(%{"kind" => "image", "url" => url}) when is_binary(url) do
    [%{"type" => "image", "source" => %{"type" => "url", "url" => url}}]
  end

  defp attachment_block(_attachment), do: []

  defp describe_decision(%{kind: "ask", outcome: outcome, answer: answer}) do
    "[System: you asked the user a question. Outcome: #{outcome || "answered"}. " <>
      "Answer: #{Jason.encode!(answer || %{})}. Continue the task using this answer.]"
  end

  defp describe_decision(%{kind: kind, outcome: outcome, request: request}) do
    title = request["title"] || request["capability"] || kind
    "[System: your #{kind} request (\"#{title}\") was #{outcome || "resolved"}. Continue accordingly — " <>
      "if it was not approved, do not retry the same action; tell the user and offer an alternative.]"
  end


  defp handle_llm_event(run, %{type: :text, content: content}) do
    Events.emit(run, "run.text.delta", %{"text" => content})
  end

  defp handle_llm_event(run, %{type: :thinking} = event) do
    label = if Map.get(event, :status) == "done", do: "Thought", else: "Thinking"
    Events.emit(run, "run.thinking", %{"tokens" => Map.get(event, :tokens, 0), "label" => label})
  end

  defp handle_llm_event(run, %{type: :progress, tool: tool, tool_call_id: id, label: label, status: status} = event) do
    cond do
      Map.has_key?(event, :input) ->
        Events.emit(run, "run.tool.started", %{
          "toolCallId" => id,
          "tool" => tool,
          "label" => label,
          "input" => VibeContracts.Redact.tool_input(event.input)
        })

      status in ["done", "error"] ->
        Events.emit(run, "run.tool.completed", %{"toolCallId" => id, "tool" => tool, "label" => label, "status" => status, "summary" => label})

      true ->
        Events.emit(run, "run.progress", %{"label" => label, "status" => status})
    end
  end

  defp handle_llm_event(run, %{type: :progress, label: label, status: status}) do
    Events.emit(run, "run.progress", %{"label" => label, "status" => status})
  end

  defp handle_llm_event(_run, _event), do: :ok
end
