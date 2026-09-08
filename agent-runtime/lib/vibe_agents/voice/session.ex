defmodule VibeAgents.Voice.Session do
  @moduledoc """
  Per-call GenServer: owns the provider pid, forwards channel<->provider frames, and
  authorizes tool calls via VibeAgents.Broker (falling back to ToolRisk) then
  VibeAgents.Tools.Executor, so approvals follow the same policy as text runs.
  One per session_id. See docs/agent-voice-v1.md.
  """
  use GenServer
  require Logger

  alias VibeAgents.Voice.{Audio, SafeApply, ToolRisk}

  @max_seconds_default 1800
  @idle_ms 90_000
  @audio_window_ms 60_000
  @audio_bytes_per_min_limit 4_000_000
  @image_max_bytes 300_000
  @image_min_interval_ms 1_000
  @decision_ttl_seconds 120
  @channel_grace_ms 15_000

  defstruct [
    :session_id,
    :agent_id,
    :user_id,
    :chat_id,
    :agent_profile,
    :channel_pid,
    :channel_ref,
    :channel_grace_timer,
    :provider_mod,
    :provider_pid,
    :idle_timer,
    :max_timer,
    audio_seq: 0,
    audio_window_started_at: nil,
    audio_window_bytes: 0,
    last_image_at: nil,
    pending_decisions: %{},
    ended: false
  ]

  # --- public API (called from VibeAgentsWeb.VoiceChannel) ---

  @doc "Starts a new session's GenServer, or attaches channel_pid to an existing one."
  @spec join(String.t(), map(), pid()) :: {:ok, pid()} | {:error, term()}
  def join(session_id, record, channel_pid) do
    case Registry.lookup(VibeAgents.Voice.Registry, session_id) do
      [{pid, _value}] ->
        :ok = GenServer.call(pid, {:attach, channel_pid})
        {:ok, pid}

      [] ->
        attrs = Map.put(record, :channel_pid, channel_pid)

        case DynamicSupervisor.start_child(VibeAgents.Voice.Supervisor, {__MODULE__, attrs}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            :ok = GenServer.call(pid, {:attach, channel_pid})
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def start_link(%{session_id: session_id} = attrs) do
    GenServer.start_link(__MODULE__, attrs, name: via(session_id))
  end

  defp via(session_id), do: {:via, Registry, {VibeAgents.Voice.Registry, session_id}}


  @impl true
  def init(attrs) do
    Process.flag(:trap_exit, true)
    channel_ref = Process.monitor(attrs.channel_pid)
    now_ms = System.monotonic_time(:millisecond)

    state = %__MODULE__{
      session_id: attrs.session_id,
      agent_id: attrs.agent_id,
      user_id: attrs.user_id,
      chat_id: attrs.chat_id,
      agent_profile: attrs.agent_profile,
      channel_pid: attrs.channel_pid,
      channel_ref: channel_ref,
      provider_mod: Application.get_env(:vibe_agents, :voice_provider, VibeAgents.Voice.OpenAIRealtime),
      audio_window_started_at: now_ms
    }

    provider_opts = [owner: self(), agent_profile: state.agent_profile]

    case state.provider_mod.start_link(provider_opts) do
      {:ok, provider_pid} ->
        state = state |> Map.put(:provider_pid, provider_pid) |> schedule_idle() |> schedule_max()
        {:ok, state}

      {:error, reason} ->
        Logger.warning("[VibeAgents.Voice.Session] provider start failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:attach, channel_pid}, _from, state) do
    if state.channel_grace_timer, do: Process.cancel_timer(state.channel_grace_timer)
    if state.channel_ref, do: Process.demonitor(state.channel_ref, [:flush])
    ref = Process.monitor(channel_pid)
    {:reply, :ok, %{state | channel_pid: channel_pid, channel_ref: ref, channel_grace_timer: nil}}
  end

  @impl true
  def handle_cast({:frame, "audio.chunk", payload}, state), do: handle_audio_chunk(payload, state)

  def handle_cast({:frame, "audio.end", _payload}, state) do
    if state.provider_pid, do: state.provider_mod.commit(state.provider_pid)
    {:noreply, touch_activity(state)}
  end

  def handle_cast({:frame, "interrupt", _payload}, state) do
    if state.provider_pid, do: state.provider_mod.interrupt(state.provider_pid)
    {:noreply, state}
  end

  def handle_cast({:frame, "text.message", %{"text" => text}}, state) when is_binary(text) do
    if state.provider_pid, do: state.provider_mod.send_text(state.provider_pid, text)
    {:noreply, touch_activity(state)}
  end

  def handle_cast({:frame, "image.frame", %{"jpegBase64" => b64}}, state) when is_binary(b64),
    do: handle_image_frame(b64, state)

  def handle_cast({:frame, "decision", payload}, state), do: handle_decision(payload, state)

  def handle_cast({:frame, "hangup", _payload}, state) do
    {:stop, :normal, end_session(state, "hangup")}
  end

  def handle_cast({:frame, _event, _payload}, state), do: {:noreply, state}

  @impl true
  def handle_info({:voice_provider, event}, state), do: handle_provider_event(event, state)

  def handle_info(:idle_timeout, state), do: {:stop, :normal, end_session(state, "idle")}
  def handle_info(:max_duration, state), do: {:stop, :normal, end_session(state, "max_duration")}

  def handle_info({:EXIT, pid, reason}, %{provider_pid: pid} = state) do
    Logger.warning("[VibeAgents.Voice.Session] provider exited: #{inspect(reason)}")
    {:stop, :normal, end_session(state, "provider_error")}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{channel_ref: ref} = state) do
    timer = Process.send_after(self(), :channel_grace_expired, @channel_grace_ms)
    {:noreply, %{state | channel_pid: nil, channel_grace_timer: timer}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:channel_grace_expired, %{channel_pid: nil} = state),
    do: {:stop, :normal, end_session(state, "error")}

  def handle_info(:channel_grace_expired, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    end_session(state, "error")
    :ok
  end


  defp handle_provider_event({:ready}, state) do
    push_to_channel(state, "session.ready", %{
      sessionId: state.session_id,
      model: Application.get_env(:vibe_agents, :voice_model, "gpt-realtime"),
      voice: Application.get_env(:vibe_agents, :voice_voice, "marin"),
      sampleRate: 24_000
    })

    {:noreply, state}
  end

  defp handle_provider_event({:transcript_user, text, final?}, state) do
    push_to_channel(state, "transcript.user", %{text: text, final: final?})
    {:noreply, touch_activity(state)}
  end

  defp handle_provider_event({:transcript_agent, text, final?}, state) do
    push_to_channel(state, "transcript.agent", %{text: text, final: final?})
    {:noreply, touch_activity(state)}
  end

  defp handle_provider_event({:audio, pcm16}, state) do
    seq = state.audio_seq + 1

    push_to_channel(state, "audio.chunk", %{
      seq: seq,
      codec: "pcm16le",
      sampleRate: 24_000,
      dataBase64: Base.encode64(pcm16)
    })

    {:noreply, touch_activity(%{state | audio_seq: seq})}
  end

  defp handle_provider_event({:tool_call, call_id, name, input}, state),
    do: {:noreply, dispatch_tool_call(state, call_id, name, input)}

  defp handle_provider_event({:error, reason}, state) do
    push_to_channel(state, "error", %{code: "provider_error", message: inspect(reason)})
    {:noreply, state}
  end

  defp handle_provider_event({:done}, state), do: {:stop, :normal, end_session(state, "provider_error")}
  defp handle_provider_event(_event, state), do: {:noreply, state}


  defp dispatch_tool_call(state, call_id, name, input) do
    case authorize_tool_call(state, name, input) do
      :run ->
        execute_tool(state, call_id, name, input)

      {:approval, request} ->
        request_decision(state, call_id, name, input, request)

      {:ask, questions} ->
        push_to_channel(state, "tool.progress", %{label: name, tool: name, status: "done"})

        send_tool_result(state, call_id, %{
          "ok" => true,
          "questions" => questions,
          "note" => "ask the user directly by speaking; their reply arrives as the next user turn"
        })

        state

      {:deny, reason} ->
        push_to_channel(state, "tool.progress", %{label: name, tool: name, status: "error"})
        send_tool_result(state, call_id, %{"error" => "not_permitted", "reason" => to_string(reason)})
        state
    end
  end

  defp authorize_tool_call(state, name, input) do
    run = %{"agent_profile" => state.agent_profile}
    SafeApply.call(VibeAgents.Broker, :authorize, [run, name, input], fallback_authorize(state, name, input))
  end

  defp fallback_authorize(_state, "ask_user", input), do: {:ask, input["questions"] || []}

  defp fallback_authorize(_state, "request_approval", input) do
    {:approval, %{
      "title" => input["title"] || input["action"] || "Approval requested",
      "detail" => input["detail"] || input["reason"] || ""
    }}
  end

  defp fallback_authorize(state, name, input) do
    risk = ToolRisk.classify(name)
    autonomy_mode = state.agent_profile["autonomyMode"] || "approval_required"
    approval_rules = state.agent_profile["approvalRules"] || %{}

    case ToolRisk.decision(risk, name, autonomy_mode, approval_rules) do
      :run -> :run
      :approval -> {:approval, %{"title" => "Run #{name}?", "detail" => inspect_input(input)}}
      :plan_only -> {:deny, "autonomy_mode requires manual execution"}
    end
  end

  defp inspect_input(input) when is_map(input) do
    case Jason.encode(input) do
      {:ok, json} -> String.slice(json, 0, 300)
      {:error, _reason} -> ""
    end
  end

  defp inspect_input(_input), do: ""

  defp request_decision(state, call_id, name, input, request) do
    decision_id = Ecto.UUID.generate()
    expires_at = DateTime.utc_now() |> DateTime.add(@decision_ttl_seconds, :second) |> DateTime.to_iso8601()

    push_to_channel(state, "tool.progress", %{label: name, tool: name, status: "running"})

    push_to_channel(state, "approval.requested", %{
      decisionId: decision_id,
      tool: name,
      risk: request["risk"],
      title: request["title"] || "Run #{name}?",
      detail: request["detail"] || inspect_input(input),
      actions: request["actions"] || default_actions(),
      expiresAt: expires_at
    })

    pending = %{call_id: call_id, tool_name: name, input: input}
    %{state | pending_decisions: Map.put(state.pending_decisions, decision_id, pending)}
  end

  defp default_actions do
    [
      %{"id" => "approve", "label" => "Approve", "style" => "primary"},
      %{"id" => "reject", "label" => "Reject", "style" => "destructive"}
    ]
  end

  defp execute_tool(state, call_id, name, input) do
    push_to_channel(state, "tool.progress", %{label: name, tool: name, status: "running"})

    run = %{
      id: nil,
      agent_id: state.agent_id,
      agent_user_id: nil,
      owner_user_id: state.user_id,
      chat_id: state.chat_id,
      agent_profile: state.agent_profile,
      capabilities: %{"computer" => true, "browser" => true},
      source: "voice"
    }

    exec_state = %{
      run: run,
      run_id: nil,
      agent_id: state.agent_id,
      chat_id: state.chat_id,
      tool_failures: 0,
      granted_capabilities: MapSet.new()
    }

    tool = %{"id" => call_id, "name" => name, "input" => input || %{}}

    result =
      SafeApply.call(
        VibeAgents.Tools.Executor,
        :execute_authorized,
        [tool, exec_state, fn _event -> :ok end],
        {:error, :tool_executor_unavailable}
      )

    normalized = normalize_result(result)
    failed? = match?(%{"ok" => false}, normalized) or Map.has_key?(normalized, "error")
    push_to_channel(state, "tool.progress", %{label: name, tool: name, status: if(failed?, do: "error", else: "done")})
    send_tool_result(state, call_id, normalized)
    state
  end

  defp normalize_result({:ok, value}) when is_map(value), do: value
  defp normalize_result({:ok, value}), do: %{"ok" => true, "result" => value}
  defp normalize_result({:error, reason}), do: %{"ok" => false, "error" => inspect(reason)}
  defp normalize_result(other) when is_map(other), do: other
  defp normalize_result(other), do: %{"ok" => true, "result" => inspect(other)}

  defp send_tool_result(state, call_id, result) do
    if state.provider_pid, do: state.provider_mod.tool_result(state.provider_pid, call_id, result)
  end

  defp handle_decision(%{"decisionId" => decision_id, "outcome" => outcome} = payload, state) do
    case Map.pop(state.pending_decisions, decision_id) do
      {nil, _pending_decisions} ->
        push_to_channel(state, "error", %{
          code: "unknown_decision",
          message: "no pending decision #{decision_id}"
        })

        {:noreply, state}

      {pending, pending_decisions} ->
        state = %{state | pending_decisions: pending_decisions}
        state = resolve_decision(pending, outcome, payload["answer"], state)
        {:noreply, state}
    end
  end

  defp handle_decision(_payload, state), do: {:noreply, state}

  defp resolve_decision(%{call_id: call_id, tool_name: name, input: input}, outcome, _answer, state)
       when outcome in ["approve", "allow_once", "allow_run"] do
    execute_tool(state, call_id, name, input)
  end

  defp resolve_decision(%{call_id: call_id, tool_name: name}, _outcome, _answer, state) do
    push_to_channel(state, "tool.progress", %{label: name, tool: name, status: "error"})
    send_tool_result(state, call_id, %{"error" => "denied_by_user"})
    state
  end


  defp handle_audio_chunk(%{"dataBase64" => b64} = payload, state) do
    sample_rate = payload["sampleRate"] || 24_000

    case Base.decode64(b64) do
      {:ok, raw} ->
        {state, allowed?} = check_audio_budget(state, byte_size(raw))

        if allowed? do
          pcm16 = if sample_rate == 16_000, do: Audio.resample_16k_to_24k(raw), else: raw
          if state.provider_pid, do: state.provider_mod.send_audio(state.provider_pid, pcm16)
        else
          push_to_channel(state, "error", %{
            code: "audio_rate_limit",
            message: "audio input rate limit exceeded"
          })
        end

        {:noreply, touch_activity(state)}

      :error ->
        {:noreply, state}
    end
  end

  defp handle_audio_chunk(_payload, state), do: {:noreply, state}

  defp check_audio_budget(state, bytes) do
    now = System.monotonic_time(:millisecond)

    state =
      if now - state.audio_window_started_at >= @audio_window_ms do
        %{state | audio_window_started_at: now, audio_window_bytes: 0}
      else
        state
      end

    total = state.audio_window_bytes + bytes

    if total > @audio_bytes_per_min_limit do
      {state, false}
    else
      {%{state | audio_window_bytes: total}, true}
    end
  end

  defp handle_image_frame(b64, state) do
    now = System.monotonic_time(:millisecond)

    if state.last_image_at && now - state.last_image_at < @image_min_interval_ms do
      {:noreply, state}
    else
      case Base.decode64(b64) do
        {:ok, jpeg} when byte_size(jpeg) <= @image_max_bytes ->
          if state.provider_pid, do: state.provider_mod.send_image(state.provider_pid, jpeg)
          {:noreply, touch_activity(%{state | last_image_at: now})}

        {:ok, _jpeg} ->
          push_to_channel(state, "error", %{code: "image_too_large", message: "image exceeds 300 KB"})
          {:noreply, state}

        :error ->
          {:noreply, state}
      end
    end
  end


  defp schedule_idle(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: Process.send_after(self(), :idle_timeout, @idle_ms)}
  end

  defp schedule_max(state) do
    max_seconds = Application.get_env(:vibe_agents, :voice_max_seconds, @max_seconds_default)
    %{state | max_timer: Process.send_after(self(), :max_duration, max_seconds * 1_000)}
  end

  defp touch_activity(state), do: schedule_idle(state)

  defp end_session(%{ended: true} = state, _reason), do: state

  defp end_session(state, reason) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    if state.max_timer, do: Process.cancel_timer(state.max_timer)
    if state.provider_pid, do: state.provider_mod.stop(state.provider_pid)
    push_to_channel(state, "session.ended", %{reason: reason})
    %{state | ended: true}
  end

  defp push_to_channel(%{channel_pid: nil}, _event, _payload), do: :ok
  defp push_to_channel(state, event, payload), do: send(state.channel_pid, {:voice_frame, event, payload})
end
