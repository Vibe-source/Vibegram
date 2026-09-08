defmodule VibeWeb.AgentBridgeChannel do
  @moduledoc """
  Channel for a user's paired computer.
  """
  use VibeWeb, :channel
  require Logger

  alias Vibe.AgentBridge
  alias Vibe.AI.LocalAgentWorker
  alias Vibe.Chat
  alias VibeWeb.Presence

  # Keep only the most recent stream-json lines per in-flight task so a long.
  @max_stream_lines 160

  @impl true
  def join("bridge:" <> topic_user_id, _payload, socket) do
    if topic_user_id == to_string(socket.assigns.user_id) do
      send(self(), :after_join)
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    computer_id = to_string(socket.assigns.computer_id)

    {:ok, _ref} =
      Presence.track(socket, computer_id, %{
        "online_at" => System.system_time(:second),
        "id" => computer_id,
        "computerId" => computer_id,
        "deviceLabel" => socket.assigns[:device_label] || "computer",
        "repositories" => []
      })

    push(socket, "bridge_identity", %{
      "computerId" => computer_id,
      "deviceLabel" => socket.assigns[:device_label] || "computer"
    })

    push(socket, "presence_state", Presence.list(socket))

    Logger.info(
      "[AgentBridge] computer online user=#{socket.assigns.user_id} computer=#{computer_id}"
    )

    AgentBridge.flush_pending_tasks(
      to_string(socket.assigns.user_id),
      computer_id,
      socket.assigns[:device_label] || "computer"
    )

    {:noreply, socket}
  end

  # daemon → server:
  @impl true
  def handle_in("status", payload, socket) do
    key = to_string(socket.assigns.computer_id)
    meta = AgentBridge.presence_meta(payload, key)

    case Presence.update(socket, key, meta) do
      {:ok, _ref} ->
        :ok

      {:error, _reason} ->
        Presence.track(socket, key, meta)
    end

    running =
      payload["runningTasks"] || payload["running_tasks"] || meta["runningTasks"] || []

    if is_list(running) do
      running
      |> Enum.group_by(fn task ->
        task["chatId"] || task["chat_id"] || task[:chatId]
      end)
      |> Enum.each(fn
        {chat_id, tasks} when is_binary(chat_id) ->
          LocalAgentWorker.rehydrate_team_workers_from_running_tasks(chat_id, tasks)

        _ ->
          :ok
      end)
    end

    {:reply, :ok, socket}
  end

  # daemon → server:
  @impl true
  def handle_in("progress", %{"provider" => provider, "chatId" => chat_id} = payload, socket) do
    received_at_ms = System.system_time(:millisecond)
    parse_start_ms = System.monotonic_time(:millisecond)
    line = payload["line"] || ""
    streams = Map.get(socket.assigns, :streams, %{})

    task_id = payload["taskId"] || payload["task_id"]
    team_run_id = payload["teamRunId"] || payload["team_run_id"]
    team_worker = payload["teamWorker"] || payload["team_worker"]

    maybe_handle_team_plan_line(line, chat_id, team_run_id, payload)
    maybe_handle_team_spawn_line(line, chat_id, team_run_id, payload, socket)
    maybe_handle_team_status_line(line, chat_id, team_run_id, socket)

    stream_key = stream_key(chat_id, provider, task_id, team_run_id, team_worker)

    state =
      Map.get(streams, stream_key, %{
        lines: [],
        stream_id: new_stream_id(chat_id, provider, task_id),
        progress_count: 0,
        progress_bytes: 0,
        last_latency_log_at: 0
      })

    lines = Enum.take([line | state.lines], @max_stream_lines)
    accumulated = lines |> Enum.reverse() |> Enum.join("\n")
    task_id = task_id || Map.get(state, :task_id)
    progress_count = (Map.get(state, :progress_count) || 0) + 1
    progress_bytes = (Map.get(state, :progress_bytes) || 0) + byte_size(line)

    source_message_id =
      payload["sourceMessageId"] ||
        payload["source_message_id"] ||
        payload["replyToId"] ||
        payload["reply_to_id"] ||
        Map.get(state, :source_message_id)

    state =
      Map.merge(state, %{
        lines: lines,
        task_id: task_id,
        source_message_id: source_message_id,
        repo_name: payload["repoName"] || payload["repo_name"] || Map.get(state, :repo_name),
        cwd: payload["cwd"] || Map.get(state, :cwd),
        work_mode: payload["workMode"] || payload["work_mode"] || Map.get(state, :work_mode),
        model: payload["model"] || Map.get(state, :model),
        advisor: payload["advisor"] || Map.get(state, :advisor),
        progress_count: progress_count,
        progress_bytes: progress_bytes,
        bridge_sent_at_ms:
          payload["sentAtMs"] || payload["sent_at_ms"] || Map.get(state, :bridge_sent_at_ms),
        sequence: payload["sequence"] || Map.get(state, :sequence),
        team_mode: payload["teamMode"] || payload["team_mode"] || Map.get(state, :team_mode),
        team_run_id:
          payload["teamRunId"] || payload["team_run_id"] || Map.get(state, :team_run_id),
        team_worker:
          payload["teamWorker"] || payload["team_worker"] || Map.get(state, :team_worker),
        team_workers:
          payload["teamWorkers"] || payload["team_workers"] || Map.get(state, :team_workers),
        lead_worker:
          payload["leadWorker"] || payload["lead_worker"] || Map.get(state, :lead_worker),
        team_role: payload["teamRole"] || payload["team_role"] || Map.get(state, :team_role),
        suppress_visible:
          payload["suppressVisible"] == true or payload["suppress_visible"] == true or
            Map.get(state, :suppress_visible) == true,
        computer_id:
          payload["computerId"] || payload["computer_id"] || Map.get(state, :computer_id),
        computer_label:
          payload["computerLabel"] || payload["computer_label"] ||
            Map.get(state, :computer_label)
      })

    LocalAgentWorker.bridge_stream_update(provider, chat_id, accumulated, state.stream_id, %{
      task_id: state.task_id,
      source_message_id: state.source_message_id,
      reply_to_id: state.source_message_id,
      repo_name: state.repo_name,
      cwd: state.cwd,
      work_mode: state.work_mode,
      model: state.model,
      advisor: state.advisor,
      bridge_sent_at_ms: state.bridge_sent_at_ms,
      server_received_at_ms: received_at_ms,
      sequence: state.sequence,
      progress_bytes: state.progress_bytes,
      team_mode: state.team_mode,
      team_run_id: state.team_run_id,
      team_worker: state.team_worker,
      team_workers: state.team_workers,
      lead_worker: state.lead_worker,
      team_role: state.team_role,
      suppress_visible: state.suppress_visible,
      computer_id: state.computer_id,
      computer_label: state.computer_label
    })

    parse_ms = System.monotonic_time(:millisecond) - parse_start_ms
    bridge_lag_ms = bridge_lag_ms(state.bridge_sent_at_ms, received_at_ms)
    last_log_at = Map.get(state, :last_latency_log_at) || 0
    now_mono = System.monotonic_time(:millisecond)

    should_log =
      progress_count <= 3 or rem(progress_count, 10) == 0 or parse_ms > 250 or
        now_mono - last_log_at > 5_000

    state =
      if should_log do
        Logger.info(
          "[AgentBridge] progress latency provider=#{provider} chat=#{chat_id} task=#{inspect(task_id)} seq=#{inspect(state.sequence)} count=#{progress_count} bridgeLagMs=#{inspect(bridge_lag_ms)} parseMs=#{parse_ms} bytes=#{progress_bytes} bufferedBytes=#{byte_size(accumulated)} lines=#{length(lines)}"
        )

        Map.put(state, :last_latency_log_at, now_mono)
      else
        state
      end

    {:reply, :ok, assign(socket, :streams, Map.put(streams, stream_key, state))}
  end

  # daemon → server:
  def handle_in("result", payload, socket) do
    provider = payload["provider"]
    chat_id = payload["chatId"]

    {socket, stream_id} = detach_stream(socket, chat_id, provider, payload)

    Logger.info(
      "[AgentBridge] result received user=#{socket.assigns.user_id} provider=#{inspect(provider)} chat=#{inspect(chat_id)} exit=#{inspect(payload["exitStatus"])} outputBytes=#{byte_size(payload["output"] || "")}"
    )

    owner_in_chat = bridge_owns_chat?(socket, chat_id)

    if is_binary(provider) and is_binary(chat_id) and not owner_in_chat do
      Logger.warning(
        "[AgentBridge] result REJECTED — bridge owner not a participant of chat user=#{socket.assigns.user_id} chat=#{inspect(chat_id)}"
      )
    end

    if is_binary(provider) and owner_in_chat do
      output = payload["output"] || ""
      exit_status = payload["exitStatus"] || 0
      duration_ms = payload["durationMs"] || 0
      reply_to_id = payload["replyToId"]
      requester_user_id = payload["requesterUserId"] || to_string(socket.assigns.user_id)

      Task.start(fn ->
        try do
          LocalAgentWorker.deliver_bridge_result(
            provider,
            chat_id,
            output,
            exit_status,
            duration_ms,
            reply_to_id: reply_to_id,
            requester_user_id: requester_user_id,
            runtime: payload["agentRuntime"] || payload["agent_runtime"],
            runtime_enc: payload["agentRuntimeEnc"] || payload["agent_runtime_enc"],
            agent_actions_enc: payload["agentActionsEnc"] || payload["agent_actions_enc"],
            can_revert: payload["canRevert"] || payload["can_revert"] || false,
            team_mode: payload["teamMode"] || payload["team_mode"],
            team_run_id: payload["teamRunId"] || payload["team_run_id"],
            team_worker: payload["teamWorker"] || payload["team_worker"],
            team_workers: payload["teamWorkers"] || payload["team_workers"],
            lead_worker: payload["leadWorker"] || payload["lead_worker"],
            team_role: payload["teamRole"] || payload["team_role"],
            suppress_visible:
              payload["suppressVisible"] == true or payload["suppress_visible"] == true,
            task_id: payload["taskId"] || payload["task_id"],
            computer_id: payload["computerId"] || payload["computer_id"],
            computer_label: payload["computerLabel"] || payload["computer_label"],
            usage_limit_hit:
              payload["usageLimitHit"] == true or payload["usage_limit_hit"] == true
          )
        rescue
          err ->
            Logger.error(
              "[AgentBridge] deliver_bridge_result crashed chat=#{chat_id} provider=#{provider} error=#{Exception.message(err)}\n#{Exception.format(:error, err, __STACKTRACE__)}"
            )
        after
          if is_binary(stream_id) do
            LocalAgentWorker.finish_stream(provider, chat_id, stream_id)
          end

          LocalAgentWorker.stop_activity(chat_id, agent_user_id_for(provider))
        end
      end)
    else
      if is_binary(stream_id) and is_binary(provider) and is_binary(chat_id) do
        LocalAgentWorker.finish_stream(provider, chat_id, stream_id)
      end
    end

    {:reply, :ok, socket}
  end

  # daemon → server:
  def handle_in("history_result", payload, socket) when is_map(payload) do
    chat_id = payload["chatId"] || payload["chat_id"]

    if bridge_owns_chat?(socket, chat_id) do
      VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-bridge-history", payload)
    else
      Logger.info(
        "[AgentBridge] history_result not relayed (no chatId or owner not a participant) user=#{socket.assigns.user_id} chat=#{inspect(chat_id)} requestId=#{inspect(payload["requestId"])}"
      )
    end

    {:reply, :ok, socket}
  end

  # daemon → server:
  def handle_in("file_result", payload, socket) when is_map(payload) do
    chat_id = payload["chatId"] || payload["chat_id"]

    if bridge_owns_chat?(socket, chat_id) do
      VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-bridge-file", payload)
    else
      Logger.info(
        "[AgentBridge] file_result not relayed (no chatId or owner not a participant) user=#{socket.assigns.user_id} chat=#{inspect(chat_id)} requestId=#{inspect(payload["requestId"])}"
      )
    end

    {:reply, :ok, socket}
  end

  # daemon → server:
  def handle_in("usage_result", payload, socket) when is_map(payload) do
    chat_id = payload["chatId"] || payload["chat_id"]

    if bridge_owns_chat?(socket, chat_id) do
      VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-bridge-usage", payload)
    else
      Logger.info(
        "[AgentBridge] usage_result not relayed (no chatId or owner not a participant) user=#{socket.assigns.user_id} chat=#{inspect(chat_id)} requestId=#{inspect(payload["requestId"])}"
      )
    end

    {:reply, :ok, socket}
  end

  # daemon → server:
  def handle_in("ask_request", payload, socket) when is_map(payload) do
    chat_id = payload["chatId"] || payload["chat_id"]

    if bridge_owns_chat?(socket, chat_id) do
      Logger.info(
        "[AgentBridge][ask] relay user=#{socket.assigns.user_id} chat=#{chat_id} " <>
          "requestId=#{inspect(payload["requestId"])} kind=#{inspect(payload["kind"])} " <>
          "sealed=#{Map.has_key?(payload, "askEnc")} → broadcast chat:#{chat_id}/agent-bridge-ask"
      )

      request_id = payload["requestId"] || payload["request_id"]

      if is_binary(request_id) do
        Vibe.AgentBridge.remember_pending_ask(chat_id, request_id, payload)
      end

      VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-bridge-ask", payload)
    else
      Logger.info(
        "[AgentBridge][ask] DROPPED — no chatId user=#{socket.assigns.user_id} requestId=#{inspect(payload["requestId"])}"
      )
    end

    {:reply, :ok, socket}
  end

  # daemon → server:
  def handle_in("ask_cancel", payload, socket) when is_map(payload) do
    chat_id = payload["chatId"] || payload["chat_id"]
    request_id = payload["requestId"] || payload["request_id"]

    if bridge_owns_chat?(socket, chat_id) do
      Logger.info(
        "[AgentBridge][ask] cancel user=#{socket.assigns.user_id} chat=#{chat_id} " <>
          "requestId=#{inspect(request_id)} reason=<redacted #{byte_size(inspect(payload["reason"] || ""))} bytes> " <>
          "→ broadcast chat:#{chat_id}/agent-bridge-ask-cancel"
      )

      if is_binary(request_id) do
        Vibe.AgentBridge.clear_pending_ask(chat_id, request_id)
      end

      VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-bridge-ask-cancel", payload)
    else
      Logger.info(
        "[AgentBridge][ask] cancel DROPPED — no chatId user=#{socket.assigns.user_id} requestId=#{inspect(request_id)}"
      )
    end

    {:reply, :ok, socket}
  end

  # daemon → server:
  def handle_in("control_result", payload, socket) do
    control_type = payload["type"] || payload["action"] || payload["event"]
    control_id = payload["id"] || payload["requestId"] || payload["request_id"]

    Logger.info(
      "[AgentBridge] control_result user=#{socket.assigns.user_id} type=#{inspect(control_type)} id=#{inspect(control_id)} payload=<redacted>"
    )

    {:reply, :ok, socket}
  end

  # daemon → server:
  def handle_in("team_spawn", payload, socket) when is_map(payload) do
    chat_id = payload["chatId"] || payload["chat_id"]
    team_run_id = payload["teamRunId"] || payload["team_run_id"]
    handles = payload["workers"] || payload["handles"] || []
    focus = payload["focusByHandle"] || payload["focus_by_handle"] || %{}
    requester = payload["requesterUserId"] || to_string(socket.assigns.user_id)

    if bridge_owns_chat?(socket, chat_id) and is_binary(team_run_id) and is_list(handles) do
      LocalAgentWorker.spawn_supervisor_workers(
        chat_id,
        team_run_id,
        handles,
        requester,
        focus_by_handle: stringify_map_keys(focus)
      )
    end

    {:reply, :ok, socket}
  end

  # daemon → server:
  def handle_in("error", %{"provider" => provider, "chatId" => chat_id} = payload, socket) do
    Logger.info(
      "[AgentBridge] error received user=#{socket.assigns.user_id} provider=#{inspect(provider)} chat=#{inspect(chat_id)} message=<redacted #{byte_size(inspect(payload["message"] || ""))} bytes>"
    )

    message = payload["message"] || "The task could not be completed on your computer."

    if bridge_owns_chat?(socket, chat_id) do
      LocalAgentWorker.post_bridge_notice(
        provider,
        chat_id,
        message,
        to_string(socket.assigns.user_id),
        payload["replyToId"]
      )

      LocalAgentWorker.fail_bridge_team_run(
        chat_id,
        payload["teamRunId"] || payload["team_run_id"],
        payload["teamWorker"] || payload["team_worker"] || provider,
        message
      )

      LocalAgentWorker.stop_activity(chat_id, agent_user_id_for(provider))
    else
      Logger.warning(
        "[AgentBridge] error notice REJECTED — bridge owner not a participant of chat user=#{socket.assigns.user_id} chat=#{inspect(chat_id)}"
      )
    end

    {:reply, :ok, clear_stream(socket, chat_id, provider, payload)}
  end

  def handle_in("heartbeat", _payload, socket), do: {:reply, :ok, socket}
  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  defp maybe_handle_team_plan_line(line, chat_id, team_run_id, payload)
       when is_binary(line) and is_binary(chat_id) and is_binary(team_run_id) do
    role = payload["teamRole"] || payload["team_role"]
    lead = payload["leadWorker"] || payload["lead_worker"]
    worker = payload["teamWorker"] || payload["team_worker"] || payload["provider"]

    if role == "lead" or (is_binary(lead) and lead == worker) or is_nil(role) do
      roster = LocalAgentWorker.team_run_roster(chat_id, team_run_id)

      case LocalAgentWorker.parse_team_plan_directive(line, roster) do
        {:ok, plan} ->
          LocalAgentWorker.store_team_plan(chat_id, team_run_id, plan)

        {:error, reasons} ->
          Logger.warning(
            "[AgentBridgeChannel] rejected team plan chat=#{chat_id} run=#{team_run_id}: #{Enum.join(reasons, "; ")}"
          )

        nil ->
          :ok
      end
    end

    :ok
  end

  defp maybe_handle_team_plan_line(_, _, _, _), do: :ok

  defp maybe_handle_team_spawn_line(line, chat_id, team_run_id, payload, socket)
       when is_binary(line) and is_binary(chat_id) and is_binary(team_run_id) do
    case LocalAgentWorker.parse_team_spawn_directive(line) do
      %{handles: handles, focus_by_handle: focus} when handles != [] ->
        role = payload["teamRole"] || payload["team_role"]
        lead = payload["leadWorker"] || payload["lead_worker"]
        worker = payload["teamWorker"] || payload["team_worker"] || payload["provider"]

        if bridge_owns_chat?(socket, chat_id) and
             (role == "lead" or (is_binary(lead) and lead == worker) or is_nil(role)) do
          LocalAgentWorker.spawn_supervisor_workers(
            chat_id,
            team_run_id,
            handles,
            payload["requesterUserId"] || to_string(socket.assigns.user_id),
            focus_by_handle: focus
          )
        end

      _ ->
        :ok
    end
  end

  defp maybe_handle_team_spawn_line(_, _, _, _, _), do: :ok

  defp maybe_handle_team_status_line(line, chat_id, team_run_id, socket)
       when is_binary(line) and is_binary(chat_id) and is_binary(team_run_id) do
    if bridge_owns_chat?(socket, chat_id) do
      case parse_team_status_line(line) do
        {:ok, %{"worker" => worker, "state" => state, "label" => label}} ->
          LocalAgentWorker.update_team_worker_state(
            chat_id,
            team_run_id,
            worker,
            team_status_patch(state, label)
          )

        :ignore ->
          :ok
      end
    else
      :ok
    end
  end

  defp maybe_handle_team_status_line(_, _, _, _), do: :ok

  @doc """
  Parse one `VIBE_TEAM_STATUS {json}` line emitted by a team worker.
  """
  def parse_team_status_line(line) when is_binary(line) do
    with [_, raw] <- Regex.run(~r/VIBE_TEAM_STATUS\s+(\{.*\})\s*$/i, line),
         {:ok, status} when is_map(status) <- Jason.decode(raw),
         worker when is_binary(worker) and worker != "" <- Map.get(status, "worker"),
         state when state in ["spawn", "starting", "running", "done", "failed"] <-
           Map.get(status, "state"),
         label <- Map.get(status, "label"),
         true <- is_nil(label) or is_binary(label) do
      {:ok, %{"worker" => worker, "state" => state, "label" => label}}
    else
      _ -> :ignore
    end
  end

  def parse_team_status_line(_), do: :ignore

  defp team_status_patch(state, label) when state in ["spawn", "starting"] do
    %{"status" => "starting", "last_label" => label}
  end

  defp team_status_patch("running", label) do
    %{"status" => "running", "last_label" => label}
  end

  defp team_status_patch("done", label) do
    %{"status" => "done", "last_label" => label}
  end

  defp team_status_patch("failed", label) do
    %{"status" => "failed", "last_label" => label}
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_map_keys(_), do: %{}

  defp bridge_lag_ms(value, received_at_ms) when is_integer(value), do: received_at_ms - value

  defp bridge_lag_ms(value, received_at_ms) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> received_at_ms - int
      _ -> nil
    end
  end

  defp bridge_lag_ms(_, _), do: nil

  defp stream_key(chat_id, provider, task_id, team_run_id, team_worker) do
    [chat_id, provider, task_id || team_run_id, team_worker]
    |> Enum.map(&to_string(&1 || "-"))
    |> Enum.join("|")
  end

  defp new_stream_id(chat_id, provider, task_id) do
    suffix = if is_binary(provider) and provider != "", do: provider <> "-", else: ""

    task_suffix =
      case task_id do
        value when is_binary(value) and value != "" -> String.slice(value, -12, 12) <> "-"
        _ -> ""
      end

    "stream-" <>
      chat_id <>
      "-" <>
      suffix <>
      task_suffix <>
      Integer.to_string(System.system_time(:millisecond))
  end

  defp detach_stream(socket, chat_id, provider, payload) when is_binary(chat_id) do
    streams = Map.get(socket.assigns, :streams, %{})

    key =
      stream_key(
        chat_id,
        provider,
        payload["taskId"] || payload["task_id"],
        payload["teamRunId"] || payload["team_run_id"],
        payload["teamWorker"] || payload["team_worker"]
      )

    case Map.pop(streams, key) do
      {nil, _streams} -> {socket, nil}
      {state, rest} -> {assign(socket, :streams, rest), state.stream_id}
    end
  end

  defp detach_stream(socket, _chat_id, _provider, _payload), do: {socket, nil}

  defp clear_stream(socket, chat_id, provider, payload) when is_binary(chat_id) do
    streams = Map.get(socket.assigns, :streams, %{})

    key =
      stream_key(
        chat_id,
        provider,
        payload["taskId"] || payload["task_id"],
        payload["teamRunId"] || payload["team_run_id"],
        payload["teamWorker"] || payload["team_worker"]
      )

    case Map.pop(streams, key) do
      {nil, _streams} ->
        socket

      {state, rest} ->
        if is_binary(provider),
          do: LocalAgentWorker.finish_stream(provider, chat_id, state.stream_id)

        assign(socket, :streams, rest)
    end
  end

  defp clear_stream(socket, _chat_id, _provider, _payload), do: socket

  defp agent_user_id_for(provider) do
    case LocalAgentWorker.resolve_handle(provider) do
      nil -> LocalAgentWorker.agent_user_id()
      worker -> worker.agent_user_id
    end
  end

  defp bridge_owns_chat?(socket, chat_id) do
    is_binary(chat_id) and chat_id != "" and
      Chat.is_participant?(chat_id, socket.assigns.user_id)
  end
end
