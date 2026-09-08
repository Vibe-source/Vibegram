defmodule VibeWeb.AgentChannel do
  @moduledoc """
  Phoenix Channel for real-time AI Agent communication.
  """

  use Phoenix.Channel
  require Logger

  alias Vibe.AI.Agent
  alias Vibe.AI.AgentBuilder
  alias Vibe.AI.AgenticEventShape
  alias Vibe.AI.ModelRegistry
  alias Vibe.AI.StandaloneAgent
  alias Vibe.AgentConversation

  @doc """
  Join the agent channel for a user.
  """
  def join("agent:" <> user_id, params, socket) do
    if socket.assigns[:user_id] == user_id do
      conversation_id = params["conversation_id"]

      socket =
        socket
        |> assign(:conversation_history, [])
        |> assign(:active_conversation_id, conversation_id)
        |> reset_stream_ui_state()

      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @doc """
  Handle incoming messages to the AI agent.
  """
  def handle_in("message", %{"text" => text} = params, socket) do
    case ModelRegistry.resolve_selection(params) do
      {:ok, model_selection} ->
        handle_message(text, params, model_selection, socket)

      {:error, :invalid_thinking_level} ->
        {:reply, {:error, %{reason: "invalid_thinking_level"}}, socket}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "invalid_model_selection"}}, socket}
    end
  end

  def handle_in("builder_ui_response", %{"ui_response" => ui_response} = params, socket)
      when is_map(ui_response) do
    user_id = socket.assigns[:user_id]
    conversation_id = params["conversation_id"] || socket.assigns[:active_conversation_id]
    summary = normalize_summary(params["summary"])
    active_agent_id = normalize_optional_string(params["active_agent_id"])

    with {:ok, conv_id} <- ensure_existing_conversation(user_id, conversation_id) do
      socket =
        socket
        |> assign(:active_conversation_id, conv_id)
        |> reset_stream_ui_state()

      push(socket, "ack", %{status: "processing", conversation_id: conv_id})

      if is_binary(summary) do
        AgentConversation.add_message(conv_id, %{
          "role" => "user",
          "content" => summary
        })
      end

      channel_pid = self()

      Task.start(fn ->
        {:ok, _conv} =
          AgentConversation.add_message(conv_id, %{
            "role" => "assistant",
            "content" => "",
            "isStreaming" => true
          })

        callback = streaming_callback(channel_pid, conv_id)

        case AgentBuilder.stream_message(
               user_id,
               summary,
               callback,
               active_agent_id: active_agent_id,
               ui_response: ui_response
             ) do
          {:ok, result} ->
            send(channel_pid, {:finalize_message, conv_id, result[:reply] || result["reply"]})
            send(channel_pid, {:push, "done", %{success: true, conversation_id: conv_id}})

          {:error, reason} ->
            Logger.error("Builder UI response error: #{inspect(reason)}")
            send(channel_pid, {:push, "error", %{message: to_string(reason)}})
        end
      end)

      {:noreply, socket}
    else
      _ ->
        {:reply, {:error, %{reason: "conversation_required"}}, socket}
    end
  end

  def handle_in("builder_create_draft", params, socket) do
    answers =
      case params["agentEnabled"] do
        nil -> %{}
        value -> %{"agentEnabled" => value}
      end

    ui_response = %{
      "requestId" => "setup:create_draft",
      "answers" => answers
    }

    handle_in(
      "builder_ui_response",
      %{
        "conversation_id" => params["conversation_id"],
        "summary" => "Create draft",
        "active_agent_id" => params["active_agent_id"],
        "ui_response" => ui_response
      },
      socket
    )
  end

  # List conversations for a user
  def handle_in("list_conversations", _params, socket) do
    user_id = socket.assigns[:user_id]
    conversations = AgentConversation.list_for_user(user_id)

    {:reply, {:ok, %{conversations: conversations}}, socket}
  end

  # Get a specific conversation
  def handle_in("get_conversation", %{"id" => id}, socket) do
    user_id = socket.assigns[:user_id]

    case AgentConversation.get_full(id, user_id) do
      nil -> {:reply, {:error, %{reason: "not_found"}}, socket}
      conv -> {:reply, {:ok, conv}, socket}
    end
  end

  # Create a new conversation
  def handle_in("create_conversation", %{"title" => title}, socket) do
    user_id = socket.assigns[:user_id]

    case AgentConversation.create(user_id, title) do
      {:ok, conv} ->
        socket = assign(socket, :active_conversation_id, conv.id)
        {:reply, {:ok, %{id: conv.id, title: conv.title}}, socket}

      {:error, _} ->
        {:reply, {:error, %{reason: "failed_to_create"}}, socket}
    end
  end

  # Delete a conversation
  def handle_in("delete_conversation", %{"id" => id}, socket) do
    user_id = socket.assigns[:user_id]

    case AgentConversation.delete(id, user_id) do
      {:ok, _} -> {:reply, {:ok, %{deleted: true}}, socket}
      {:error, _} -> {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  # Set active conversation
  def handle_in("set_conversation", %{"id" => id}, socket) do
    socket = assign(socket, :active_conversation_id, id)
    {:reply, {:ok, %{active: id}}, socket}
  end

  # Clear conversation history
  def handle_in("clear_history", _params, socket) do
    conv_id = socket.assigns[:active_conversation_id]
    user_id = socket.assigns[:user_id]

    if conv_id do
      AgentConversation.clear_messages(conv_id, user_id)
    end

    {:reply, {:ok, %{cleared: true}}, assign(socket, :conversation_history, [])}
  end

  # Handle push messages from the async task
  def handle_info({:push, "chunk", payload}, socket) do
    text =
      payload[:text] ||
        payload["text"] ||
        ""

    socket = append_text_node(socket, text)
    push(socket, "chunk", with_turn_nodes(payload, socket))

    socket =
      if is_binary(text) and text != "" and not (socket.assigns[:has_streamed_text] || false) do
        socket
        |> assign(:has_streamed_text, true)
        |> flush_pending_agent_cards()
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:push, "progress", payload}, socket) do
    socket =
      payload
      |> incoming_nodes()
      |> Enum.reduce(socket, &upsert_tool_node(&2, &1))

    push(socket, "progress", with_turn_nodes(payload, socket))
    {:noreply, socket}
  end

  def handle_info({:push, "tool_result", payload}, socket) do
    push(socket, "tool_result", with_turn_nodes(payload, socket))
    {:noreply, socket}
  end

  # Reasoning stream → a `kind:
  def handle_info({:push, "thinking", payload}, socket) do
    started_at = socket.assigns[:thinking_started_at] || System.monotonic_time(:millisecond)
    running? = to_string(payload[:status] || "running") != "done"
    duration_ms = System.monotonic_time(:millisecond) - started_at

    node = %{
      id: "thinking-#{socket.assigns[:thinking_index] || 0}",
      label: "Thinking",
      status: if(running?, do: "running", else: "done"),
      depth: 0,
      kind: "thinking",
      itemType: "thinking",
      tokens: payload[:tokens],
      durationMs: duration_ms,
      thinkingText: payload[:text]
    }

    socket =
      socket
      |> assign(:thinking_started_at, started_at)
      |> upsert_tool_node(node)

    push(socket, "thinking", with_turn_nodes(Map.delete(payload, :text), socket))

    socket =
      if running? do
        socket
      else
        socket
        |> assign(:thinking_index, (socket.assigns[:thinking_index] || 0) + 1)
        |> assign(:thinking_started_at, nil)
      end

    {:noreply, socket}
  end

  def handle_info({:push, "agent_cards", payload}, socket) do
    if socket.assigns[:has_streamed_text] || false do
      push(socket, "agent_cards", payload)
      {:noreply, socket}
    else
      pending = socket.assigns[:pending_agent_cards] || []
      {:noreply, assign(socket, :pending_agent_cards, pending ++ [payload])}
    end
  end

  def handle_info({:push, "error", payload}, socket) do
    enriched = "error" |> AgenticEventShape.enrich(payload) |> with_turn_nodes(socket)
    push(socket, "error", enriched)
    socket = persist_partial_turn(socket)
    {:noreply, reset_stream_ui_state(socket)}
  end

  def handle_info({:push, "done", payload}, socket) do
    enriched = "done" |> AgenticEventShape.enrich(payload) |> with_turn_nodes(socket)
    push(socket, "done", enriched)
    {:noreply, socket}
  end

  def handle_info({:push, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info({:append_content, chunk}, socket) do
    current = socket.assigns[:streaming_content] || ""
    {:noreply, assign(socket, :streaming_content, current <> chunk)}
  end

  def handle_info({:add_tool_result, result}, socket) do
    current = socket.assigns[:tool_results] || []
    {:noreply, assign(socket, :tool_results, current ++ [result])}
  end

  def handle_info({:finalize_message, conv_id, full_response}, socket) do
    socket = flush_pending_agent_cards(socket)
    tool_results = socket.assigns[:tool_results] || []
    final_text = StandaloneAgent.final_text_with_tool_fallback(full_response, tool_results)

    if final_text != "" and normalize_optional_string(full_response) == nil do
      push(
        socket,
        "chunk",
        AgenticEventShape.enrich("chunk", %{text: final_text, conversation_id: conv_id})
      )
    end

    rich_outputs =
      StandaloneAgent.finalized_rich_outputs(tool_results, final_text,
        agent_turn_id: Ecto.UUID.generate(),
        base_timestamp: :os.system_time(:millisecond)
      )

    if rich_outputs != [] do
      push(socket, "rich_outputs", %{
        conversation_id: conv_id,
        outputs: rich_outputs
      })
    end

    AgentConversation.update_last_message(conv_id, %{
      "content" => final_text,
      "isStreaming" => false,
      "toolResults" => tool_results,
      "richOutputs" => rich_outputs,
      "progressNodes" => sealed_turn_nodes(socket),
      "toolDigest" => tool_digest(tool_results)
    })

    socket = reset_stream_ui_state(socket)

    {:noreply, socket}
  end

  def handle_info({:update_history, history}, socket) do
    trimmed = Enum.take(history, -20)
    {:noreply, assign(socket, :conversation_history, trimmed)}
  end


  defp handle_message(text, params, model_selection, socket) do
    images = params["images"] || []
    conversation_id = params["conversation_id"] || socket.assigns[:active_conversation_id]
    user_id = socket.assigns[:user_id]
    truncate_id = params["truncate_at_id"]

    if truncate_id && conversation_id do
      AgentConversation.truncate_history(conversation_id, user_id, truncate_id)
    end

    {conv_id, history, turn_memory} =
      get_or_create_conversation(user_id, conversation_id, text)

    socket =
      socket
      |> assign(:active_conversation_id, conv_id)
      |> reset_stream_ui_state()

    push(socket, "ack", %{status: "processing", conversation_id: conv_id})

    AgentConversation.add_message(conv_id, %{
      "role" => "user",
      "content" => text,
      "images" => images
    })

    channel_pid = self()

    Task.start(fn ->
      {:ok, _conv} =
        AgentConversation.add_message(conv_id, %{
          "role" => "assistant",
          "content" => "",
          "isStreaming" => true
        })

      callback = streaming_callback(channel_pid, conv_id)

      case Agent.stream_response(text, callback,
             history: history,
             turn_memory: turn_memory,
             images: images,
             user_id: user_id,
             requester_user_id: user_id,
             model_provider: model_selection.provider,
             model_id: model_selection.model_id,
             thinking_level: model_selection.thinking_level
           ) do
        {:ok, full_response, runtime_state} ->
          send(channel_pid, {:finalize_message, conv_id, full_response})

          send(
            channel_pid,
            {:push, "done",
             %{
               success: true,
               conversation_id: conv_id,
               status: Map.get(runtime_state, :terminal_status, "completed")
             }}
          )

        {:ok, full_response} ->
          send(channel_pid, {:finalize_message, conv_id, full_response})
          send(channel_pid, {:push, "done", %{success: true, conversation_id: conv_id}})

        {:error, reason} ->
          Logger.error("Agent error: #{inspect(reason)}")
          send(channel_pid, {:push, "error", %{message: to_string(reason)}})
      end
    end)

    {:noreply, socket}
  end

  defp get_or_create_conversation(user_id, nil, first_message) do
    {:ok, conv} = AgentConversation.create(user_id, "New Chat")

    Task.start(fn -> generate_title_async(conv.id, first_message) end)

    {conv.id, [], []}
  end

  defp get_or_create_conversation(user_id, conv_id, _first_message) do
    case AgentConversation.get_for_user(conv_id, user_id) do
      nil ->
        {:ok, conv} = AgentConversation.create(user_id, "New Chat")
        {conv.id, [], []}

      conv ->
        {conv.id, history_from_messages(conv.messages), turn_memory_from_messages(conv.messages)}
    end
  end

  defp history_from_messages(messages) do
    messages
    |> List.wrap()
    |> Enum.map(fn msg -> %{role: msg["role"], content: msg["content"] || ""} end)
    |> Enum.filter(fn msg -> msg.content != "" end)
    |> Enum.take(-20)
  end

  defp turn_memory_from_messages(messages) do
    messages
    |> List.wrap()
    |> Enum.filter(&(&1["role"] == "assistant"))
    |> Enum.map(fn msg -> msg["toolDigest"] || tool_digest(msg["toolResults"]) end)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.take(-6)
  end

  @doc false
  def tool_digest(tool_results) do
    tool_results
    |> List.wrap()
    |> StandaloneAgent.select_music_tool_results()
    |> Enum.map(&digest_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join("; ")
  end

  defp digest_entry(item) when is_map(item) do
    tool = item[:tool] || item["tool"]
    result = item[:result] || item["result"]

    case {to_string(tool || ""), result} do
      {"", _} ->
        nil

      {"search_music", %{} = result} ->
        case music_digest(result) do
          nil -> "search_music → no track"
          detail -> "search_music → #{detail}"
        end

      {name, %{} = result} ->
        if error_result?(result), do: "#{name} → failed", else: "#{name} → ok"

      {name, _} ->
        "#{name} → ok"
    end
  end

  defp digest_entry(_item), do: nil

  defp music_digest(result) do
    (result[:tracks] || result["tracks"] || [])
    |> List.wrap()
    |> Enum.map(fn track ->
      title = track[:title] || track["title"]
      id = track[:video_id] || track["video_id"] || track[:videoId] || track["videoId"]

      cond do
        is_binary(title) and is_binary(id) -> ~s(sent "#{String.slice(title, 0, 70)}" [#{id}])
        is_binary(title) -> ~s(sent "#{String.slice(title, 0, 70)}")
        true -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      entries -> Enum.join(entries, ", ")
    end
  end

  defp error_result?(result) when is_map(result) do
    case result[:error] || result["error"] do
      value when is_binary(value) -> true
      %{} -> true
      _ -> (result[:ok] || result["ok"]) == false
    end
  end

  defp error_result?(_), do: false

  defp sealed_turn_nodes(socket) do
    (socket.assigns[:turn_nodes] || [])
    |> Enum.map(fn node ->
      %{
        "id" => node[:id] || node["id"],
        "label" => node[:label] || node["label"],
        "status" => seal_status(node[:status] || node["status"]),
        "depth" => node[:depth] || node["depth"] || 0,
        "kind" => node[:kind] || node["kind"],
        "itemType" => node[:itemType] || node["itemType"],
        "tool" => node[:tool] || node["tool"],
        "tokens" => node[:tokens] || node["tokens"],
        "durationMs" => node[:durationMs] || node["durationMs"],
        "thinkingText" => node[:thinkingText] || node["thinkingText"]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  defp seal_status("running"), do: "done"
  defp seal_status(nil), do: "done"
  defp seal_status(status), do: to_string(status)

  defp streaming_callback(channel_pid, conversation_id) do
    fn
      %{type: :text, content: chunk} ->
        send(
          channel_pid,
          {:push, "chunk",
           AgenticEventShape.enrich("chunk", %{text: chunk, conversation_id: conversation_id})}
        )

        send(channel_pid, {:append_content, chunk})

      %{type: :progress, label: label} = payload ->
        send(
          channel_pid,
          {:push, "progress",
           AgenticEventShape.enrich("progress", %{
             label: label,
             tool: payload[:tool],
             tool_call_id: payload[:tool_call_id],
             status: payload[:status] || "running",
             conversation_id: conversation_id
           })}
        )

      %{type: :thinking} = payload ->
        send(
          channel_pid,
          {:push, "thinking",
           %{
             status: payload[:status] || "running",
             content: payload[:content],
             text: payload[:text],
             tokens: payload[:tokens],
             conversation_id: conversation_id
           }}
        )

      %{type: :subagent} = payload ->
        send(
          channel_pid,
          {:push, "subagent",
           Map.put(Map.delete(payload, :type), :conversation_id, conversation_id)}
        )

      %{type: :tool_result, tool: tool, result: result} = payload ->
        send(
          channel_pid,
          {:push, "tool_result",
           AgenticEventShape.enrich("tool_result", %{
             tool: tool,
             tool_call_id: payload[:tool_call_id],
             result: result,
             status: payload[:status] || "complete",
             duration_ms: payload[:duration_ms],
             conversation_id: conversation_id
           })}
        )

        send(channel_pid, {:add_tool_result, %{tool: tool, result: result}})

      %{type: :agent_cards, cards: cards} = payload ->
        send(
          channel_pid,
          {:push, "agent_cards",
           %{
             cards: cards,
             group_id: payload[:group_id] || payload["group_id"],
             conversation_id: conversation_id
           }}
        )

      %{type: :state} = payload ->
        send(
          channel_pid,
          {:push, "builder_state",
           AgenticEventShape.enrich(
             "state",
             Map.put(Map.delete(payload, :type), :conversation_id, conversation_id)
           )}
        )

      %{type: :ui_request} = payload ->
        send(
          channel_pid,
          {:push, "ui_request",
           AgenticEventShape.enrich(
             "ui_request",
             Map.put(Map.delete(payload, :type), :conversation_id, conversation_id)
           )}
        )

      %{type: :review_ready} = payload ->
        send(
          channel_pid,
          {:push, "review_ready",
           AgenticEventShape.enrich(
             "review_ready",
             Map.put(Map.delete(payload, :type), :conversation_id, conversation_id)
           )}
        )
    end
  end

  defp ensure_existing_conversation(user_id, nil) do
    {:ok, conv} = AgentConversation.create(user_id, "New Chat")
    {:ok, conv.id}
  end

  defp ensure_existing_conversation(user_id, conv_id) do
    case AgentConversation.get_for_user(conv_id, user_id) do
      nil ->
        {:error, :not_found}

      _conv ->
        {:ok, conv_id}
    end
  end

  defp normalize_summary(nil), do: nil

  defp normalize_summary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: String.slice(trimmed, 0, 500)
  end

  defp normalize_summary(value), do: to_string(value) |> normalize_summary()

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(value), do: value |> to_string() |> normalize_optional_string()

  defp reset_stream_ui_state(socket) do
    socket
    |> assign(:streaming_content, "")
    |> assign(:tool_results, [])
    |> assign(:pending_agent_cards, [])
    |> assign(:has_streamed_text, false)
    |> assign(:turn_nodes, [])
    |> assign(:thinking_index, 0)
    |> assign(:thinking_started_at, nil)
  end


  @text_node_limit 4000

  defp append_text_node(socket, chunk) when is_binary(chunk) do
    nodes = socket.assigns[:turn_nodes] || []

    case List.last(nodes) do
      %{kind: "text", label: label} = last ->
        merged = %{last | label: String.slice(label <> chunk, 0, @text_node_limit)}
        assign(socket, :turn_nodes, List.replace_at(nodes, -1, merged))

      _ ->
        node = %{
          id: "text-#{length(nodes)}",
          label: String.slice(chunk, 0, @text_node_limit),
          status: "done",
          depth: 0,
          kind: "text",
          itemType: "text"
        }

        assign(socket, :turn_nodes, nodes ++ [node])
    end
  end

  defp append_text_node(socket, _chunk), do: socket

  defp upsert_tool_node(socket, node) when is_map(node) do
    nodes = socket.assigns[:turn_nodes] || []
    id = node[:id] || node["id"]

    case Enum.find_index(nodes, fn existing -> (existing[:id] || existing["id"]) == id end) do
      nil -> assign(socket, :turn_nodes, nodes ++ [node])
      index -> assign(socket, :turn_nodes, List.replace_at(nodes, index, node))
    end
  end

  defp upsert_tool_node(socket, _node), do: socket

  defp persist_partial_turn(socket) do
    conv_id = socket.assigns[:active_conversation_id]
    tool_results = socket.assigns[:tool_results] || []
    partial_text = socket.assigns[:streaming_content] || ""
    nodes = sealed_turn_nodes(socket)

    if is_binary(conv_id) and (tool_results != [] or String.trim(partial_text) != "") do
      rich_outputs =
        StandaloneAgent.finalized_rich_outputs(tool_results, partial_text,
          agent_turn_id: Ecto.UUID.generate(),
          base_timestamp: :os.system_time(:millisecond)
        )

      if rich_outputs != [] do
        push(socket, "rich_outputs", %{conversation_id: conv_id, outputs: rich_outputs})
      end

      AgentConversation.update_last_message(conv_id, %{
        "content" => partial_text,
        "isStreaming" => false,
        "toolResults" => tool_results,
        "richOutputs" => rich_outputs,
        "progressNodes" => nodes,
        "toolDigest" => tool_digest(tool_results),
        "failed" => true
      })
    end

    socket
  end

  defp incoming_nodes(payload) when is_map(payload) do
    (payload[:progressNodes] || payload["progressNodes"] || payload[:progress_nodes] ||
       payload["progress_nodes"] || [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp incoming_nodes(_payload), do: []

  defp with_turn_nodes(payload, socket) do
    nodes = socket.assigns[:turn_nodes] || []

    payload
    |> Map.put(:progressNodes, nodes)
    |> Map.put(:progress_nodes, nodes)
  end

  defp flush_pending_agent_cards(socket) do
    pending = socket.assigns[:pending_agent_cards] || []

    Enum.each(pending, fn payload ->
      push(socket, "agent_cards", payload)
    end)

    assign(socket, :pending_agent_cards, [])
  end

  defp generate_title_async(conv_id, message) do
    prompt = """
    Generate a very short title (3-5 words max) for a conversation that starts with this message:
    "#{String.slice(message, 0..200)}"

    Rules:
    - Maximum 5 words
    - No quotes or punctuation at the end
    - Be specific and descriptive
    - Don't start with "Chat about" or similar

    Just respond with the title, nothing else.
    """

    case Vibe.AI.Agent.quick_completion(prompt) do
      {:ok, title} ->
        clean_title =
          title
          |> String.trim()
          |> String.replace(~r/^["']|["']$/, "")
          |> String.slice(0..50)

        AgentConversation.update_title(conv_id, clean_title)
        Logger.info("Generated title for #{conv_id}: #{clean_title}")

        VibeWeb.Endpoint.broadcast("agent:*", "title_updated", %{
          conversation_id: conv_id,
          title: clean_title
        })

      {:error, reason} ->
        Logger.warn("Failed to generate title: #{inspect(reason)}")
        fallback = String.slice(message, 0..30)
        AgentConversation.update_title(conv_id, fallback)
    end
  end
end
