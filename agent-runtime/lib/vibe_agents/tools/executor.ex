defmodule VibeAgents.Tools.Executor do
  @moduledoc """
  `execute_tools` callback passed into `VibeAgents.LLM.Loop.Config`. Same mechanics as the
  core's `execute_tools_runtime/3` (labels, concurrency, crash/timeout results) plus the
  isolated runtime's decision gate: `VibeAgents.Broker.authorize/3` runs before every call.

  A call needing approval/permission/ask blocks its OWN task in
  `VibeAgents.Runs.Server.await_decision/3`. `VibeAgents.Runs.Server` can track only ONE
  outstanding decision per run, so — exactly like the core's `ask_user` precedent
  (`executable_calls = [ask_call]`) — when a round contains a call that needs a decision,
  ONLY THE FIRST ONE runs this round; siblings are dropped and the model re-requests them
  next round. Rounds with no decision-needing calls run fully concurrently as before.
  `ask_user` itself is NOT gated here: it is always `:run` and ends the turn on its own
  (see `VibeAgents.Tools.AskUser`), exactly like the core.
  """
  require Logger
  alias VibeAgents.{Broker, CoreClient}
  alias VibeAgents.Runs.{Decisions, Events, Server}
  alias VibeAgents.Tools.{AskUser, Browser, Computer, Handoff, Memory, ReadUrl, Search}

  @tool_timeout_ms 120_000
  @min_decision_timeout_ms 60_000
  @max_decision_timeout_ms 7 * 24 * 60 * 60 * 1000

  def execute(tool_calls, state, callback) do
    classified = Enum.map(tool_calls, fn tool -> {tool, classify(tool, state)} end)

    executable =
      case Enum.find(classified, &match?({_tool, {:decision, _, _, _}}, &1)) do
        nil -> classified
        decision_call -> [decision_call]
      end

    Enum.each(executable, fn {tool, classification} -> emit_running(tool, classification, state, callback) end)

    tasks =
      Enum.map(executable, fn {tool, classification} ->
        {tool, classification,
         Task.Supervisor.async_nolink(VibeAgents.TaskSupervisor, fn ->
           run_classified(tool, classification, state, callback)
         end)}
      end)

    outcomes =
      Enum.map(tasks, fn {tool, classification, task} ->
        timeout = yield_timeout(classification)

        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, {result, grant}} -> {result, grant}
          {:exit, reason} -> {crash_result(tool, callback, reason), nil}
          nil -> {timeout_result(tool, callback), nil}
        end
      end)

    results = Enum.map(outcomes, &elem(&1, 0))
    next_state = fold_outcomes(state, results, outcomes)
    {results, next_state}
  end

  defp fold_outcomes(state, results, outcomes) do
    granted =
      Enum.reduce(outcomes, state[:granted_capabilities] || MapSet.new(), fn
        {_result, nil}, acc -> acc
        {_result, capability}, acc -> MapSet.put(acc, capability)
      end)

    failures = Enum.count(results, &tool_result_error?/1)
    handed_off? = Enum.any?(results, &handoff_result?/1)
    waiting? = Enum.any?(results, &waiting_for_user_result?/1)

    state
    |> Map.put(:granted_capabilities, granted)
    |> Map.put(:handoff_dispatched, handed_off? or Map.get(state, :handoff_dispatched, false))
    |> Map.update(:tool_failures, failures, &(&1 + failures))
    |> then(fn s -> if waiting?, do: Map.put(s, :terminal_status, "waiting_for_user"), else: s end)
  end

  defp waiting_for_user_result?(%{"content" => content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"status" => "waiting_for_user"}} -> true
      _ -> false
    end
  end

  defp waiting_for_user_result?(_result), do: false


  defp classify(tool, state) do
    name = tool["name"]
    input = tool["input"] || %{}
    run = state.run
    grants = state[:granted_capabilities] || MapSet.new()

    case Broker.required_capability(name) do
      nil ->
        broker_outcome(run, name, input, grants)

      capability ->
        if MapSet.member?(grants, capability) or Broker.auto_grant_capability?(run) do
          broker_outcome(run, name, input, grants)
        else
          reason = "First use of the #{capability} this run."
          {:decision, "permission", Broker.permission_request(capability, reason), capability}
        end
    end
  end

  defp broker_outcome(run, name, input, grants) do
    case Broker.authorize(run, name, input) do
      :run ->
        :run

      {:deny, reason} ->
        {:deny, reason}

      {:approval, request} ->
        if MapSet.member?(grants, "tool:" <> name),
          do: :run,
          else: {:decision, "approval", request, nil}

      {:ask, questions} ->
        {:decision, "ask", %{"questions" => VibeContracts.AskQuestion.normalize(questions)}, nil}
    end
  end

  defp yield_timeout({:decision, _kind, _request, _cap}), do: @max_decision_timeout_ms
  defp yield_timeout(_classification), do: @tool_timeout_ms

  defp decision_timeout_ms(%{expires_at: nil}), do: @max_decision_timeout_ms

  defp decision_timeout_ms(%{expires_at: expires_at}) do
    ms = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
    ms |> max(@min_decision_timeout_ms) |> min(@max_decision_timeout_ms)
  end


  defp run_classified(tool, :run, state, callback), do: {execute_single_tool(tool, state, callback), nil}

  defp run_classified(tool, {:deny, reason}, _state, callback) do
    result = tool_error_envelope("policy_denied", "Not permitted: #{reason}", retryable: false, hint: nil)
    emit_result(tool, callback, result, "Denied")
    {encoded_tool_result(tool, result), nil}
  end

  defp run_classified(tool, {:decision, kind, request, capability}, state, callback) do
    run = state.run

    with {:ok, decision} <- Decisions.create(%{run_id: run.id, kind: kind, request: request}) do
      maybe_request_approval(run, kind, decision, request)
      emit_decision_requested(run, kind, decision, request)

      payload = %{
        decision_id: decision.id,
        status: waiting_status(kind),
        messages: state[:current_messages] || [],
        step: Map.get(state, :step, 0)
      }

      case Server.await_decision(run.id, payload, decision_timeout_ms(decision)) do
        {:ok, resolved} -> apply_decision_outcome(tool, kind, resolved, capability, state, callback)
        {:error, reason} -> {error_result(tool, callback, "decision_wait_failed", inspect(reason)), nil}
      end
    else
      {:error, changeset} ->
        {error_result(tool, callback, "decision_create_failed", changeset_summary(changeset)), nil}
    end
  end

  defp apply_decision_outcome(tool, "approval", %{outcome: "approve"}, _capability, state, callback),
    do: {execute_single_tool(tool, state, callback), nil}

  defp apply_decision_outcome(tool, "approval", %{outcome: "approve_always"}, _cap, state, callback),
    do: {execute_single_tool(tool, state, callback), "tool:" <> tool["name"]}

  defp apply_decision_outcome(tool, "permission", %{outcome: outcome}, capability, state, callback)
       when outcome in ["allow_once", "allow_run"] do
    {execute_single_tool(tool, state, callback), if(outcome == "allow_run", do: capability)}
  end

  defp apply_decision_outcome(tool, "ask", %{outcome: "answer", answer: answer}, _capability, _state, callback) do
    result = %{"ok" => true, "answer" => answer || %{}}
    emit_result(tool, callback, result, "Answered")
    {encoded_tool_result(tool, result), nil}
  end

  defp apply_decision_outcome(tool, _kind, _resolved, _capability, _state, callback),
    do: {declined_result(tool, callback), nil}

  defp declined_result(tool, callback) do
    result =
      tool_error_envelope("declined", "The user did not approve this action.",
        retryable: false,
        hint: "Tell the user plainly that this step did not happen, and offer an alternative if one exists."
      )

    emit_result(tool, callback, result, "Declined")
    encoded_tool_result(tool, result)
  end


  @doc """
  Runs one tool call that the caller already authorized through the broker (voice sessions
  gate their own decisions). Returns the decoded tool result map, never the wire envelope.
  """
  def execute_authorized(%{"name" => _name} = tool, state, callback) when is_function(callback, 1) do
    case execute_single_tool(tool, state, callback) do
      %{"content" => json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, decoded} -> decoded
          _ -> %{"ok" => false, "error" => "undecodable tool result"}
        end

      other ->
        other
    end
  end

  defp execute_single_tool(tool, state, callback) do
    name = tool["name"]
    input = tool["input"] || %{}
    on_step = fn label -> callback.(%{type: :progress, label: label, tool: name, tool_call_id: tool["id"], status: "running"}) end
    start = System.monotonic_time(:millisecond)

    result =
      case name do
        "search_google" -> Search.search_google(input)
        "read_url" -> ReadUrl.read_url(input)
        "ask_user" -> AskUser.ask_user(state.run, input)
        "computer_run" -> Computer.computer_run(state.run, input)
        "computer_read_file" -> Computer.computer_read_file(state.run, input)
        "computer_write_file" -> Computer.computer_write_file(state.run, input)
        "computer_edit_file" -> Computer.computer_edit_file(state.run, input)
        "computer_list_files" -> Computer.computer_list_files(state.run, input)
        "browser_open" -> Browser.browser_open(state.run, input, callback)
        "browser_read_page" -> Browser.browser_read_page(state.run, input, callback)
        "browser_act" -> Browser.browser_act(state.run, input, callback)
        "browser_screenshot" -> Browser.browser_screenshot(state.run, input, callback)
        "handoff_to_agent" -> Handoff.handoff_to_agent(state.run, input)
        "remember" -> Memory.remember(state.run, input)
        "recall" -> Memory.recall(state.run, input)
        "request_approval" -> %{"ok" => true, "approved" => true}
        _ -> %{"ok" => false, "error" => "Unknown tool #{name}"}
      end

    duration_ms = System.monotonic_time(:millisecond) - start
    failed? = tool_result_error?(result)
    label = if failed?, do: failure_label(name, result), else: "#{name} done"
    on_step.(label)
    emit_result(tool, callback, result, label, duration_ms)
    encoded_tool_result(tool, result)
  rescue
    error ->
      Logger.error("[VibeAgents.Tools.Executor] #{tool["name"]} raised: #{Exception.format(:error, error, __STACKTRACE__)}")
      crash_result(tool, callback, error)
  catch
    kind, reason ->
      Logger.error("[VibeAgents.Tools.Executor] #{tool["name"]} #{kind}: #{inspect(reason)}")
      crash_result(tool, callback, {kind, reason})
  end


  defp emit_running(tool, classification, _state, callback) do
    input = tool["input"] || %{}
    redacted = VibeContracts.Redact.tool_input(input)
    label = running_label(tool["name"], classification)

    callback.(%{type: :progress, label: label, tool: tool["name"], tool_call_id: tool["id"], status: "running", input: redacted})
  end

  defp running_label(name, {:decision, "permission", _req, _cap}), do: "Requesting permission for #{name}…"
  defp running_label(name, {:decision, kind, _req, _cap}), do: "Waiting for #{kind} on #{name}…"
  defp running_label(name, _classification), do: "Running #{name}…"

  defp emit_result(tool, callback, result, label, duration_ms \\ 0) do
    failed? = tool_result_error?(result)

    callback.(%{type: :progress, label: label, tool: tool["name"], tool_call_id: tool["id"], status: if(failed?, do: "error", else: "done")})

    callback.(%{
      type: :tool_result,
      tool: tool["name"],
      tool_call_id: tool["id"],
      result: result,
      status: if(failed?, do: "error", else: "complete"),
      duration_ms: duration_ms,
      label: label
    })
  end

  defp error_result(tool, callback, code, message) do
    result = tool_error_envelope(code, message, retryable: false, hint: nil)
    emit_result(tool, callback, result, "Failed")
    encoded_tool_result(tool, result)
  end

  defp crash_result(tool, callback, reason) do
    result =
      tool_error_envelope("tool_crashed", "#{tool["name"]} failed unexpectedly.",
        retryable: false,
        hint: "This tool is currently broken — do not retry it.",
        detail: inspect(reason) |> String.slice(0, 300)
      )

    emit_result(tool, callback, result, "Crashed")
    encoded_tool_result(tool, result)
  end

  defp timeout_result(tool, callback) do
    result =
      tool_error_envelope("tool_timeout", "#{tool["name"]} timed out.",
        retryable: true,
        hint: "Retry at most once with a simpler input, then stop and tell the user."
      )

    emit_result(tool, callback, result, "Timed out")
    encoded_tool_result(tool, result)
  end

  defp failure_label(name, result) do
    case failure_reason(result) do
      nil -> "#{name} failed"
      reason -> "#{name} failed — #{String.slice(reason, 0, 140)}"
    end
  end

  defp failure_reason(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp failure_reason(%{"error" => reason}) when is_binary(reason), do: reason
  defp failure_reason(%{"error" => reason}) when not is_nil(reason), do: inspect(reason)
  defp failure_reason(_result), do: nil

  defp tool_error_envelope(code, message, opts) do
    %{
      "ok" => false,
      "error" => %{
        "code" => code,
        "message" => to_string(message),
        "retryable" => Keyword.get(opts, :retryable, false),
        "hint" => Keyword.get(opts, :hint),
        "detail" => Keyword.get(opts, :detail)
      }
    }
  end

  defp encoded_tool_result(tool, result) do
    %{"type" => "tool_result", "tool_use_id" => tool["id"] || "unknown", "content" => Jason.encode!(result)}
  end

  defp tool_result_error?(%{"content" => content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> raw_result_error?(decoded)
      _ -> false
    end
  end

  defp tool_result_error?(result) when is_map(result), do: raw_result_error?(result)
  defp tool_result_error?(_result), do: false

  defp handoff_result?(%{"content" => content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"handoff_dispatched" => true}} -> true
      _ -> false
    end
  end

  defp handoff_result?(_result), do: false

  defp raw_result_error?(map) do
    case Map.get(map, "ok", Map.get(map, :ok, true)) do
      false -> true
      _ -> present?(Map.get(map, "error")) or present?(Map.get(map, :error))
    end
  end

  defp present?(value), do: not is_nil(value)


  defp waiting_status("approval"), do: "waiting_approval"
  defp waiting_status("permission"), do: "waiting_permission"
  defp waiting_status("ask"), do: "waiting_ask"

  defp emit_decision_requested(run, "ask", decision, request) do
    Events.emit(run, "run.ask", %{"decisionId" => decision.id, "questions" => request["questions"] || []})
  end

  defp emit_decision_requested(run, "permission", decision, request) do
    Events.emit(run, "run.permission.requested", %{
      "decisionId" => decision.id,
      "capability" => request["capability"],
      "scope" => request["scope"],
      "reason" => request["reason"]
    })
  end

  defp emit_decision_requested(run, "approval", decision, request) do
    Events.emit(run, "run.approval.requested", %{
      "decisionId" => decision.id,
      "kind" => "approval",
      "tool" => request["tool"],
      "title" => request["title"],
      "detail" => request["detail"],
      "risk" => request["risk"],
      "actions" => request["actions"] || []
    })
  end

  defp maybe_request_approval(run, kind, decision, request) when kind in ["approval", "permission"] do
    CoreClient.request_approval(%{
      "runId" => run.id,
      "agentId" => run.agent_id,
      "chatId" => run.chat_id,
      "decisionId" => decision.id,
      "kind" => kind,
      "capability" => request["capability"],
      "scope" => request["scope"],
      "reason" => request["reason"],
      "title" => request["title"] || approval_title(kind, request),
      "detail" => request["detail"] || request["reason"] || "",
      "risk" => request["risk"] || "external_effect",
      "actions" => request["actions"] || permission_actions(kind),
      "actionMode" => "single"
    })
  end

  defp maybe_request_approval(_run, _kind, _decision, _request), do: :ok

  defp approval_title("permission", request), do: "Allow access to #{request["capability"]}?"
  defp approval_title(_kind, _request), do: "Approve this action?"

  defp permission_actions("permission") do
    [
      %{"id" => "allow_once", "label" => "Allow once", "style" => "primary", "confirm" => nil},
      %{"id" => "allow_run", "label" => "Allow for this run", "style" => "primary", "confirm" => nil},
      %{"id" => "deny", "label" => "Deny", "style" => "destructive", "confirm" => nil}
    ]
  end

  defp permission_actions(_kind) do
    [
      %{"id" => "approve", "label" => "Approve", "style" => "primary", "confirm" => nil},
      %{"id" => "reject", "label" => "Reject", "style" => "destructive", "confirm" => nil}
    ]
  end

  defp changeset_summary(changeset), do: changeset.errors |> inspect() |> String.slice(0, 200)
end
