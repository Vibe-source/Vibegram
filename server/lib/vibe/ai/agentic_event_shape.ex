defmodule Vibe.AI.AgenticEventShape do
  @moduledoc false

  @schema "vibe.agentic.v1"

  def enrich(event, payload) do
    event = to_string(event)

    payload =
      payload
      |> ensure_map()
      |> normalize_payload_label(event)
      |> normalize_progress_node_fields()

    nodes = progress_nodes(event, payload)

    payload
    |> Map.put_new(:agenticSchema, @schema)
    |> Map.put_new(:agentic_schema, @schema)
    |> Map.put_new(:response_item, response_item(event, payload))
    |> Map.put_new(:responseItem, response_item(event, payload))
    |> Map.put_new(:progressNodes, nodes)
    |> Map.put_new(:progress_nodes, nodes)
    |> Map.put_new(:terminal, terminal?(event))
    |> put_activity_state(event)
  end

  defp response_item("chunk", payload) do
    text = fetch(payload, [:text, "text", :content, "content"]) || ""

    %{
      type: "message",
      role: "assistant",
      status: "streaming",
      content: [%{type: "output_text", text: text}]
    }
  end

  defp response_item(event, payload) when event in ["progress", "tool_result"] do
    tool = fetch(payload, [:tool, "tool"]) || "tool"
    call_id = fetch(payload, [:tool_call_id, "tool_call_id", :call_id, "call_id"]) || tool

    if event == "tool_result" do
      %{
        type: "function_call_output",
        call_id: call_id,
        status: fetch(payload, [:status, "status"]) || "complete",
        output: encode_json(fetch(payload, [:result, "result"]) || %{})
      }
    else
      %{
        type: "function_call",
        call_id: call_id,
        name: tool,
        status: fetch(payload, [:status, "status"]) || "running",
        arguments: encode_json(fetch(payload, [:input, "input", :arguments, "arguments"]) || %{})
      }
    end
  end

  defp response_item("done", payload) do
    reply = fetch(payload, [:reply, "reply", :text, "text", :message, "message"]) || ""

    %{
      type: "message",
      role: "assistant",
      status: "completed",
      content: [%{type: "output_text", text: reply}]
    }
  end

  defp response_item("error", payload) do
    %{
      type: "error",
      status: "failed",
      message: fetch(payload, [:message, "message", :error, "error"]) || "Agent failed"
    }
  end

  defp response_item(event, payload) do
    %{
      type: event,
      status: fetch(payload, [:status, "status"])
    }
  end

  defp progress_nodes(_event, payload) do
    existing =
      fetch(payload, [:progressNodes, "progressNodes", :progress_nodes, "progress_nodes"])

    cond do
      is_list(existing) ->
        Enum.map(existing, &normalize_node_label/1)

      activity = fetch(payload, [:activity, "activity"]) ->
        Enum.map(List.wrap(activity), &activity_node/1)

      fetch(payload, [:label, "label"]) ->
        [tool_node(payload)]

      true ->
        []
    end
  end

  defp activity_node(item) do
    item = ensure_map(item)

    %{
      id: fetch(item, [:id, "id"]) || "activity:#{fetch(item, [:title, "title"]) || "step"}",
      label:
        compact_label(
          fetch(item, [:title, "title"]) || fetch(item, [:label, "label"]) || "Working"
        ),
      status: fetch(item, [:status, "status"]) || "running",
      depth: fetch(item, [:depth, "depth"]) || 0,
      kind: fetch(item, [:kind, "kind"]) || "task",
      target: fetch(item, [:detail, "detail"]) || fetch(item, [:prompt, "prompt"]),
      parentId: fetch(item, [:parentId, "parentId", :parent_id, "parent_id"]),
      subagentType: fetch(item, [:agentLabel, "agentLabel", :agent_label, "agent_label"])
    }
  end

  defp tool_node(payload) do
    tool = fetch(payload, [:tool, "tool"]) || "tool"
    label = compact_label(fetch(payload, [:label, "label"]) || tool)
    status = fetch(payload, [:status, "status"]) || "running"

    %{
      id:
        fetch(payload, [:activityId, "activityId", :tool_call_id, "tool_call_id"]) ||
          "tool:#{tool}",
      label: label,
      status: normalize_status(status),
      depth: 0,
      kind: tool_kind(tool),
      itemType: "tool",
      target: fetch(payload, [:target, "target"]),
      tool: tool,
      callId: fetch(payload, [:tool_call_id, "tool_call_id", :call_id, "call_id"]) || tool,
      eventType: fetch(payload, [:type, "type"]) || "progress"
    }
  end

  # "error" and "failed" must survive to the client.
  defp normalize_status(status) do
    case to_string(status) do
      "complete" -> "done"
      "completed" -> "done"
      "failed" -> "error"
      other -> other
    end
  end

  # Order matters:
  defp tool_kind(tool) do
    tool = to_string(tool)

    cond do
      tool == "read_url" -> "web"
      String.contains?(tool, "music") -> "music"
      String.contains?(tool, "image") || String.contains?(tool, "vision") -> "image"
      String.contains?(tool, "search") -> "web"
      String.contains?(tool, "document") -> "read"
      String.contains?(tool, "ask_user") -> "question"
      String.contains?(tool, "subagent") || String.contains?(tool, "delegate") -> "task"
      String.contains?(tool, "agent") -> "agent"
      String.contains?(tool, "config") || String.contains?(tool, "update") -> "config"
      true -> "tool"
    end
  end

  defp terminal?(event), do: event in ["done", "error", "review_ready"]

  defp put_activity_state(payload, event) when event in ["chunk", "progress", "done", "error"] do
    state =
      case event do
        "chunk" -> "typing"
        "progress" -> "working"
        _terminal -> "ready"
      end

    payload
    |> Map.delete("activityState")
    |> Map.delete("activity_state")
    |> Map.put(:activityState, state)
    |> Map.put(:activity_state, state)
  end

  defp put_activity_state(payload, _event), do: payload

  defp normalize_payload_label(payload, "progress") do
    payload
    |> update_if_present(:label, &compact_label/1)
    |> update_if_present("label", &compact_label/1)
  end

  defp normalize_payload_label(payload, _event), do: payload

  defp normalize_progress_node_fields(payload) do
    Enum.reduce(
      [
        :progressNodes,
        "progressNodes",
        :progress_nodes,
        "progress_nodes",
        :activity,
        "activity"
      ],
      payload,
      fn key, result ->
        update_if_present(result, key, fn
          nodes when is_list(nodes) -> Enum.map(nodes, &normalize_node_label/1)
          other -> other
        end)
      end
    )
  end

  defp normalize_node_label(node) when is_map(node) do
    node
    |> update_if_present(:label, &compact_label/1)
    |> update_if_present("label", &compact_label/1)
    |> update_if_present(:title, &compact_label/1)
    |> update_if_present("title", &compact_label/1)
  end

  defp normalize_node_label(node), do: node

  defp update_if_present(map, key, fun) do
    if Map.has_key?(map, key), do: Map.update!(map, key, fun), else: map
  end

  # SAFETY NET ONLY.
  @label_limit 40

  defp compact_label(value) when is_binary(value) do
    normalized =
      value
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.join(" ")

    if String.length(normalized) <= @label_limit do
      normalized
    else
      cut = String.slice(normalized, 0, @label_limit - 1)
      on_word = String.replace(cut, ~r/\s+\S*$/u, "")

      base = if String.length(on_word) >= div(@label_limit * 3, 5), do: on_word, else: cut

      base
      |> String.trim_trailing(" -–—·,:(")
      |> String.trim_trailing("…")
      |> Kernel.<>("…")
    end
  end

  defp compact_label(value), do: value

  defp fetch(map, keys) when is_map(map), do: Enum.find_value(keys, &Map.get(map, &1))
  defp fetch(_map, _keys), do: nil

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _error} -> Jason.encode!(inspect(value))
    end
  end
end
