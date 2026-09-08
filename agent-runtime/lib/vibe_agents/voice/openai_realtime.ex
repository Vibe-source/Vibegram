defmodule VibeAgents.Voice.OpenAIRealtime do
  @moduledoc """
  VibeAgents.Voice.Provider adapter over OpenAI's Realtime API via Mint.WebSocket.
  See docs/agent-voice-v1.md §5 for the exact event mapping and a flagged schema assumption.
  """
  @behaviour VibeAgents.Voice.Provider

  use GenServer
  require Logger

  alias VibeAgents.Voice.SafeApply

  defstruct [
    :owner,
    :conn,
    :ref,
    :websocket,
    :status,
    :resp_headers,
    :model,
    :voice,
    :instructions,
    :tools,
    :api_key,
    ready: false,
    fn_calls: %{}
  ]

  # --- VibeAgents.Voice.Provider ---

  @impl VibeAgents.Voice.Provider
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl VibeAgents.Voice.Provider
  def send_audio(pid, pcm16) when is_binary(pcm16), do: GenServer.cast(pid, {:send_audio, pcm16})

  @impl VibeAgents.Voice.Provider
  def send_text(pid, text) when is_binary(text), do: GenServer.cast(pid, {:send_text, text})

  @impl VibeAgents.Voice.Provider
  def send_image(pid, jpeg) when is_binary(jpeg), do: GenServer.cast(pid, {:send_image, jpeg})

  @impl VibeAgents.Voice.Provider
  def commit(pid), do: GenServer.cast(pid, :commit)

  @impl VibeAgents.Voice.Provider
  def interrupt(pid), do: GenServer.cast(pid, :interrupt)

  @impl VibeAgents.Voice.Provider
  def tool_result(pid, call_id, result), do: GenServer.cast(pid, {:tool_result, call_id, result})

  @impl VibeAgents.Voice.Provider
  def stop(pid), do: GenServer.stop(pid, :normal)


  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    agent_profile = Keyword.get(opts, :agent_profile, %{})
    capabilities = Keyword.get(opts, :capabilities, %{"computer" => true, "browser" => true})
    api_key = Application.get_env(:vibe_agents, :openai_api_key)

    if api_key in [nil, ""] do
      {:stop, :missing_api_key}
    else
      state = %__MODULE__{
        owner: owner,
        model: Application.get_env(:vibe_agents, :voice_model, "gpt-realtime"),
        voice: Application.get_env(:vibe_agents, :voice_voice, "marin"),
        api_key: api_key,
        instructions: system_prompt(agent_profile, capabilities),
        tools: realtime_tools(agent_profile, capabilities)
      }

      {:ok, state, {:continue, :connect}}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        notify(state.owner, {:error, reason})
        notify(state.owner, {:done})
        {:stop, :normal, state}
    end
  end

  defp connect(state) do
    with {:ok, conn} <- Mint.HTTP.connect(:https, "api.openai.com", 443, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(:wss, conn, "/v1/realtime?model=#{state.model}", [
             {"authorization", "Bearer #{state.api_key}"}
           ]) do
      Logger.info("[VibeAgents.Voice.OpenAIRealtime] connecting model=#{state.model}")
      {:ok, %{state | conn: conn, ref: ref}}
    else
      {:error, _conn, reason} ->
        Logger.warning("[VibeAgents.Voice.OpenAIRealtime] connect failed: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        Logger.warning("[VibeAgents.Voice.OpenAIRealtime] connect failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def handle_cast({:send_audio, pcm16}, state) do
    event = %{"type" => "input_audio_buffer.append", "audio" => Base.encode64(pcm16)}
    {:noreply, send_event(state, event)}
  end

  def handle_cast({:send_text, text}, state) do
    item = %{
      "type" => "conversation.item.create",
      "item" => %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => text}]
      }
    }

    state =
      state
      |> send_event(item)
      |> send_event(%{"type" => "response.create"})

    {:noreply, state}
  end

  def handle_cast({:send_image, jpeg}, state) do
    data_url = "data:image/jpeg;base64," <> Base.encode64(jpeg)

    event = %{
      "type" => "conversation.item.create",
      "item" => %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_image", "image_url" => data_url}]
      }
    }

    {:noreply, send_event(state, event)}
  end

  def handle_cast(:commit, state) do
    state =
      state
      |> send_event(%{"type" => "input_audio_buffer.commit"})
      |> send_event(%{"type" => "response.create"})

    {:noreply, state}
  end

  def handle_cast(:interrupt, state) do
    {:noreply, send_event(state, %{"type" => "response.cancel"})}
  end

  def handle_cast({:tool_result, call_id, result}, state) do
    item = %{
      "type" => "conversation.item.create",
      "item" => %{
        "type" => "function_call_output",
        "call_id" => call_id,
        "output" => encode_result(result)
      }
    }

    state =
      state
      |> send_event(item)
      |> send_event(%{"type" => "response.create"})

    {:noreply, state}
  end

  @impl true
  def handle_info(message, %{conn: nil} = state) do
    Logger.debug("[VibeAgents.Voice.OpenAIRealtime] dropped message, no connection: #{inspect(message)}")
    {:noreply, state}
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &handle_response/2)
        {:noreply, state}

      {:error, conn, reason, _responses} ->
        notify(state.owner, {:error, reason})
        notify(state.owner, {:done})
        {:stop, :normal, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    :ok
  end


  defp handle_response({:status, ref, status}, %{ref: ref} = state), do: %{state | status: status}

  defp handle_response({:headers, ref, headers}, %{ref: ref} = state),
    do: %{state | resp_headers: headers}

  defp handle_response({:done, ref}, %{ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        Logger.debug("[VibeAgents.Voice.OpenAIRealtime] websocket upgraded status=#{state.status}")
        %{state | conn: conn, websocket: websocket}

      {:error, conn, reason} ->
        Logger.warning("[VibeAgents.Voice.OpenAIRealtime] upgrade failed status=#{state.status}: #{inspect(reason)}")
        notify(state.owner, {:error, reason})
        %{state | conn: conn}
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref, websocket: websocket} = state)
       when not is_nil(websocket) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        Enum.reduce(frames, %{state | websocket: websocket}, &handle_frame/2)

      {:error, websocket, _reason} ->
        %{state | websocket: websocket}
    end
  end

  defp handle_response(_other, state), do: state

  defp handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, event} -> handle_event(event, state)
      {:error, _reason} -> state
    end
  end

  defp handle_frame({:ping, data}, state), do: send_frame(state, {:pong, data})
  defp handle_frame({:pong, _data}, state), do: state

  defp handle_frame({:close, _code, _reason}, state) do
    notify(state.owner, {:done})
    state
  end

  defp handle_frame(_frame, state), do: state


  defp handle_event(%{"type" => "session.created"}, state) do
    send_event(state, session_update_event(state))
  end

  defp handle_event(%{"type" => "session.updated"}, %{ready: false} = state) do
    Logger.info("[VibeAgents.Voice.OpenAIRealtime] session ready")
    notify(state.owner, {:ready})
    %{state | ready: true}
  end

  defp handle_event(%{"type" => "session.updated"}, state), do: state

  defp handle_event(
         %{"type" => "conversation.item.input_audio_transcription.delta", "delta" => delta},
         state
       ) do
    notify(state.owner, {:transcript_user, delta, false})
    state
  end

  defp handle_event(
         %{"type" => "conversation.item.input_audio_transcription.completed"} = event,
         state
       ) do
    notify(state.owner, {:transcript_user, event["transcript"] || "", true})
    state
  end

  defp handle_event(
         %{"type" => "response.output_audio_transcript.delta", "delta" => delta},
         state
       ) do
    notify(state.owner, {:transcript_agent, delta, false})
    state
  end

  defp handle_event(%{"type" => "response.output_audio_transcript.done"} = event, state) do
    notify(state.owner, {:transcript_agent, event["transcript"] || "", true})
    state
  end

  defp handle_event(%{"type" => "response.output_audio.delta", "delta" => delta}, state) do
    case Base.decode64(delta) do
      {:ok, pcm16} -> notify(state.owner, {:audio, pcm16})
      :error -> :ok
    end

    state
  end

  defp handle_event(
         %{"type" => "response.output_item.added", "item" => %{"type" => "function_call"} = item},
         state
       ) do
    call = %{call_id: item["call_id"], name: item["name"], args: ""}
    %{state | fn_calls: Map.put(state.fn_calls, item["id"], call)}
  end

  defp handle_event(
         %{
           "type" => "response.function_call_arguments.delta",
           "item_id" => item_id,
           "delta" => delta
         },
         state
       ) do
    update_fn_call(state, item_id, fn call -> %{call | args: call.args <> delta} end)
  end

  defp handle_event(
         %{"type" => "response.function_call_arguments.done", "item_id" => item_id} = event,
         state
       ) do
    case Map.get(state.fn_calls, item_id) do
      nil ->
        state

      call ->
        input = decode_args(event["arguments"] || call.args)
        notify(state.owner, {:tool_call, call.call_id, call.name, input})
        %{state | fn_calls: Map.delete(state.fn_calls, item_id)}
    end
  end

  defp handle_event(%{"type" => "error"} = event, state) do
    error = event["error"] || %{}
    notify(state.owner, {:error, %{code: error["code"], message: error["message"]}})
    state
  end

  defp handle_event(_event, state), do: state

  defp update_fn_call(state, item_id, fun) do
    case Map.get(state.fn_calls, item_id) do
      nil -> state
      call -> %{state | fn_calls: Map.put(state.fn_calls, item_id, fun.(call))}
    end
  end

  defp decode_args(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end


  defp send_event(state, event), do: send_frame(state, {:text, Jason.encode!(event)})

  defp send_frame(%{websocket: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} -> %{state | conn: conn, websocket: websocket}
          {:error, conn, _reason} -> %{state | conn: conn, websocket: websocket}
        end

      {:error, websocket, _reason} ->
        %{state | websocket: websocket}
    end
  end

  defp encode_result(result) when is_binary(result), do: result
  defp encode_result(result), do: Jason.encode!(result)

  defp notify(owner, event), do: send(owner, {:voice_provider, event})


  defp session_update_event(state) do
    %{
      "type" => "session.update",
      "session" => %{
        "type" => "realtime",
        "model" => state.model,
        "instructions" => state.instructions,
        "output_modalities" => ["audio"],
        "audio" => %{
          "input" => %{
            "format" => %{"type" => "audio/pcm", "rate" => 24_000},
            "turn_detection" => %{"type" => "server_vad"},
            "transcription" => %{"model" => "gpt-4o-mini-transcribe"}
          },
          "output" => %{
            "format" => %{"type" => "audio/pcm", "rate" => 24_000},
            "voice" => state.voice
          }
        },
        "tools" => state.tools
      }
    }
  end

  defp system_prompt(agent_profile, capabilities) do
    SafeApply.call(
      VibeAgents.Policy,
      :system_prompt,
      [agent_profile, capabilities],
      local_system_prompt(agent_profile)
    )
  end

  defp local_system_prompt(agent_profile) do
    name = agent_profile["displayName"] || agent_profile["username"] || "the assistant"
    persona = agent_profile["persona"] || agent_profile["systemPrompt"] || ""
    String.trim("You are #{name}, speaking with the user on a live voice call. #{persona}")
  end

  defp realtime_tools(agent_profile, capabilities) do
    VibeAgents.Tools.Catalog
    |> SafeApply.call(:specs, [agent_profile, capabilities], [])
    |> List.wrap()
    |> Enum.map(&to_realtime_tool/1)
    |> Enum.reject(&is_nil/1)
  end

  defp to_realtime_tool(spec) when is_map(spec) do
    name = spec["name"] || spec[:name]
    description = spec["description"] || spec[:description] || ""

    parameters =
      spec["parameters"] || spec[:parameters] || spec["input_schema"] || spec[:input_schema] ||
        %{"type" => "object", "properties" => %{}}

    if is_binary(name) do
      %{"type" => "function", "name" => name, "description" => description, "parameters" => parameters}
    end
  end

  defp to_realtime_tool(_spec), do: nil
end
